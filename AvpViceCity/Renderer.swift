//
//  Renderer.swift
//  AvpViceCity
//
//  Created by Christian Schmid on 10.08.2026.
//

import CompositorServices
import Metal
import simd

nonisolated let maxBuffersInFlight = 3

// Debug stats overlay (GPU time + compositor interval bars). Off by default;
// enable with VC_DEBUG_STATS=1. Separate from VC_DEBUG_TRIANGLE (which only
// toggles the test triangle) — the triangle is for "nothing appears", the bars
// for "it stutters".
nonisolated let vcDebugStats = ProcessInfo.processInfo.environment["VC_DEBUG_STATS"] == "1"

// Head tracking (Phase 5, one eye): feed the left-eye CompositorServices camera
// into reVC as an offset on top of the game camera. Off by default.
//   VC_HEAD_TRACKING=1    full head pose (yaw+pitch+roll+translation)
//   VC_HEAD_TRACKING=yaw  yaw only (pitch/roll/translation zeroed) -- isolates
//                         the rotation-direction question for the swim test.
// 0 = off, 1 = full, 2 = yaw-only.
nonisolated let vcHeadTrackingMode: Int = {
    switch ProcessInfo.processInfo.environment["VC_HEAD_TRACKING"] {
    case "1":   return 1
    case "yaw": return 2
    default:    return 0
    }
}()

// The 90 Hz frame budget in milliseconds (1/90 s). Full-length bar == budget;
// longer/red means over budget.
nonisolated let vcFrameBudgetMs = 1000.0 / 90.0   // 11.1 ms

// GPU frame time is only known in the command buffer's completion handler, which
// runs off the render thread — hold it in a tiny lock-guarded box the render
// thread reads next frame.
final class FrameStats: @unchecked Sendable {
    private let lock = NSLock()
    private var _gpuMs: Double = 0
    var gpuMs: Double { lock.lock(); defer { lock.unlock() }; return _gpuMs }
    func setGPUMs(_ v: Double) { lock.lock(); _gpuMs = v; lock.unlock() }
}

extension LayerRenderer.Clock.Instant {
    nonisolated var timeInterval: TimeInterval {
        let components = LayerRenderer.Clock.Instant.epoch.duration(to: self).components
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + (nanoseconds / TimeInterval(NSEC_PER_SEC))
    }
}

final class RendererTaskExecutor: TaskExecutor {
    private let queue = DispatchQueue(label: "RenderThreadQueue", qos: .userInteractive)

