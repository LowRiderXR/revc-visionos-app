//
//  MultiviewSpike.swift
//  Stufe 1 of the multiview plan (Docs/vicecity/multiview-plan.md).
//
//  A standalone offscreen render pass, outside ANGLE, that combines the two
//  UNPROVEN ingredients of the multiview goal in one pass:
//    (a) a SELF-BUILT two-layer rasterization rate map (the compositor's own
//        map is proven; ours is not), and
//    (b) implicit MSAA the way the production path uses it: memoryless
//        multisample array target + resolve, under the rate map, with
//        vertex amplification 2.
//
//  Verification is numeric, not visual: colored bars are drawn at known
//  LOGICAL positions, the resolved texture is read back, and each measured
//  physical bar center is compared against the rate map's own answer
//  (physicalCoordinates(screenCoordinates:layer:)). The double-warp position
//  phys(phys(x)) is computed alongside, so "runs fine but warps twice" shows
//  up as a named failure instead of a mystery offset.
//
//  Success criteria (fixed before this file was written — see the plan):
//    PASS  every bar center within 4 px of its expected position, both
//          layers; layer 1 shows the +96 px shifted bars (amplification
//          works) with layer-1 warp (per-layer map honored); background
//          pixels equal the clear color (resolve clean).
//    FAIL  bars match the double-warp prediction, or layer 1 shows layer-0
//          content, or the pass/command buffer errors out.
//
//  Enabled with VC_MV_SPIKE=1; logs with prefix [mv-spike].
//

import Foundation
import Metal

enum MultiviewSpike {

    private static let screen = 2048
    private static let zones = 8
    private static let layerShift: Float = 96          // logical px, layer 1 only
    private static let sampleCount = 2                 // matches VC_MSAA default
    private static let tolerance: Float = 4.0          // px, bar-center delta

    // Bar centers in logical pixels; every bar is 48 px thick.
    private static let barCenters: [Float] = [384, 768, 1152, 1536]
    private static let barHalf: Float = 24
    // X markers: full-height vertical bars. Y markers: horizontal bars
    // confined to x in [32, 288] so the two sets never overlap, even after
    // the +96 layer shift. Scan lines at logical 160 stay clear of both.
    private static let xBarColors: [SIMD4<Float>] = [
        SIMD4(1, 0, 0, 1), SIMD4(0, 1, 0, 1), SIMD4(0, 0, 1, 1), SIMD4(1, 1, 0, 1),
    ]
    private static let yBarColors: [SIMD4<Float>] = [
        SIMD4(0, 1, 1, 1), SIMD4(1, 0, 1, 1), SIMD4(1, 1, 1, 1), SIMD4(1, 0.5, 0, 1),
    ]

    static func run(device: MTLDevice) {
        runSpike(device: device, instanced: false)
    }

    /// The stage-3 gate test: same bar verification as stage 1, but the layer
    /// routing is ANGLE's multiview emulation — instanceCount 2, view =
    /// instance_id % 2, [[render_target_array_index]] from the vertex shader,
    /// NO vertex amplification. Rate map follows the measured rule: one
    /// SHARED vertical curve across both layers, horizontal per layer
    /// (layer 0 uniform, layer 1 falloff), so both axes must foveate.
    static func runInstanced(device: MTLDevice) {
        runSpike(device: device, instanced: true)
    }

    private static func runSpike(device: MTLDevice, instanced: Bool) {
        print("[mv-spike] start: mode=\(instanced ? "instanced-rt-index" : "amplification")"
              + " screen=\(screen)x\(screen) zones=\(zones)x\(zones)"
              + " samples=\(sampleCount) shift=\(layerShift) tolerance=\(tolerance)px")

        guard let map = makeTwoLayerMap(device: device, instanced: instanced) else {
            print("[mv-spike] RESULT=FAIL stage=map (makeRasterizationRateMap returned nil)")
            return
        }
        logMapGeometry(map, instanced: instanced)

        // --- Textures: memoryless MS array + private resolve array + memoryless depth.
        let msDesc = MTLTextureDescriptor()
        msDesc.textureType = .type2DMultisampleArray
        msDesc.pixelFormat = .rgba8Unorm
        msDesc.width = screen
        msDesc.height = screen
        msDesc.arrayLength = 2
        msDesc.sampleCount = sampleCount
        msDesc.storageMode = .memoryless
        msDesc.usage = .renderTarget

        let resolveDesc = MTLTextureDescriptor()
        resolveDesc.textureType = .type2DArray
        resolveDesc.pixelFormat = .rgba8Unorm
        resolveDesc.width = screen
        resolveDesc.height = screen
        resolveDesc.arrayLength = 2
        resolveDesc.storageMode = .private
        resolveDesc.usage = .renderTarget

        let depthDesc = MTLTextureDescriptor()
        depthDesc.textureType = .type2DMultisampleArray
        depthDesc.pixelFormat = .depth32Float
        depthDesc.width = screen
        depthDesc.height = screen
        depthDesc.arrayLength = 2
        depthDesc.sampleCount = sampleCount
        depthDesc.storageMode = .memoryless
        depthDesc.usage = .renderTarget

        guard let msTex = device.makeTexture(descriptor: msDesc),
              let resolveTex = device.makeTexture(descriptor: resolveDesc),
              let depthTex = device.makeTexture(descriptor: depthDesc) else {
            print("[mv-spike] RESULT=FAIL stage=textures (allocation failed)")
            return
        }

        // --- Pipeline.
        guard let library = device.makeDefaultLibrary(),
              let vfn = library.makeFunction(name: instanced ? "mv_spike_inst_vertex" : "mv_spike_vertex"),
              let ffn = library.makeFunction(name: instanced ? "mv_spike_inst_fragment" : "mv_spike_fragment") else {
            print("[mv-spike] RESULT=FAIL stage=library (spike shaders missing)")
            return
        }
        let pipeDesc = MTLRenderPipelineDescriptor()
        pipeDesc.label = instanced ? "mv-spike-inst" : "mv-spike"
        pipeDesc.vertexFunction = vfn
        pipeDesc.fragmentFunction = ffn
        pipeDesc.colorAttachments[0].pixelFormat = .rgba8Unorm
        pipeDesc.depthAttachmentPixelFormat = .depth32Float
        pipeDesc.rasterSampleCount = sampleCount
        if instanced {
            // Layered rendering via [[render_target_array_index]]: the pipeline
            // must know the topology up front; no amplification is configured.
            pipeDesc.inputPrimitiveTopology = .triangle
        } else {
            pipeDesc.maxVertexAmplificationCount = 2
        }
        let pipeline: MTLRenderPipelineState
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: pipeDesc)
        } catch {
            print("[mv-spike] RESULT=FAIL stage=pipeline error=\(error)")
            return
        }

        let dsDesc = MTLDepthStencilDescriptor()
        dsDesc.depthCompareFunction = .always
        dsDesc.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: dsDesc) else {
            print("[mv-spike] RESULT=FAIL stage=depthState")
            return
        }

        // --- Geometry + readback buffer.
        let vertexData = buildBars()
        guard let vertexBuffer = device.makeBuffer(bytes: vertexData,
                                                   length: vertexData.count * MemoryLayout<Float>.size),
              let readback = device.makeBuffer(length: screen * screen * 4 * 2,
                                               options: .storageModeShared) else {
            print("[mv-spike] RESULT=FAIL stage=buffers")
            return
        }
        let vertexCount = vertexData.count / 6

        // --- Encode: one pass, rate map + amplification + memoryless MSAA resolve.
        guard let queue = device.makeCommandQueue(),
              let cb = queue.makeCommandBuffer() else {
            print("[mv-spike] RESULT=FAIL stage=queue")
            return
        }
        cb.label = "mv-spike"

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msTex
        pass.colorAttachments[0].resolveTexture = resolveTex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.depthAttachment.texture = depthTex
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 0
        pass.rasterizationRateMap = map
        pass.renderTargetArrayLength = 2

        guard let encoder = cb.makeRenderCommandEncoder(descriptor: pass) else {
            print("[mv-spike] RESULT=FAIL stage=encoder (descriptor rejected)")
            return
        }
        encoder.label = "mv-spike"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                        width: Double(screen), height: Double(screen),
                                        znear: 0, zfar: 1))
        if !instanced {
            var viewMappings = [
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: 0, renderTargetArrayIndexOffset: 0),
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: 0, renderTargetArrayIndexOffset: 1),
            ]
            encoder.setVertexAmplificationCount(2, viewMappings: &viewMappings)
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        var params = SIMD4<Float>(Float(screen), Float(screen), layerShift, layerShift)
        encoder.setVertexBytes(&params, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
        if instanced {
            // ANGLE's emulation doubles the instances; view = instance_id % 2.
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount,
                                   instanceCount: 2)
        } else {
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        }
        encoder.endEncoding()

        guard let blit = cb.makeBlitCommandEncoder() else {
            print("[mv-spike] RESULT=FAIL stage=blit")
            return
        }
        for slice in 0..<2 {
            blit.copy(from: resolveTex, sourceSlice: slice, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: screen, height: screen, depth: 1),
                      to: readback, destinationOffset: slice * screen * screen * 4,
                      destinationBytesPerRow: screen * 4,
                      destinationBytesPerImage: screen * screen * 4)
        }
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        if let error = cb.error {
            print("[mv-spike] RESULT=FAIL stage=gpu status=\(cb.status.rawValue) error=\(error)")
            return
        }
        print("[mv-spike] gpu pass completed without error — now verifying content")

        // --- Verify.
        let pixels = readback.contents().bindMemory(to: UInt8.self,
                                                    capacity: screen * screen * 4 * 2)
        var failures = 0
        var checks = 0
        for layer in 0..<2 {
            let shift = Float(layer) * layerShift
            let base = layer * screen * screen * 4

            // Background must be the clear color (resolve produced a clean image).
            let bg = pixel(pixels, base: base, x: 16, y: 16)
            let bgOK = bg.0 < 8 && bg.1 < 8 && bg.2 < 8
            checks += 1
            if !bgOK { failures += 1 }
            print("[mv-spike] layer=\(layer) background rgb=(\(bg.0),\(bg.1),\(bg.2)) \(bgOK ? "OK" : "FAIL")")

            // X markers: scan the physical row for logical y = 160 + shift.
            let scanY = Int(map.physicalCoordinates(
                screenCoordinates: MTLCoordinate2DMake(Float(screen) / 2, 160 + shift),
                layer: layer).y.rounded())
            let physW = Int(map.physicalCoordinates(
                screenCoordinates: MTLCoordinate2DMake(Float(screen), 160 + shift),
                layer: layer).x.rounded())
            for (i, c) in barCenters.enumerated() {
                let logical = c + shift
                let expected = map.physicalCoordinates(
                    screenCoordinates: MTLCoordinate2DMake(logical, 160 + shift), layer: layer).x
                let onceWarped = map.physicalCoordinates(
                    screenCoordinates: MTLCoordinate2DMake(logical, 160 + shift), layer: layer)
                let doubleWarp = map.physicalCoordinates(
                    screenCoordinates: onceWarped, layer: layer).x
                let unshifted = map.physicalCoordinates(
                    screenCoordinates: MTLCoordinate2DMake(c, 160 + shift), layer: layer).x
                report(layer: layer, axis: "x", index: i, expected: expected,
                       doubleWarp: doubleWarp, unshifted: unshifted,
                       measured: scanLine(pixels, base: base, fixed: scanY, limit: physW,
                                          horizontalScan: true, color: xBarColors[i]),
                       checks: &checks, failures: &failures)
            }

            // Y markers: scan the physical column for logical x = 160 + shift.
            let scanX = Int(map.physicalCoordinates(
                screenCoordinates: MTLCoordinate2DMake(160 + shift, Float(screen) / 2),
                layer: layer).x.rounded())
            let physH = Int(map.physicalCoordinates(
                screenCoordinates: MTLCoordinate2DMake(160 + shift, Float(screen)),
                layer: layer).y.rounded())
            for (i, c) in barCenters.enumerated() {
                let logical = c + shift
                let expected = map.physicalCoordinates(
                    screenCoordinates: MTLCoordinate2DMake(160 + shift, logical), layer: layer).y
                let onceWarped = map.physicalCoordinates(
                    screenCoordinates: MTLCoordinate2DMake(160 + shift, logical), layer: layer)
                let doubleWarp = map.physicalCoordinates(
                    screenCoordinates: onceWarped, layer: layer).y
                let unshifted = map.physicalCoordinates(
                    screenCoordinates: MTLCoordinate2DMake(160 + shift, c), layer: layer).y
                report(layer: layer, axis: "y", index: i, expected: expected,
                       doubleWarp: doubleWarp, unshifted: unshifted,
                       measured: scanLine(pixels, base: base, fixed: scanX, limit: physH,
                                          horizontalScan: false, color: yBarColors[i]),
                       checks: &checks, failures: &failures)
            }
        }

        print("[mv-spike] RESULT=\(failures == 0 ? "PASS" : "FAIL") checks=\(checks) failures=\(failures)")
    }

    // MARK: - Isolation test (follow-up to the Stufe-1 finding)

    /// Stufe 1 found that the VERTICAL rates of our self-built two-layer map
    /// were ignored (physicalSize height = full, farCorner.y = identity) while
    /// horizontal worked. This builds a matrix of map variants and logs each
    /// map's self-reported geometry, to isolate WHERE vertical rates get lost:
    /// per axis (H-only vs V-only), per layer count (1 vs 2), and per
    /// construction API (Swift subscript assignment vs the pointer initializer
    /// the game uses in visionos_angle.mm). No rendering needed — Stufe 1
    /// proved rendering follows the map's own physicalCoordinates answers.
    /// Logged with prefix [mv-iso]; run with VC_MV_SPIKE=1 or =2.
    static func isolationTest(device: MTLDevice) {
        var falloff = [Float](repeating: 1, count: zones)
        for i in 0..<zones {
            let d = abs(Float(i) - Float(zones - 1) / 2) / (Float(zones - 1) / 2)
            falloff[i] = 1.0 - 0.75 * d
        }
        let uniform = [Float](repeating: 1, count: zones)
        let integral = falloff.reduce(0, +) / Float(zones) * Float(screen)
        print("[mv-iso] start: screen=\(screen)x\(screen) zones=\(zones)"
              + " falloffIntegral=\(Int(integral.rounded())) fullAxis=\(screen)")

        func subscriptLayer(h: [Float], v: [Float]) -> MTLRasterizationRateLayerDescriptor {
            let l = MTLRasterizationRateLayerDescriptor(sampleCount: MTLSizeMake(zones, zones, 0))
            for i in 0..<zones {
                l.horizontal[i] = h[i]
                l.vertical[i] = v[i]
            }
            return l
        }
        // The game's construction path (visionos_angle.mm:1654): the pointer
        // initializer, with depth 1 in the MTLSize exactly as the game passes it.
        func pointerLayer(h: [Float], v: [Float]) -> MTLRasterizationRateLayerDescriptor {
            h.withUnsafeBufferPointer { hp in
                v.withUnsafeBufferPointer { vp in
                    MTLRasterizationRateLayerDescriptor(__sampleCount: MTLSizeMake(zones, zones, 1),
                                                        horizontal: hp.baseAddress!,
                                                        vertical: vp.baseAddress!)
                }
            }
        }

        struct Variant {
            let name: String
            let layers: [MTLRasterizationRateLayerDescriptor]
        }
        // Asymmetric curve (rate rising left to right) plus its mirror, so a
        // "mirrored H per eye, shared V" map — the actual multiview target
        // shape — can be told apart from a merely symmetric one.
        var rising = [Float](repeating: 1, count: zones)
        for i in 0..<zones {
            rising[i] = 0.25 + 0.75 * Float(i) / Float(zones - 1)
        }
        let mirrored = Array(rising.reversed())

        // Round 1 (2026-09-22) established: single-layer maps honor BOTH axes
        // (production is single-layer and fine); the two-layer map with
        // DIFFERING vertical curves ignored V. Round 2 tests the hypothesis
        // that a multi-layer map honors V iff all layers share one V curve —
        // which is exactly what the compositor's own two-layer map does
        // (identical physical heights per eye).
        let variants: [Variant] = [
            Variant(name: "2layer equal V-falloff both (hypothesis)",
                    layers: [subscriptLayer(h: uniform, v: falloff),
                             subscriptLayer(h: uniform, v: falloff)]),
            Variant(name: "2layer mirrored-H + equal V-falloff (multiview shape)",
                    layers: [subscriptLayer(h: rising, v: falloff),
                             subscriptLayer(h: mirrored, v: falloff)]),
            Variant(name: "2layer differing V (round-1 repro)",
                    layers: [subscriptLayer(h: uniform, v: falloff),
                             subscriptLayer(h: uniform, v: uniform)]),
        ]

        var verdicts: [String] = []
        for variant in variants {
            let desc = MTLRasterizationRateMapDescriptor()
            desc.screenSize = MTLSizeMake(screen, screen, 0)
            for (i, layer) in variant.layers.enumerated() {
                desc.setLayer(layer, at: i)
            }
            desc.label = "mv-iso \(variant.name)"
            guard let map = device.makeRasterizationRateMap(descriptor: desc) else {
                print("[mv-iso] \(variant.name): makeRasterizationRateMap returned nil")
                verdicts.append("\(variant.name): NIL")
                continue
            }
            for layer in 0..<variant.layers.count {
                let p = map.physicalSize(layer: layer)
                let corner = map.physicalCoordinates(
                    screenCoordinates: MTLCoordinate2DMake(Float(screen), Float(screen)), layer: layer)
                let mid = map.physicalCoordinates(
                    screenCoordinates: MTLCoordinate2DMake(Float(screen) / 2, Float(screen) / 2), layer: layer)
                let hShrunk = corner.x < Float(screen) * 0.99
                let vShrunk = corner.y < Float(screen) * 0.99
                print("[mv-iso] \(variant.name) layer=\(layer):"
                      + " physicalSize=\(p.width)x\(p.height)"
                      + " farCorner=\(fmt(corner.x))x\(fmt(corner.y))"
                      + " mid=\(fmt(mid.x))x\(fmt(mid.y))"
                      + " -> H \(hShrunk ? "shrunk" : "full"), V \(vShrunk ? "shrunk" : "full")")
                verdicts.append("\(variant.name)/L\(layer): H=\(hShrunk ? "s" : "F") V=\(vShrunk ? "s" : "F")")
            }
        }
        print("[mv-iso] SUMMARY: " + verdicts.joined(separator: " | "))
    }

    // MARK: - Rate map

    private static func makeTwoLayerMap(device: MTLDevice,
                                        instanced: Bool) -> MTLRasterizationRateMap? {
        let layer0 = MTLRasterizationRateLayerDescriptor(sampleCount: MTLSizeMake(zones, zones, 0))
        let layer1 = MTLRasterizationRateLayerDescriptor(sampleCount: MTLSizeMake(zones, zones, 0))
        for i in 0..<zones {
            // Distance from grid center, 0 at the middle, 1 at the edges.
            let d = abs(Float(i) - Float(zones - 1) / 2) / (Float(zones - 1) / 2)
            let rate = 1.0 - 0.75 * d   // 1.0 center -> 0.25 edge
            if instanced {
                // The measured rule (see plattformwissen): vertical must be ONE
                // shared curve across layers or Metal silently drops it.
                // Horizontal stays per-layer: layer 0 uniform, layer 1 falloff,
                // so the two slices are distinguishable on both axes.
                layer0.horizontal[i] = 1.0
                layer1.horizontal[i] = rate
                layer0.vertical[i] = rate
                layer1.vertical[i] = rate
            } else {
                // Stage-1 shape, kept verbatim for regression comparability.
                layer0.horizontal[i] = 1.0
                layer0.vertical[i] = 1.0
                layer1.horizontal[i] = rate
                layer1.vertical[i] = rate
            }
        }
        let desc = MTLRasterizationRateMapDescriptor()
        desc.screenSize = MTLSizeMake(screen, screen, 0)
        desc.setLayer(layer0, at: 0)
        desc.setLayer(layer1, at: 1)
        desc.label = "mv-spike map"
        return device.makeRasterizationRateMap(descriptor: desc)
    }

    private static func logMapGeometry(_ map: MTLRasterizationRateMap, instanced: Bool) {
        // Side quest (Stufe-0 curiosity): compare each axis's reported physical
        // size against the integral of the rates, to see whether width and
        // height quantize differently.
        var falloffSum: Float = 0
        for i in 0..<zones {
            let d = abs(Float(i) - Float(zones - 1) / 2) / (Float(zones - 1) / 2)
            falloffSum += 1.0 - 0.75 * d
        }
        let falloffInt = Int((falloffSum / Float(zones) * Float(screen)).rounded())
        for layer in 0..<2 {
            let p = map.physicalSize(layer: layer)
            let expectH: Int
            let expectV: Int
            if instanced {
                expectH = layer == 0 ? screen : falloffInt
                expectV = falloffInt
            } else {
                expectH = layer == 0 ? screen : falloffInt
                expectV = layer == 0 ? screen : falloffInt
            }
            let corner = map.physicalCoordinates(
                screenCoordinates: MTLCoordinate2DMake(Float(screen), Float(screen)), layer: layer)
            print("[mv-spike] map layer=\(layer) physicalSize=\(p.width)x\(p.height)"
                  + " rateIntegral=\(expectH)x\(expectV)"
                  + " farCorner=\(corner.x)x\(corner.y)"
                  + " granularity=\(map.physicalGranularity.width)x\(map.physicalGranularity.height)")
        }
    }

    // MARK: - Geometry

    /// Six floats per vertex: x, y (logical px), r, g, b, a.
    private static func buildBars() -> [Float] {
        var data: [Float] = []
        func quad(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, _ c: SIMD4<Float>) {
            let corners: [(Float, Float)] = [(x0, y0), (x1, y0), (x0, y1),
                                             (x1, y0), (x1, y1), (x0, y1)]
            for (x, y) in corners {
                data.append(contentsOf: [x, y, c.x, c.y, c.z, c.w])
            }
        }
        for (i, c) in barCenters.enumerated() {
            quad(c - barHalf, 0, c + barHalf, Float(screen), xBarColors[i])   // vertical, full height
            quad(32, c - barHalf, 288, c + barHalf, yBarColors[i])            // horizontal, left strip
        }
        return data
    }

    // MARK: - Readback analysis

    private static func pixel(_ p: UnsafePointer<UInt8>, base: Int, x: Int, y: Int)
        -> (Int, Int, Int) {
        let o = base + (y * screen + x) * 4
        return (Int(p[o]), Int(p[o + 1]), Int(p[o + 2]))
    }

    /// Scans one physical row (horizontalScan) or column for pixels matching
    /// `color` and returns the center of the matching run, or nil.
    private static func scanLine(_ p: UnsafePointer<UInt8>, base: Int, fixed: Int,
                                 limit: Int, horizontalScan: Bool,
                                 color: SIMD4<Float>) -> Float? {
        var first = -1
        var last = -1
        let bound = min(limit, screen)
        for i in 0..<bound {
            let (r, g, b) = horizontalScan
                ? pixel(p, base: base, x: i, y: fixed)
                : pixel(p, base: base, x: fixed, y: i)
            if abs(r - Int(color.x * 255)) < 40,
               abs(g - Int(color.y * 255)) < 40,
               abs(b - Int(color.z * 255)) < 40 {
                if first < 0 { first = i }
                last = i
            }
        }
        return first >= 0 ? Float(first + last) / 2 : nil
    }

    private static func report(layer: Int, axis: String, index: Int, expected: Float,
                               doubleWarp: Float, unshifted: Float, measured: Float?,
                               checks: inout Int, failures: inout Int) {
        checks += 1
        guard let m = measured else {
            failures += 1
            print("[mv-spike] layer=\(layer) \(axis)-bar[\(index)] NOT FOUND"
                  + " expected=\(fmt(expected)) FAIL")
            return
        }
        let delta = m - expected
        let ok = abs(delta) <= tolerance
        if !ok { failures += 1 }
        var diagnosis = ""
        if !ok {
            if abs(m - doubleWarp) <= tolerance {
                diagnosis = " <- matches DOUBLE-WARP position"
            } else if abs(m - unshifted) <= tolerance {
                diagnosis = " <- matches UNSHIFTED (amplification broken?)"
            }
        }
        print("[mv-spike] layer=\(layer) \(axis)-bar[\(index)]"
              + " expected=\(fmt(expected)) measured=\(fmt(m)) delta=\(fmt(delta))"
              + " doubleWarpWouldBe=\(fmt(doubleWarp)) \(ok ? "OK" : "FAIL")\(diagnosis)")
    }

    private static func fmt(_ v: Float) -> String {
        String(format: "%.1f", v)
    }
}