    func enqueue(_ job: UnownedJob) {
        queue.async {
          job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }

    nonisolated func asUnownedSerialExecutor() -> UnownedTaskExecutor {
        return UnownedTaskExecutor(ordinary: self)
    }

    static var shared: RendererTaskExecutor = RendererTaskExecutor()
}

actor Renderer {

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    #if !targetEnvironment(simulator)
    let residencySets: [MTLResidencySet]
    #endif

    let depthState: MTLDepthStencilState

    let endFrameEvent: MTLSharedEvent
    var committedFrameIndex: UInt64 = 0

    // World-anchored quad that displays the reVC/ANGLE game texture.
    let gameQuadPipeline: MTLRenderPipelineState
    var gameSharedEvent: MTLSharedEvent?   // id<MTLSharedEvent> from the game side (lazy)
    var gameQuadVertexBuffer: MTLBuffer?   // rebuilt when the texture aspect changes
    var gameQuadAspect: Float = 0          // width/height the vertex buffer was built for
    var didLogColorFormat = false
    var didLogGameTexture = false
    var lastHeadLogTime: Double = 0   // throttles the per-second M_head translation log
    var didLogHeadTracking = false

    // Last acquired game frame, held so a failed acquire re-shows it instead of
    // going black. The held buffer is never scheduled for release while current.
    var heldTexture: MTLTexture?
    var heldIndex: UInt32 = 0
    var heldWaitValue: UInt64 = 0
    var hasHeldFrame = false

    // Debug stats bars (VC_DEBUG_STATS).
    let statsBarPipeline: MTLRenderPipelineState
    let frameStats = FrameStats()
    var statsBarVertexBuffer: MTLBuffer?
    var lastPresentationTime: Double = 0
    var smoothedIntervalMs: Double = 0     // EMA of the compositor frame interval

    // Cycles the per-frame residency set (color/depth/game texture). No longer
    // backs a uniform buffer since the template cube was removed.
    var uniformBufferIndex = 0

    let worldTracking: WorldTrackingProvider
    let layerRenderer: LayerRenderer
    let appModel: AppModel

    init(_ layerRenderer: LayerRenderer, appModel: AppModel) {
        self.layerRenderer = layerRenderer
        self.device = layerRenderer.device
        self.appModel = appModel

        let device = self.device
        self.commandQueue = self.device.makeCommandQueue()!

        // Hand the Metal device to the (future) C++ renderer across the C
        // boundary. Passed as an opaque, unretained pointer since the host
        // owns the device's lifetime.
        _ = vc_renderer_init(Unmanaged.passUnretained(self.device as AnyObject).toOpaque())

        #if !targetEnvironment(simulator)
        let residencySetDesc = MTLResidencySetDescriptor()
        residencySetDesc.initialCapacity = 3 // color + depth + view projection buffer
        self.residencySets = (0...maxBuffersInFlight).map { _ in try! device.makeResidencySet(descriptor: residencySetDesc) }
        #endif

        self.endFrameEvent = device.makeSharedEvent()!
        // Start the signal value + committed frames index at
        // max buffers in flight to avoid negative values
        self.endFrameEvent.signaledValue = UInt64(maxBuffersInFlight)
        committedFrameIndex = UInt64(maxBuffersInFlight)

        do {
            gameQuadPipeline = try Self.buildGameQuadPipeline(device: device, layerRenderer: layerRenderer)
            statsBarPipeline = try Self.buildStatsBarPipeline(device: device, layerRenderer: layerRenderer)
        } catch {
            fatalError("Unable to compile game-quad/stats pipeline state. Error info: \(error)")
        }

        self.depthState = Self.buildDepthStencilState(device: device)

        worldTracking = WorldTrackingProvider()
        print("[vc-stats] VC_DEBUG_STATS \(vcDebugStats ? "ENABLED" : "disabled"), budget=\(vcFrameBudgetMs) ms")
    }

    private func startARSession(_ arSession: ARKitSession) async {
        do {
            try await arSession.run([worldTracking])
        } catch {
            fatalError("Failed to initialize ARSession")
        }
    }

    @MainActor
    static func startRenderLoop(_ layerRenderer: LayerRenderer, appModel: AppModel, arSession: ARKitSession) {
        Task(executorPreference: RendererTaskExecutor.shared) {
            let renderer = Renderer(layerRenderer, appModel: appModel)
            await renderer.startARSession(arSession)
            await renderer.renderLoop()
        }
    }

    // Pipeline for the world-anchored game-texture quad. Renders single-sample
    // straight into the drawable's already-resolved colour/depth textures (same
    // as the test triangle), both eyes via vertex amplification.
    static func buildGameQuadPipeline(device: MTLDevice,
                                      layerRenderer: LayerRenderer) throws -> MTLRenderPipelineState {
        let library = device.makeDefaultLibrary()
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "GameQuadPipeline"
        pipelineDescriptor.vertexFunction = library?.makeFunction(name: "vc_quad_vertex")
        pipelineDescriptor.fragmentFunction = library?.makeFunction(name: "vc_quad_fragment")
        pipelineDescriptor.rasterSampleCount = 1
        pipelineDescriptor.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
        pipelineDescriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
        pipelineDescriptor.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    // Solid-colour pipeline for the debug stats bars. Same single-sample /
    // amplified setup as the quad.
    static func buildStatsBarPipeline(device: MTLDevice,
                                      layerRenderer: LayerRenderer) throws -> MTLRenderPipelineState {
        let library = device.makeDefaultLibrary()
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "StatsBarPipeline"
        pipelineDescriptor.vertexFunction = library?.makeFunction(name: "vc_bar_vertex")
        pipelineDescriptor.fragmentFunction = library?.makeFunction(name: "vc_bar_fragment")
        pipelineDescriptor.rasterSampleCount = 1
        pipelineDescriptor.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
        pipelineDescriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
        pipelineDescriptor.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    static func buildDepthStencilState(device: MTLDevice) -> MTLDepthStencilState {
        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = MTLCompareFunction.greater
        depthStateDescriptor.isDepthWriteEnabled = true
        return device.makeDepthStencilState(descriptor: depthStateDescriptor)!
    }

    private func updateDynamicBufferState() {
        /// Advance to the next per-frame residency set and reset it.

        uniformBufferIndex = (uniformBufferIndex + 1) % maxBuffersInFlight

        /// Reset resources used in previous frame

        #if !targetEnvironment(simulator)
        residencySets[uniformBufferIndex].removeAllAllocations()
        residencySets[uniformBufferIndex].commit()
        #endif
    }

    func renderFrame() {
        /// Per frame updates hare

        guard let frame = layerRenderer.queryNextFrame() else { return }

        guard self.endFrameEvent.wait(untilSignaledValue: committedFrameIndex - UInt64(maxBuffersInFlight), timeoutMS: 10000) else {
            return
        }

        frame.startUpdate()

        // Perform frame independent work

        self.updateDynamicBufferState()

        frame.endUpdate()

        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            fatalError("Failed to create command buffer")
        }

        #if !targetEnvironment(simulator)
        commandBuffer.useResidencySet(self.residencySets[uniformBufferIndex])
        #endif

        // Capture this frame's GPU time for the stats overlay (read next frame).
        if vcDebugStats {
            let stats = self.frameStats
            commandBuffer.addCompletedHandler { cb in
                stats.setGPUMs((cb.gpuEndTime - cb.gpuStartTime) * 1000.0)
            }
        }

        let drawables = frame.queryDrawables()
        guard !drawables.isEmpty else { return }

        // Compositor frame interval (mean via EMA) — updated for every presented
        // frame, including the no-anchor path below, so dropped frames show up.
        if vcDebugStats {
            let pt = drawables[0].frameTiming.presentationTime.timeInterval
            if lastPresentationTime > 0 {
                let dtMs = (pt - lastPresentationTime) * 1000.0
                smoothedIntervalMs = smoothedIntervalMs == 0 ? dtMs : smoothedIntervalMs * 0.9 + dtMs * 0.1
            }
            lastPresentationTime = pt
        }

        // The frame is already in flight the moment queryDrawables() ran above, so
        // we must NOT bail out here — that leaks it ("more than 3 frames in
        // flight"), and the system kills an immersive app that stops presenting.
        // If world tracking has no pose yet (ARKit still coming up), we can't
        // render correctly, but a blank frame is better than none: present an
        // empty (black) frame so the pipeline keeps flowing.
        let presentationTime = drawables[0].frameTiming.presentationTime.timeInterval
        guard let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: presentationTime) else {
            frame.startSubmission()
            for drawable in drawables {
                let clearPass = MTLRenderPassDescriptor()
                clearPass.colorAttachments[0].texture = drawable.colorTextures[0]
                clearPass.colorAttachments[0].loadAction = .clear
                clearPass.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
                clearPass.colorAttachments[0].storeAction = .store
                clearPass.rasterizationRateMap = drawable.rasterizationRateMaps.first
                if layerRenderer.configuration.layout == .layered {
                    clearPass.renderTargetArrayLength = drawable.views.count
                }
                // Encode just the clear, then present so the frame is completed.
                if let clearEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: clearPass) {
                    clearEncoder.label = "Empty frame (awaiting device anchor)"
                    clearEncoder.endEncoding()
                }
                drawable.encodePresent(commandBuffer: commandBuffer)
            }
            committedFrameIndex += 1
            commandBuffer.encodeSignalEvent(self.endFrameEvent, value: committedFrameIndex)
            commandBuffer.commit()
            frame.endSubmission()
            return
        }

        frame.startSubmission()

        for drawable in drawables {
            render(drawable: drawable, deviceAnchor: deviceAnchor, commandBuffer: commandBuffer)
        }

        // Hand the frame to the (future) C++ renderer once per frame, from
        // within the submission phase and sharing this frame's command buffer.
        submitFrameToVCRenderer(drawable: drawables[0], commandBuffer: commandBuffer)

        // Acquire the latest finished game texture and draw it on a world-anchored
        // quad. Gates the quad pass on the game's GPU (shared event) and returns
        // the buffer only once this command buffer has finished reading it.
        renderGameQuad(drawables: drawables, commandBuffer: commandBuffer)

        // Debug overlay: GPU-time + compositor-interval bars below the screen.
        if vcDebugStats {
            renderStatsBars(drawables: drawables, commandBuffer: commandBuffer)
        }

        // Present LAST: base clear, optional triangle, game quad and stats bars
        // are all encoded above. Anything encoded AFTER encodePresent never
        // reaches the display, so presentation must come after every content pass.
        for drawable in drawables {
            drawable.encodePresent(commandBuffer: commandBuffer)
        }

        committedFrameIndex += 1

        commandBuffer.encodeSignalEvent(self.endFrameEvent, value: committedFrameIndex)

        commandBuffer.commit()

        frame.endSubmission()
    }

    func render(drawable: LayerRenderer.Drawable, deviceAnchor: DeviceAnchor, commandBuffer: MTLCommandBuffer) {
        drawable.deviceAnchor = deviceAnchor

        // Base pass: clear the drawable's colour/depth so the (optional) test
        // triangle and the game quad can .load onto a clean target. Presentation
        // happens once, AFTER all content passes (see renderFrame) — never here.
        // Colour alpha stays 0 so passthrough shows around the screen; depth is
        // reverse-Z (clear 0). Single-sample straight into the drawable textures
        // (the removed template cube was the only MSAA user).
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.colorTextures[0]
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.depthAttachment.texture = drawable.depthTextures[0]
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.clearDepth = 0.0
        renderPassDescriptor.depthAttachment.storeAction = .store
        renderPassDescriptor.rasterizationRateMap = drawable.rasterizationRateMaps.first
        if layerRenderer.configuration.layout == .layered {
            renderPassDescriptor.renderTargetArrayLength = drawable.views.count
        }

        #if !targetEnvironment(simulator)
        let residencySet = self.residencySets[uniformBufferIndex]
        residencySet.addAllocations([drawable.colorTextures[0], drawable.depthTextures[0]])
        residencySet.commit()
        #endif

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }
        renderEncoder.label = "Base Clear Encoder"
        renderEncoder.endEncoding()
    }

    /// Populate a `vc_frame_t` from the current drawable and pass it across the
    /// C boundary to the (future) C++ renderer. All Metal objects are handed
    /// over as opaque, unretained pointers valid only for the duration of the
    /// call. Per-eye matrices are derived exactly as the Metal path does.
    /// Convert the left-eye CompositorServices camera to librw convention and push
    /// it as a head-pose OFFSET (compose mode) on top of the game camera:
    /// V_final = M_head · V_game. The game camera (third-person, from the gamepad)
    /// is preserved; the head only adds a look-around on top, so Tommy stays put in
    /// the world and wanders out of frame as you turn.
    /// Projection: P_out = D·P_cs·F (F: librw +Z eye -> Metal -Z; D: clip depth
    /// 0..1 -> -1..1). Offset: M_head = F·V_cs·F (basis-change similarity of the
    /// Metal head view into librw eye space; proper rotation, no mirroring).
    /// This is coherent only with a HEAD-LOCKED quad (see renderGameQuad): a
    /// world-anchored quad would count the head motion twice.
    /// Runs on the render thread per host frame; the reVC side buffers under a lock.
    private func pushHeadMatrices(drawable: LayerRenderer.Drawable, yawOnly: Bool) {
        if !didLogHeadTracking {
            didLogHeadTracking = true
            let kind = yawOnly ? "yaw only" : "full pose"
            print("[vc-head] head tracking ENABLED (\(kind), left eye -> game-camera offset, compose)")
        }

        let anchor = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        // eye->world pose (Metal RH, -Z). This is a POSE, not a view matrix; the
        // view is its inverse (below).
        var eyePose = anchor * drawable.views[0].transform

        if yawOnly {
            // Keep only the heading (rotation about world up, +Y); drop pitch,
            // roll, and translation. The eye looks down -Z, so its forward in
            // world space is -(pose.col2). Project onto the XZ plane and rebuild
            // a pure +Y rotation that reproduces exactly that heading, so the
            // yaw sign is preserved through the same conversion below.
            let fwd = -SIMD3<Float>(eyePose.columns.2.x, eyePose.columns.2.y, eyePose.columns.2.z)
            // R_y(a) maps (0,0,-1) -> (-sin a, 0, -cos a); solve for a from fwd.
            let a = atan2(-fwd.x, -fwd.z)
            eyePose = simd_float4x4(simd_quatf(angle: a, axis: SIMD3<Float>(0, 1, 0)))
        }

        let vCS = eyePose.inverse                                  // world -> eye (Metal RH, -Z)
        let pCS = drawable.computeProjection(viewIndex: 0)          // Metal RH, -Z, depth 0..1

        let F = simd_float4x4(diagonal: SIMD4<Float>(1, 1, -1, 1))  // Z flip, F == F^-1
        // Depth remap clip z: 0..1 (Metal) -> -1..1 (GL): z' = 2z - w. Column-major.
        let D = simd_float4x4(columns: (SIMD4<Float>(1, 0, 0, 0),
                                        SIMD4<Float>(0, 1, 0, 0),
                                        SIMD4<Float>(0, 0, 2, 0),
                                        SIMD4<Float>(0, 0, -1, 1)))

        // Head offset in librw eye convention. It is a change-of-basis
        // (similarity) of the Metal head view V_cs by F, i.e. M_head = F·V_cs·F --
        // a proper rotation (det +1), so no mirroring. (The earlier "raw V_cs"
        // variant was only compensating for double-counted head motion from the
        // world-anchored quad; the quad is head-locked now, so the compensation is
        // gone and the convention form is restored.)
        let mHead = F * vCS * F
        let pOut  = D * pCS * F      // projection, librw convention (+Z eye, depth -1..1)

        // Once per second: the translation of the head offset in metres. Values
        // near my distance to the ARKit origin -> missing recenter (a); values
        // that are implausible or track with head motion -> translation-conversion
        // bug (b).
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastHeadLogTime >= 1.0 {
            lastHeadLogTime = now
            print(String(format: "[vc-head] M_head translation (m): x=%.3f y=%.3f z=%.3f",
                         mHead.columns.3.x, mHead.columns.3.y, mHead.columns.3.z))
        }

        func flat(_ m: simd_float4x4) -> [Float] {
            [m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
             m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
             m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
             m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w]
        }
        vc_set_view_matrix(flat(mHead))
        vc_set_projection_matrix(flat(pOut))
        vc_set_view_compose(1)
        vc_set_matrix_override(1)
    }

    private func submitFrameToVCRenderer(drawable: LayerRenderer.Drawable, commandBuffer: MTLCommandBuffer) {
        if vcHeadTrackingMode != 0 {
            pushHeadMatrices(drawable: drawable, yawOnly: vcHeadTrackingMode == 2)
        }

        let simdDeviceAnchor = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4

        func makeEye(_ viewIndex: Int) -> vc_eye_t {
            let view = drawable.views[viewIndex]
            let viewMatrix = (simdDeviceAnchor * view.transform).inverse
            let projectionMatrix = drawable.computeProjection(viewIndex: viewIndex)
            return vc_eye_t(view: viewMatrix, projection: projectionMatrix, slice: UInt32(viewIndex))
        }

        var frame = vc_frame_t()
        let viewCount = min(drawable.views.count, 2)
        frame.eye_count = UInt32(viewCount)
        if viewCount > 0 { frame.eyes.0 = makeEye(0) }
        if viewCount > 1 { frame.eyes.1 = makeEye(1) }

        frame.color_texture = Unmanaged.passUnretained(drawable.colorTextures[0] as AnyObject).toOpaque()
        frame.depth_texture = Unmanaged.passUnretained(drawable.depthTextures[0] as AnyObject).toOpaque()
        if let rateMap = drawable.rasterizationRateMaps.first {
            frame.rate_map = Unmanaged.passUnretained(rateMap as AnyObject).toOpaque()
        } else {
            frame.rate_map = nil
        }
        frame.command_buffer = Unmanaged.passUnretained(commandBuffer as AnyObject).toOpaque()
        frame.presentation_time = drawable.frameTiming.presentationTime.timeInterval

        withUnsafePointer(to: &frame) { vc_renderer_render($0) }
    }

    /// Build the world-anchored quad vertices (triangle strip: BL, BR, TL, TR)
    /// for the given texture aspect. Positions are WORLD space, ~2.5 m in front
    /// at eye height, sized from the aspect (never hardcoded). V is flipped so a
    /// GL (bottom-left origin) render target reads upright when sampled by Metal
    /// (top-left origin). Layout per vertex: packed_float3 pos + packed_float2 uv.
    private func gameQuadVertices(aspect: Float) -> [Float] {
        let halfHeight: Float = 0.75          // 1.5 m tall
        let halfWidth = halfHeight * aspect
        // World-anchored: 1.15 m above the floor origin (eye height in the room).
        // Head-locked (head tracking on): the origin IS the head, so centre at
        // eye level (cy = 0), otherwise the screen sits 1.15 m above the eyes.
        let cx: Float = 0.0
        let cy: Float = vcHeadTrackingMode != 0 ? 0.0 : 1.15
        let cz: Float = -2.5
        return [
            cx - halfWidth, cy - halfHeight, cz,  0.0, 0.0,   // bottom-left
            cx + halfWidth, cy - halfHeight, cz,  1.0, 0.0,   // bottom-right
            cx - halfWidth, cy + halfHeight, cz,  0.0, 1.0,   // top-left
            cx + halfWidth, cy + halfHeight, cz,  1.0, 1.0,   // top-right
        ]
    }

    /// Draw the game texture on the world-anchored quad, both eyes in one
    /// vertex-amplified pass. Tries to acquire a fresh frame each compositor
    /// frame; on failure it re-shows the last held frame (no black, no flicker).
    /// Black only until the very first frame has ever been acquired.
    private func renderGameQuad(drawables: [LayerRenderer.Drawable], commandBuffer: MTLCommandBuffer) {
        if !didLogColorFormat {
            didLogColorFormat = true
            let fmt = layerRenderer.configuration.colorFormat
            print("[vc-quad] drawable colorFormat rawValue=\(fmt.rawValue) isRGBA16Float=\(fmt == .rgba16Float)")
        }

        // The game side may not have created the shared event yet at init time.
        if gameSharedEvent == nil, let evPtr = vc_get_shared_event() {
            gameSharedEvent = (Unmanaged<AnyObject>.fromOpaque(evPtr).takeUnretainedValue() as! MTLSharedEvent)
        }

        var ready = vc_ready_frame_t()
        if vc_acquire_ready_frame(&ready), let texPtr = ready.texture {
            // Got a fresh frame. Release the PREVIOUS held buffer once THIS
            // command buffer finishes: it runs in-order after every cb that
            // sampled the old texture, so the old one is guaranteed no longer in
            // use. The buffer we keep displaying is never scheduled for release —
            // that is exactly what lets a failed acquire re-show it safely.
            if hasHeldFrame {
                let oldIndex = heldIndex
                commandBuffer.addCompletedHandler { _ in vc_release_frame(oldIndex) }
            }

            heldTexture = Unmanaged<AnyObject>.fromOpaque(texPtr).takeUnretainedValue() as? MTLTexture
            heldIndex = ready.index
            heldWaitValue = ready.wait_value
            hasHeldFrame = true

            if !didLogGameTexture, let t = heldTexture {
                didLogGameTexture = true
                print("[vc-quad] game texture \(t.width)x\(t.height) pixelFormat=\(t.pixelFormat.rawValue) sameDeviceAsHost=\(t.device.registryID == device.registryID)")
            }

            // Rebuild the quad vertices only when the texture aspect changes.
            let aspect = ready.height > 0 ? Float(ready.width) / Float(ready.height) : 1.0
            if gameQuadVertexBuffer == nil || gameQuadAspect != aspect {
                let verts = gameQuadVertices(aspect: aspect)
                gameQuadVertexBuffer = verts.withUnsafeBytes {
                    device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [.storageModeShared])
                }
                gameQuadVertexBuffer?.label = "GameQuadVertices"
                gameQuadAspect = aspect
            }
        }

        // Nothing to show until the first-ever acquire; then always show the held
        // frame (fresh this frame, or re-shown on a failed acquire).
        guard hasHeldFrame, let gameTexture = heldTexture, let quadVertexBuffer = gameQuadVertexBuffer else {
            return
        }
        let waitValue = heldWaitValue

        // Gate the quad pass on the game's GPU. Skip when there is no event
        // (fallback path) or no value (VC_NOFENCE) — waiting on a value that is
        // never signalled would stall the frame.
        if let event = gameSharedEvent, waitValue != 0 {
            commandBuffer.encodeWaitForEvent(event, value: waitValue)
        }

        for drawable in drawables {
            let renderPassDescriptor = MTLRenderPassDescriptor()
            renderPassDescriptor.colorAttachments[0].texture = drawable.colorTextures[0]
            renderPassDescriptor.colorAttachments[0].loadAction = .load
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            renderPassDescriptor.depthAttachment.texture = drawable.depthTextures[0]
            renderPassDescriptor.depthAttachment.loadAction = .load
            renderPassDescriptor.depthAttachment.storeAction = .store
            renderPassDescriptor.rasterizationRateMap = drawable.rasterizationRateMaps.first
            if layerRenderer.configuration.layout == .layered {
                renderPassDescriptor.renderTargetArrayLength = drawable.views.count
            }

            #if !targetEnvironment(simulator)
            let residencySet = self.residencySets[uniformBufferIndex]
            residencySet.addAllocations([gameTexture, quadVertexBuffer])
            residencySet.commit()
            #endif

            guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                return
            }
            renderEncoder.label = "Game Quad Encoder"
            renderEncoder.setCullMode(.none)
            renderEncoder.setRenderPipelineState(gameQuadPipeline)
            renderEncoder.setDepthStencilState(depthState)

            let viewports = drawable.views.map { $0.textureMap.viewport }
            renderEncoder.setViewports(viewports)

            if drawable.views.count > 1 {
                var viewMappings = (0..<drawable.views.count).map {
                    MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                      renderTargetArrayIndexOffset: UInt32($0))
                }
                renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
            }

            // Per-eye view-projection (world -> clip), same derivation as the cube.
            let simdDeviceAnchor = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
            var viewProjection = [matrix_identity_float4x4, matrix_identity_float4x4]
            for i in 0..<min(drawable.views.count, 2) {
                let view = drawable.views[i]
                // While head tracking is active, HEAD-LOCK the quad: drop the
                // device-anchor (world) part so the screen stays glued to the head.
                // This neutralizes the compositor's own head tracking of the quad --
                // otherwise the head motion is counted twice (once moving the quad in
                // the room, once in the composed game camera) and no M_head sign can
                // ever look right. Normal cinema keeps the quad world-anchored.
                let viewMatrix: simd_float4x4 = vcHeadTrackingMode != 0
                    ? view.transform.inverse
                    : (simdDeviceAnchor * view.transform).inverse
                let projectionMatrix = drawable.computeProjection(viewIndex: i)
                viewProjection[i] = projectionMatrix * viewMatrix
            }
            renderEncoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
            renderEncoder.setVertexBytes(&viewProjection,
                                         length: MemoryLayout<matrix_float4x4>.stride * 2,
                                         index: 1)
            renderEncoder.setFragmentTexture(gameTexture, index: 0)

            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            renderEncoder.endEncoding()
        }
    }

    /// Two world-anchored bars (triangle strips) below the screen: a thicker one
    /// for GPU time, a thinner one below it for the compositor interval. Length is
    /// value/budget (full == 11.1 ms). Positions in WORLD space, z on the screen
    /// plane. 3 floats per vertex (packed_float3), 8 verts = two strips.
    private func statsBarVertices(gpuFrac: Float, intervalFrac: Float) -> [Float] {
        let x0: Float = -0.25, maxLen: Float = 0.5, z: Float = -2.5   // full length 0.5 m
        // GPU bar (thicker), just below the screen's bottom edge (~y 0.40).
        let g0: Float = 0.340, g1: Float = 0.360
        let gx = x0 + gpuFrac * maxLen
        // Interval bar (thinner), a touch lower.
        let i0: Float = 0.315, i1: Float = 0.325
        let ix = x0 + intervalFrac * maxLen
        return [
            x0, g0, z,  gx, g0, z,  x0, g1, z,  gx, g1, z,   // GPU strip: BL,BR,TL,TR
            x0, i0, z,  ix, i0, z,  x0, i1, z,  ix, i1, z,   // interval strip
        ]
    }

    private func renderStatsBars(drawables: [LayerRenderer.Drawable], commandBuffer: MTLCommandBuffer) {
        let gpuMs = frameStats.gpuMs
        let intervalMs = smoothedIntervalMs
        let gpuFrac = Float(min(max(gpuMs / vcFrameBudgetMs, 0.0), 1.5))
        let intervalFrac = Float(min(max(intervalMs / vcFrameBudgetMs, 0.0), 1.5))
        // Green under budget, red over. Linear RGB (drawable is linear RGBA16F).
        var gpuColor = gpuMs <= vcFrameBudgetMs ? SIMD4<Float>(0, 1, 0, 1) : SIMD4<Float>(1, 0, 0, 1)
        var intervalColor = intervalMs <= vcFrameBudgetMs ? SIMD4<Float>(0, 0.7, 1, 1) : SIMD4<Float>(1, 0, 0, 1)

        let verts = statsBarVertices(gpuFrac: gpuFrac, intervalFrac: intervalFrac)
        let barBuffer = verts.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [.storageModeShared])
        }
        guard let barBuffer else { return }
        barBuffer.label = "StatsBarVertices"

        for drawable in drawables {
            let renderPassDescriptor = MTLRenderPassDescriptor()
            renderPassDescriptor.colorAttachments[0].texture = drawable.colorTextures[0]
            renderPassDescriptor.colorAttachments[0].loadAction = .load
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            renderPassDescriptor.depthAttachment.texture = drawable.depthTextures[0]
            renderPassDescriptor.depthAttachment.loadAction = .load
            renderPassDescriptor.depthAttachment.storeAction = .store
            renderPassDescriptor.rasterizationRateMap = drawable.rasterizationRateMaps.first
            if layerRenderer.configuration.layout == .layered {
                renderPassDescriptor.renderTargetArrayLength = drawable.views.count
            }

            #if !targetEnvironment(simulator)
            let residencySet = self.residencySets[uniformBufferIndex]
            residencySet.addAllocations([barBuffer])
            residencySet.commit()
            #endif

            guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                return
            }
            renderEncoder.label = "Stats Bars Encoder"
            renderEncoder.setCullMode(.none)
            renderEncoder.setRenderPipelineState(statsBarPipeline)
            renderEncoder.setDepthStencilState(depthState)

            let viewports = drawable.views.map { $0.textureMap.viewport }
            renderEncoder.setViewports(viewports)
            if drawable.views.count > 1 {
                var viewMappings = (0..<drawable.views.count).map {
                    MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                      renderTargetArrayIndexOffset: UInt32($0))
                }
                renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
            }

            let simdDeviceAnchor = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
            var viewProjection = [matrix_identity_float4x4, matrix_identity_float4x4]
            for i in 0..<min(drawable.views.count, 2) {
                let view = drawable.views[i]
                let viewMatrix = (simdDeviceAnchor * view.transform).inverse
                viewProjection[i] = drawable.computeProjection(viewIndex: i) * viewMatrix
            }
            renderEncoder.setVertexBuffer(barBuffer, offset: 0, index: 0)
            renderEncoder.setVertexBytes(&viewProjection,
                                         length: MemoryLayout<matrix_float4x4>.stride * 2, index: 1)

            // GPU bar (verts 0..3), then interval bar (verts 4..7); colour per draw.
            renderEncoder.setFragmentBytes(&gpuColor, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            renderEncoder.setFragmentBytes(&intervalColor, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 4, vertexCount: 4)

            renderEncoder.endEncoding()
        }
    }

    func renderLoop() {
        while true {
            if layerRenderer.state == .invalidated {
                print("Layer is invalidated")
                Task { @MainActor in
                    appModel.immersiveSpaceState = .closed
                }
                return
            } else if layerRenderer.state == .paused {
                Task { @MainActor in
                    appModel.immersiveSpaceState = .inTransition
                }
                layerRenderer.waitUntilRunning()
                continue
            } else {
                Task { @MainActor in
                    if appModel.immersiveSpaceState != .open {
                        appModel.immersiveSpaceState = .open
                    }
                }
                autoreleasepool {
                    self.renderFrame()
                }
            }
        }
    }
}

