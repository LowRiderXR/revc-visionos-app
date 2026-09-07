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

// Stereo display bisection: paint eye0 red / eye1 green instead of sampling the
// game texture, to tell "pass broken" from "sampling broken". Off by default.
nonisolated let vcStereoTestFill = ProcessInfo.processInfo.environment["VC_STEREO_TESTFILL"] == "1"

// Throttle for the (off-thread) command-buffer error logger.
nonisolated(unsafe) var vcLastCBErrorLog: Double = 0

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

// Distance (metres) of the STEREO display quad from the head. At a near distance
// the quad's own plane adds a fixed convergence on top of the disparity already
// baked into the two slices -- the "behind glass" 3D-cinema feel. Placing it far
// (ALVR/Klepton use 500 m) makes the plane's disparity vanish, so perceived depth
// comes only from the slice content = volumetric. Cinema is unaffected (its quad
// stays at 2.5 m). Tunable so a too-far quad clipped past the compositor far plane
// (reverse-Z -> black) can be pulled back on device. VC_CANVAS_DEPTH, default 500.
nonisolated let vcCanvasDepth: Float = {
    if let s = ProcessInfo.processInfo.environment["VC_CANVAS_DEPTH"], let d = Float(s), d > 0 {
        return d
    }
    return 500.0
}()

// Stereo head-look (V_final = M_head · V_game). Default on. VC_STEREO_HEADLOOK=0
// turns it off (screen head-locked, scene fixed) to A/B whether the head-driven
// game camera is what makes every other frame's setup phase expensive (the 45 Hz).
nonisolated let vcStereoHeadLook: Bool = {
    ProcessInfo.processInfo.environment["VC_STEREO_HEADLOOK"] != "0"
}()

// Reproject-from-render-pose fix: report drawable.deviceAnchor as the pose the displayed
// slice was RENDERED with (matched via pose_set_time), not the current pose, so the
// compositor reprojects the flat slice from its true render pose -> kills the head-turn
// double image. Default on; VC_REPROJ_FIX=0 to A/B against the old (current-pose) behaviour.
nonisolated let vcReprojFix: Bool = {
    ProcessInfo.processInfo.environment["VC_REPROJ_FIX"] != "0"
}()

// After a splash ends, the world slices were SUPPRESSED (stale = old gameplay); the compositor
// may show a buffered stale slice for a frame or two before the fresh black fade-in slices
// arrive -> a brief gameplay flash (a race, "not every time"). Hold BLACK for this many frames
// past the splash to cover the pipeline depth. VC_SPLASH_HOLD_FRAMES.
nonisolated let vcSplashHoldFrames: Int = {
    if let s = ProcessInfo.processInfo.environment["VC_SPLASH_HOLD_FRAMES"], let n = Int(s), n >= 0 { return n }
    return 4
}()

// Stereo HUD layer (Phase 5.6, approach B). The 2D/HUD/menu overlay is rendered by
// reVC into a SEPARATE transparent buffer (hud_texture) and drawn here as its own
// HEAD-LOCKED quad over the world slices. Unlike the world (pushed far so its baked
// disparity dominates), the HUD is a flat 2D image, so it sits at a comfortable
// reading distance with normal convergence. VC_HUD_DEPTH = metres from the head
// (default 1.8). VC_HUD_SIZE = fraction of the vertical FOV the quad fills at that
// depth (default 1.0 = full FOV, i.e. same coverage as the flat screen); shrink it
// to pull the corners (radar, cash) into comfortable central view.
nonisolated let vcHudDepth: Float = {
    if let s = ProcessInfo.processInfo.environment["VC_HUD_DEPTH"], let d = Float(s), d > 0 {
        return d
    }
    return 1.8
}()
nonisolated let vcHudSize: Float = {
    if let s = ProcessInfo.processInfo.environment["VC_HUD_SIZE"], let d = Float(s), d > 0 {
        return d
    }
    return 1.0
}()
// Draw the stereo HUD overlay at all. Default on. VC_HUD=0 disables it, to A/B
// whether a black screen is the HUD layer covering the world (overlay opaque) vs a
// break in the world path itself.
nonisolated let vcHudEnabled: Bool = {
    ProcessInfo.processInfo.environment["VC_HUD"] != "0"
}()

// In-game menu panel (stereo). While the pause menu is up, the SAME overlay buffer
// holds only the menu (the in-game block incl. HUD is skipped game-side), so we draw
// it on a WORLD-ANCHORED quad frozen at the head pose captured when the menu opened
// -- it appears in front of you and stays put like a screen in the room. VC_MENU_DEPTH
// = metres from that frozen pose (default 2.0). VC_MENU_SIZE = fraction of the vertical
// FOV the panel fills at that depth when it opens (default 1.0).
nonisolated let vcMenuDepth: Float = {
    if let s = ProcessInfo.processInfo.environment["VC_MENU_DEPTH"], let d = Float(s), d > 0 {
        return d
    }
    return 2.0
}()
nonisolated let vcMenuSize: Float = {
    if let s = ProcessInfo.processInfo.environment["VC_MENU_SIZE"], let d = Float(s), d > 0 {
        return d
    }
    return 1.0
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
    // Stereo pipeline: the 2D-array game texture on a world-anchored screen
    // projected per eye (slice per eye), single vertex-amplified pass.
    let gameStereoPipeline: MTLRenderPipelineState
    // Same, with the test-fill fragment (VC_STEREO_TESTFILL).
    let gameStereoTestPipeline: MTLRenderPipelineState
    // Stereo HUD layer: the transparent 2D overlay on a head-locked quad, blended
    // over the world slices (premultiplied alpha). Reuses the cinema quad shaders.
    let gameHudPipeline: MTLRenderPipelineState
    // Depth-disabled state for the full-screen stereo blit (always fills).
    let noDepthState: MTLDepthStencilState
    var didSetRenderQuality = false        // one-time: raise renderQuality + log the rate map
    var lastHostMemLog: Double = 0         // throttle for the host-device memory probe
    var gameSharedEvent: MTLSharedEvent?   // id<MTLSharedEvent> from the game side (lazy)
    var gameQuadVertexBuffer: MTLBuffer?   // cinema quad, rebuilt when the texture aspect changes
    var gameQuadAspect: Float = 0          // width/height the cinema vertex buffer was built for
    var stereoScreenVertexBuffer: MTLBuffer?  // stereo quad (far distance), rebuilt on aspect change
    var stereoScreenAspect: Float = 0         // width/height the stereo vertex buffer was built for
    var hudQuadVertexBuffer: MTLBuffer?       // head-locked HUD quad, rebuilt on aspect change
    var hudQuadAspect: Float = 0              // width/height the HUD vertex buffer was built for
    var menuQuadVertexBuffer: MTLBuffer?      // head-locked menu panel quad (own depth/size)
    var menuQuadAspect: Float = 0
    var splashScreenVertexBuffer: MTLBuffer?  // head-locked full-FOV splash quad at menu depth
    var splashScreenAspect: Float = 0
    var splashHoldFrames = 0                   // black-hold countdown after a splash (stale-slice race)
    var didLogColorFormat = false
    // Log the texture description once PER eye_count, not globally: otherwise the
    // first mono (menu) frame permanently swallows the stereo description.
    var loggedGameTexEyeCounts: Set<UInt32> = []
    var lastHeadLogTime: Double = 0   // throttles the per-second M_head translation log
    var didLogHeadTracking = false

    // Last acquired game frame, held so a failed acquire re-shows it instead of
    // going black. The held buffer is never scheduled for release while current.
    var heldTexture: MTLTexture?
    var heldHudTexture: MTLTexture?        // stereo HUD overlay for the held frame (nil in cinema)
    var frozenWorldTexture: MTLTexture?    // world slices frozen at menu-open (paused = no eye passes)
    var heldIndex: UInt32 = 0
    var heldWaitValue: UInt64 = 0
    var hasHeldFrame = false
    var heldEyeCount: UInt32 = 1           // 1 = mono/cinema, 2 = stereo array; drives the display path
    var didLogStereoDisplay = false


    // Render-pose reprojection fix: ring of the DeviceAnchor each head pose was pushed
    // with, keyed by vc_last_pushed_pose_time(). The displayed buffer carries
    // pose_set_time; we look up its anchor A and report it as drawable.deviceAnchor so the
    // compositor reprojects from A (survives 4-deep buffering + recycling: the key rides
    // the buffer through publish/acquire). heldRenderAnchor persists across re-shows.
    var renderAnchorRing: [(key: UInt64, anchor: DeviceAnchor)] = []
    var heldRenderAnchor: DeviceAnchor?
    var lastPathLogTime: Double = 0        // throttles the per-frame path/branch diagnostic
    var lastStereoDrawLogTime: Double = 0  // throttles the "stereo drew this frame" diagnostic
    var lastPresentLogTime: Double = 0     // throttles the present/empty-path anchor diagnostic

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
            gameStereoPipeline = try Self.buildGameStereoPipeline(device: device, layerRenderer: layerRenderer,
                                                                  vertex: "vc_stereo_vertex",
                                                                  fragment: "vc_stereo_fragment")
            gameStereoTestPipeline = try Self.buildGameStereoPipeline(device: device, layerRenderer: layerRenderer,
                                                                      vertex: "vc_stereo_vertex",
                                                                      fragment: "vc_stereo_fragment_testfill")
            gameHudPipeline = try Self.buildHudPipeline(device: device, layerRenderer: layerRenderer)
            statsBarPipeline = try Self.buildStatsBarPipeline(device: device, layerRenderer: layerRenderer)
        } catch {
            fatalError("Unable to compile game-quad/stereo/stats pipeline state. Error info: \(error)")
        }

        self.depthState = Self.buildDepthStencilState(device: device)
        self.noDepthState = Self.buildNoDepthStencilState(device: device)

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

    // Full-screen stereo pipeline: samples the 2D-array game texture (slice per
    // eye) with no geometry/uniforms. Same single-sample / amplified setup as the
    // quad so both eyes render in one pass.
    static func buildGameStereoPipeline(device: MTLDevice,
                                        layerRenderer: LayerRenderer,
                                        vertex: String,
                                        fragment: String) throws -> MTLRenderPipelineState {
        let library = device.makeDefaultLibrary()
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "GameStereoPipeline(\(vertex),\(fragment))"
        pipelineDescriptor.vertexFunction = library?.makeFunction(name: vertex)
        pipelineDescriptor.fragmentFunction = library?.makeFunction(name: fragment)
        pipelineDescriptor.rasterSampleCount = 1
        pipelineDescriptor.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
        pipelineDescriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
        pipelineDescriptor.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    // HUD-overlay pipeline: the cinema quad shaders (2D texture) with ALPHA BLENDING
    // enabled, so the transparent HUD buffer composites over the world slices. The
    // HUD buffer is accumulated by reVC's 2D pass (src-over into a zero-cleared
    // buffer), so its stored colour is already PREMULTIPLIED by coverage -> composite
    // with premultiplied "over" (srcRGB factor = 1, dstRGB factor = 1 - srcAlpha).
    // Partial-alpha edges are slightly off (reVC blends alpha with SRC_ALPHA, not
    // ONE, so accumulated coverage is a touch low) but opaque HUD is exact.
    static func buildHudPipeline(device: MTLDevice,
                                 layerRenderer: LayerRenderer) throws -> MTLRenderPipelineState {
        let library = device.makeDefaultLibrary()
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "GameHudPipeline"
        pipelineDescriptor.vertexFunction = library?.makeFunction(name: "vc_quad_vertex")
        pipelineDescriptor.fragmentFunction = library?.makeFunction(name: "vc_quad_fragment")
        pipelineDescriptor.rasterSampleCount = 1
        let ca = pipelineDescriptor.colorAttachments[0]!
        ca.pixelFormat = layerRenderer.configuration.colorFormat
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add
        ca.alphaBlendOperation = .add
        ca.sourceRGBBlendFactor = .one                     // premultiplied colour
        ca.sourceAlphaBlendFactor = .one
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
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

    // Depth-disabled state for the full-screen stereo blit: always passes, never
    // writes, so the game image fills the eye regardless of the depth buffer.
    static func buildNoDepthStencilState(device: MTLDevice) -> MTLDepthStencilState {
        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = MTLCompareFunction.always
        d.isDepthWriteEnabled = false
        return device.makeDepthStencilState(descriptor: d)!
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

        // A command-buffer error blanks the WHOLE frame (base clear included), so
        // "everything black once stereo is on" could be a runtime error at commit.
        // Log it (throttled) -- silent when there is none.
        commandBuffer.addCompletedHandler { cb in
            if cb.status == .error, let e = cb.error {
                let now = CFAbsoluteTimeGetCurrent()
                if now - vcLastCBErrorLog >= 1.0 {
                    vcLastCBErrorLog = now
                    print("[vc-quad] COMMAND BUFFER ERROR: \((e as NSError).domain) code=\((e as NSError).code) \(e.localizedDescription)")
                }
            }
        }

        // Capture this frame's GPU time for the stats overlay (read next frame).
        if vcDebugStats {
            let stats = self.frameStats
            commandBuffer.addCompletedHandler { cb in
                stats.setGPUMs((cb.gpuEndTime - cb.gpuStartTime) * 1000.0)
            }
        }

        let drawables = frame.queryDrawables()
        guard !drawables.isEmpty else { return }

        // Leak split: the C [vc-mem] logs the ANGLE device (g_mtlDevice). This logs the HOST
        // (compositor/Swift) device. Same value & both grow -> one shared device (leak could
        // be compositor drawables too); only ANGLE grows -> the leak is reVC/ANGLE-side.
        do {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastHostMemLog >= 2.0 {
                lastHostMemLog = now
                print(String(format: "[vc-mem-host] hostDevice.currentAllocatedSize=%llu MB", UInt64(device.currentAllocatedSize) / 1_000_000))
            }
        }

        // visionOS 26 render quality (the real PPD lever above the old 26-PPD FFR cap). Set the
        // per-frame renderQuality (GPU cost) high; the ceiling is configuration.maxRenderQuality
        // (set in makeConfiguration). Then log the rate map: if physicalSize / the drawable
        // texture grew, the drawable now rasterizes more pixels and we need higher slice res.
        if !didSetRenderQuality {
            didSetRenderQuality = true
            // renderQuality MUST NOT exceed maxRenderQuality or CompositorServices aborts
            // ("abort with payload or reason"). When VC_MAX_RENDER_QUALITY=off we left
            // maxRenderQuality at the system default, so DON'T force renderQuality up; else
            // clamp it to the maxRenderQuality we set in makeConfiguration.
            let mqEnv = ProcessInfo.processInfo.environment["VC_MAX_RENDER_QUALITY"]
            if mqEnv == "off" {
                print("[vc-rq] maxRenderQuality=off -> leaving renderQuality at system default")
            } else {
                let maxq = mqEnv.flatMap { Float($0) } ?? 1.0
                var rq = ProcessInfo.processInfo.environment["VC_RENDER_QUALITY"].flatMap { Float($0) } ?? 1.0
                rq = max(0.0, min(min(1.0, maxq), rq))   // clamp to maxRenderQuality
                layerRenderer.renderQuality = LayerRenderer.RenderQuality(rq)
            }
            let tex = drawables[0].colorTextures[0]
            if let rm = drawables[0].rasterizationRateMaps.first {
                let phys = rm.physicalSize(layer: 0)
                let scr = rm.screenSize
                print("[vc-rq] rateMap physical=\(phys.width)x\(phys.height) screen=\(scr.width)x\(scr.height) drawableTex=\(tex.width)x\(tex.height)")
            } else {
                print("[vc-rq] (no rate map) drawableTex=\(tex.width)x\(tex.height)")
            }
        }

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
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastPresentLogTime >= 1.0 {
                lastPresentLogTime = now
                print("[vc-quad] EMPTY frame: queryDeviceAnchor returned nil (provider not running) -> drawable dropped")
            }
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
        let nowPresent = CFAbsoluteTimeGetCurrent()
        if nowPresent - lastPresentLogTime >= 1.0 {
            lastPresentLogTime = nowPresent
            print("[vc-quad] present: NORMAL path, drawables=\(drawables.count) anchor0set=\(drawables[0].deviceAnchor != nil) heldEyeCount=\(heldEyeCount)")
        }
        // Reprojection fix: report the pose the DISPLAYED slice was actually rendered
        // with (A), so the compositor reprojects from A -> current head instead of from
        // the current pose B (which left the slice at its stale render orientation = the
        // head-turn double). Stereo only; the quad is head-locked, so only the REPORTED
        // anchor changes, not the draw. Until the first render pose is known, keep B.
        //
        // EXCEPT while the menu is up: then there is NO world baked at pose A -- only the
        // HEAD-LOCKED menu panel is shown. Reporting A would make the compositor reproject
        // that glued panel by the head motion over the pipeline latency -> it swims/juders
        // (worse the staler the frame; that is why VC_CAP_LEAD_MS only dampened it). Keep
        // the CURRENT pose B during the menu so the panel stays glued.
        if vcReprojFix, vc_render_mode() == VC_MODE_STEREO, vc_menu_active() == 0,
           vc_splash_active() == 0, let a = heldRenderAnchor {
            for drawable in drawables { drawable.deviceAnchor = a }
        }

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

        // Reprojection fix: remember the DeviceAnchor this exact push used, keyed by the
        // same g_ovSetTime that rides back on the rendered buffer as pose_set_time.
        if vcReprojFix, let a = drawable.deviceAnchor {
            renderAnchorRing.append((key: vc_last_pushed_pose_time(), anchor: a))
            if renderAnchorRing.count > 16 {
                renderAnchorRing.removeFirst(renderAnchorRing.count - 16)
            }
        }
    }

    private func submitFrameToVCRenderer(drawable: LayerRenderer.Drawable, commandBuffer: MTLCommandBuffer) {
        // Head pose -> game camera (V_final = M_head · V_game), the 5.4 seam. In
        // STEREO this lets you look around IN the scene (composed into vcMainView for
        // the main camera only; eye pass adds the IPD). VC_STEREO_HEADLOOK=0 disables
        // it (screen stays head-locked, scene fixed) -- the A/B probe for whether the
        // head-look is what makes every other frame's setup expensive (the 45 Hz).
        if vc_render_mode() == VC_MODE_STEREO {
            if vcStereoHeadLook {
                pushHeadMatrices(drawable: drawable, yawOnly: false)
            }
        } else if vcHeadTrackingMode != 0 {
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

        // Stereo only: hand the REAL per-eye compositor matrices to the reVC game
        // thread via the C seam, converted to librw convention with the SAME F/D
        // basis change as the head-pose seam (see pushHeadMatrices): world->eye is
        // F·V_cs·F, projection is D·P_cs·F. Translations stay in METRES (the seam
        // logs ~0.06 m eye separation); the metres->game-units scale and how these
        // compose with the game camera are the render path's job (Prompt B). This
        // only fills + logs here, so cinema and stereo still render exactly as
        // before. Cinema leaves it unset -> vc_get_stereo_eye_matrices returns false.
        if vc_render_mode() == VC_MODE_STEREO && viewCount == 2 {
            let F = simd_float4x4(diagonal: SIMD4<Float>(1, 1, -1, 1))
            let D = simd_float4x4(columns: (SIMD4<Float>(1, 0, 0, 0),
                                            SIMD4<Float>(0, 1, 0, 0),
                                            SIMD4<Float>(0, 0, 2, 0),
                                            SIMD4<Float>(0, 0, -1, 1)))
            func librwEye(_ i: Int) -> (view: simd_float4x4, proj: simd_float4x4) {
                let vCS = (simdDeviceAnchor * drawable.views[i].transform).inverse  // world->eye (Metal RH, -Z)
                let pCS = drawable.computeProjection(viewIndex: i)                  // Metal RH, depth 0..1
                return (F * vCS * F, D * pCS * F)                                   // librw view / projection
            }
            let left = librwEye(0), right = librwEye(1)
            var eyes = vc_stereo_eye_matrices_t()
            eyes.view = (left.view, right.view)
            eyes.projection = (left.proj, right.proj)
            eyes.valid = 1
            withUnsafePointer(to: &eyes) { vc_set_stereo_eye_matrices($0) }
        }
    }

    /// Build the world-anchored quad vertices (triangle strip: BL, BR, TL, TR) at
    /// `distance` m in front, from explicit half-width/half-height (WORLD space).
    /// V is flipped so a GL (bottom-left origin) render target reads upright when
    /// sampled by Metal (top-left origin). Layout: packed_float3 pos + float2 uv.
    private func gameQuadVertices(halfWidth: Float, halfHeight: Float, distance: Float,
                                  centerY: Float) -> [Float] {
        let cx: Float = 0.0
        let cy: Float = centerY
        let cz: Float = -distance
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
            // Stereo also hands over the transparent HUD overlay (same index/fence).
            heldHudTexture = ready.hud_texture.map {
                Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as! MTLTexture
            }
            heldIndex = ready.index
            heldWaitValue = ready.wait_value
            heldEyeCount = ready.eye_count   // the C side decides mono (1) vs stereo (2)
            hasHeldFrame = true

            // Reprojection fix: the anchor this held frame was RENDERED with. Exact key
            // match on pose_set_time; nearest as a safety net if the ring evicted it.
            if vcReprojFix, ready.pose_set_time != 0 {
                let t = ready.pose_set_time
                if let hit = renderAnchorRing.last(where: { $0.key == t }) {
                    heldRenderAnchor = hit.anchor
                } else if let near = renderAnchorRing.min(by: {
                    ($0.key > t ? $0.key - t : t - $0.key) < ($1.key > t ? $1.key - t : t - $1.key) }) {
                    heldRenderAnchor = near.anchor
                }
            }

            if !loggedGameTexEyeCounts.contains(ready.eye_count), let t = heldTexture {
                loggedGameTexEyeCounts.insert(ready.eye_count)
                print("[vc-quad] game texture \(t.width)x\(t.height) type=\(t.textureType.rawValue) arrayLen=\(t.arrayLength) eye_count=\(ready.eye_count) pixelFormat=\(t.pixelFormat.rawValue) sameDeviceAsHost=\(t.device.registryID == device.registryID)")
            }

            // Quad geometry, rebuilt when the texture aspect changes. Cinema: 2.5 m
            // world screen (2D texture), sized from the aspect. Stereo: pushed to
            // vcCanvasDepth (plane adds no disparity -> depth from slice content) AND
            // sized to the TRUE render tangents so it fills exactly the field of view
            // the slice was drawn with -- full sight, not a window. The slice uses the
            // compositor FOV scale p0/p5 = computeProjection[0][0]/[1][1], so the quad
            // half-extents are D/p0 x D/p5. p0/p5 are ~equal per eye (only the
            // off-centre term differs), so eye 0 is representative.
            let aspect = ready.height > 0 ? Float(ready.width) / Float(ready.height) : 1.0
            if ready.eye_count >= 2 {
                if stereoScreenVertexBuffer == nil || stereoScreenAspect != aspect {
                    let proj = drawables.first?.computeProjection(viewIndex: 0) ?? matrix_identity_float4x4
                    let p0 = proj.columns.0.x, p5 = proj.columns.1.y
                    let hw = (p0 != 0) ? vcCanvasDepth / p0 : vcCanvasDepth
                    let hh = (p5 != 0) ? vcCanvasDepth / p5 : vcCanvasDepth
                    // Head-locked (centre at eye level, cy=0): the stereo quad is
                    // anchored in the deviceAnchor (render-pose) frame so it follows
                    // the head and always fills the FOV, instead of standing in world
                    // space and sliding out of view when you turn.
                    let verts = gameQuadVertices(halfWidth: hw, halfHeight: hh,
                                                 distance: vcCanvasDepth, centerY: 0.0)
                    stereoScreenVertexBuffer = verts.withUnsafeBytes {
                        device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [.storageModeShared])
                    }
                    stereoScreenVertexBuffer?.label = "StereoScreenVertices"
                    stereoScreenAspect = aspect
                }
                // HUD quad (approach B): head-locked, at vcHudDepth, sized to a
                // fraction (vcHudSize) of the vertical FOV at that depth, keeping the
                // HUD texture's own aspect so it isn't stretched. Rebuilt on aspect
                // change. Separate from the world quad: the HUD is a flat 2D image, so
                // it belongs at a comfortable reading depth, not pushed to infinity.
                if hudQuadVertexBuffer == nil || hudQuadAspect != aspect {
                    let proj = drawables.first?.computeProjection(viewIndex: 0) ?? matrix_identity_float4x4
                    let p5 = proj.columns.1.y
                    let fullHalfH = (p5 != 0) ? vcHudDepth / p5 : vcHudDepth
                    let hh = vcHudSize * fullHalfH
                    let hw = hh * aspect
                    let verts = gameQuadVertices(halfWidth: hw, halfHeight: hh,
                                                 distance: vcHudDepth, centerY: 0.0)
                    hudQuadVertexBuffer = verts.withUnsafeBytes {
                        device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [.storageModeShared])
                    }
                    hudQuadVertexBuffer?.label = "HudQuadVertices"
                    hudQuadAspect = aspect
                }
                // Menu panel quad: same construction but at vcMenuDepth / vcMenuSize.
                // Drawn world-anchored (frozen pose) while the pause menu is up.
                if menuQuadVertexBuffer == nil || menuQuadAspect != aspect {
                    let proj = drawables.first?.computeProjection(viewIndex: 0) ?? matrix_identity_float4x4
                    let p5 = proj.columns.1.y
                    let fullHalfH = (p5 != 0) ? vcMenuDepth / p5 : vcMenuDepth
                    let hh = vcMenuSize * fullHalfH
                    let hw = hh * aspect
                    let verts = gameQuadVertices(halfWidth: hw, halfHeight: hh,
                                                 distance: vcMenuDepth, centerY: 0.0)
                    menuQuadVertexBuffer = verts.withUnsafeBytes {
                        device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [.storageModeShared])
                    }
                    menuQuadVertexBuffer?.label = "MenuQuadVertices"
                    menuQuadAspect = aspect
                }
                // Splash quad: FULL FOV (like the world screen) but at the MENU depth, so
                // the loading/title splash sits at the same distance as the menu -> no depth
                // jump menu -> splash -> game. Head-locked; drawn via the HUD pipeline.
                if splashScreenVertexBuffer == nil || splashScreenAspect != aspect {
                    let proj = drawables.first?.computeProjection(viewIndex: 0) ?? matrix_identity_float4x4
                    let p0 = proj.columns.0.x, p5 = proj.columns.1.y
                    let hw = (p0 != 0) ? vcMenuDepth / p0 : vcMenuDepth
                    let hh = (p5 != 0) ? vcMenuDepth / p5 : vcMenuDepth
                    let verts = gameQuadVertices(halfWidth: hw, halfHeight: hh,
                                                 distance: vcMenuDepth, centerY: 0.0)
                    splashScreenVertexBuffer = verts.withUnsafeBytes {
                        device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [.storageModeShared])
                    }
                    splashScreenVertexBuffer?.label = "SplashScreenVertices"
                    splashScreenAspect = aspect
                }
            } else {
                if gameQuadVertexBuffer == nil || gameQuadAspect != aspect {
                    let cy: Float = vcHeadTrackingMode != 0 ? 0.0 : 1.15
                    let verts = gameQuadVertices(halfWidth: 0.75 * aspect, halfHeight: 0.75,
                                                 distance: 2.5, centerY: cy)
                    gameQuadVertexBuffer = verts.withUnsafeBytes {
                        device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [.storageModeShared])
                    }
                    gameQuadVertexBuffer?.label = "GameQuadVertices"
                    gameQuadAspect = aspect
                }
            }
        }

        // Nothing to show until the first-ever acquire; then always show the held
        // frame (fresh this frame, or re-shown on a failed acquire).
        guard hasHeldFrame, let gameTexture = heldTexture else { return }
        let waitValue = heldWaitValue

        // Per-frame (throttled) which branch runs and on what texture -- proves
        // whether the stereo branch is chosen every frame and what eye_count the
        // pause menu actually delivers.
        let nowPath = CFAbsoluteTimeGetCurrent()
        if nowPath - lastPathLogTime >= 1.0 {
            lastPathLogTime = nowPath
            print("[vc-quad] path: branch=\(heldEyeCount >= 2 ? "STEREO" : "cinema") heldEyeCount=\(heldEyeCount) heldType=\(gameTexture.textureType.rawValue) heldArrayLen=\(gameTexture.arrayLength) wait=\(waitValue)")
        }

        // Gate the display pass on the game's GPU. Skip when there is no event
        // (fallback path) or no value (VC_NOFENCE) — waiting on a value that is
        // never signalled would stall the frame.
        if let event = gameSharedEvent, waitValue != 0 {
            commandBuffer.encodeWaitForEvent(event, value: waitValue)
        }

        // Stereo: slice per eye on a world-anchored screen projected per eye (the
        // ONLY display path that fuses -- a full-FOV blit can't, because the
        // compositor reprojects colorTextures[i] with its own off-axis
        // computeProjection(i), which a projected quad satisfies and a blit does
        // not; proven on device with identical slices). Driven by the held frame's
        // eye_count, so a runtime cinema <-> stereo switch needs no restart.
        if heldEyeCount >= 2 {
            if !didLogStereoDisplay {
                didLogStereoDisplay = true
                print("[vc-quad] stereo display path ACTIVE (projected screen, slice per eye)\(vcStereoTestFill ? " [TESTFILL: eye0=red eye1=green]" : "")")
            }
            // Pause menu: game-side the whole in-game block (incl. eye passes) is skipped
            // while the menu is up, so the 4 buffers hold DIFFERENT stale world frames and
            // cycling them per acquire makes the frozen world JITTER. Fix: pin ONE frame
            // (the one held when the menu opened) for the whole pause; keep the menu
            // overlay live. Everything stays HEAD-LOCKED (menu + world are flat quads on
            // the same plane -- world-anchoring them only caused alignment issues, no gain).
            // Loading / splash fade: the eye passes did NOT run (world suppressed), so the
            // eye slices are stale. Draw the splash (overlay/cinema buffer, where DoFade /
            // LoadingScreen put it) as a head-locked FULL-FOV quad at MENU depth and skip the
            // stale world -> clean splash, no 2D-over-3D crossfade, hard cut when it clears.
            let splashNow = vc_splash_active() != 0
            if splashNow { splashHoldFrames = vcSplashHoldFrames }   // keep topped up during the splash
            if splashNow, let splash = heldHudTexture {
                encodeGameHud(drawables: drawables, commandBuffer: commandBuffer,
                              texture: splash, quadOverride: splashScreenVertexBuffer)
                return
            }
            // Black hold: the suppressed world slices are STALE; the compositor may show a
            // buffered stale slice (old gameplay) for a frame or two before the fresh black
            // fade-in slices arrive -> a brief flash (a race). Clear to BLACK for a few frames
            // past the splash to cover the pipeline depth; the C side is at FadeValue~255 then
            // anyway, so we only hide near-black frames.
            if splashHoldFrames > 0 {
                splashHoldFrames -= 1
                for drawable in drawables {
                    let rp = MTLRenderPassDescriptor()
                    rp.colorAttachments[0].texture = drawable.colorTextures[0]
                    rp.colorAttachments[0].loadAction = .clear
                    rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                    rp.colorAttachments[0].storeAction = .store
                    rp.rasterizationRateMap = drawable.rasterizationRateMaps.first
                    if layerRenderer.configuration.layout == .layered {
                        rp.renderTargetArrayLength = drawable.views.count
                    }
                    if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rp) {
                        enc.label = "Splash black hold"
                        enc.endEncoding()
                    }
                }
                return
            }

            let menuActive = vc_menu_active() != 0
            if menuActive {
                if frozenWorldTexture == nil { frozenWorldTexture = gameTexture }
            } else {
                frozenWorldTexture = nil
            }
            let worldTexture = menuActive ? (frozenWorldTexture ?? gameTexture) : gameTexture
            encodeGameStereoScreen(drawables: drawables, commandBuffer: commandBuffer, texture: worldTexture)
            if vcHudEnabled, let hud = heldHudTexture {
                encodeGameHud(drawables: drawables, commandBuffer: commandBuffer, texture: hud)
            }
            return
        }

        guard let quadVertexBuffer = gameQuadVertexBuffer else { return }

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

    /// Stereo: the game's 2D-array texture (slice 0 = left, 1 = right) on a world-
    /// anchored quad at vcCanvasDepth, each eye sampling its own slice. One per-eye
    /// view-projection makes both eyes converge on the screen; at a far distance the
    /// quad plane adds ~no disparity of its own, so depth comes from the per-eye
    /// slice content. amplification_id selects the source slice and the view mapping
    /// routes it to drawable slice i, so eyes are not swapped. The slice is symmetric
    /// (C side), sampled WITHOUT a uv.x flip (a flip mirrored the world -> inverted
    /// disparity + reversed controls).
    private func encodeGameStereoScreen(drawables: [LayerRenderer.Drawable],
                                        commandBuffer: MTLCommandBuffer,
                                        texture: MTLTexture) {
        guard let quadVertexBuffer = stereoScreenVertexBuffer else { return }

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
            residencySet.addAllocations([texture, quadVertexBuffer])
            residencySet.commit()
            #endif

            guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                return
            }
            renderEncoder.label = "Game Stereo Screen"
            renderEncoder.setCullMode(.none)
            renderEncoder.setRenderPipelineState(vcStereoTestFill ? gameStereoTestPipeline : gameStereoPipeline)
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

            // Per-eye clip. The stereo quad is ALWAYS head-locked: viewMatrix =
            // view.transform.inverse (NO deviceAnchor), so the quad lives in the
            // deviceAnchor/render-pose frame and follows the head -- it fills the FOV
            // and doesn't slide away when you turn. The compositor still reprojects
            // against the reported drawable.deviceAnchor, correcting head motion since
            // render (Klepton/ALVR reprojection). The slice is a flat game image, so
            // there is no in-scene look-around here -- that needs the game camera to
            // follow the head, a separate step.
            var viewProjection = [matrix_identity_float4x4, matrix_identity_float4x4]
            for i in 0..<min(drawable.views.count, 2) {
                let view = drawable.views[i]
                let viewMatrix = view.transform.inverse   // head-locked
                let projectionMatrix = drawable.computeProjection(viewIndex: i)
                viewProjection[i] = projectionMatrix * viewMatrix
            }

            let nowDraw = CFAbsoluteTimeGetCurrent()
            if nowDraw - lastStereoDrawLogTime >= 1.0 {
                lastStereoDrawLogTime = nowDraw
                let ct = drawable.colorTextures[0]
                // Far-plane probe: project the quad CENTRE and a CORNER through eye 0
                // and report NDC z = clip.z/clip.w. Metal is reverse-Z (near=1, far=0);
                // the compositor discards NDC z < 0 (past the far plane). If the corner
                // z is < 0 while the centre is > 0, the quad edges are being clipped ->
                // that is the "window / too near" symptom. proj row2 = the compositor's
                // own near/far encoding (columns.2.z, columns.3.z).
                let proj = drawable.computeProjection(viewIndex: 0)
                let p0 = proj.columns.0.x, p5 = proj.columns.1.y
                let hw = (p0 != 0) ? vcCanvasDepth / p0 : vcCanvasDepth
                let hh = (p5 != 0) ? vcCanvasDepth / p5 : vcCanvasDepth
                let cyc: Float = 0.0   // stereo quad is head-locked at eye level
                let centre = viewProjection[0] * SIMD4<Float>(0, cyc, -vcCanvasDepth, 1)
                let corner = viewProjection[0] * SIMD4<Float>(hw, cyc + hh, -vcCanvasDepth, 1)
                let cz = centre.w != 0 ? centre.z / centre.w : .nan
                let kz = corner.w != 0 ? corner.z / corner.w : .nan
                print(String(format: "[vc-far] depth=%.0f  proj row2 z=%.5f w=%.3f  centre ndcZ=%.5f (w=%.2f)  corner ndcZ=%.5f (w=%.2f)  cornerDist=%.0f  colorArrayLen=%d srcArrayLen=%d",
                             vcCanvasDepth, proj.columns.2.z, proj.columns.3.z,
                             cz, centre.w, kz, corner.w,
                             (hw*hw + hh*hh + vcCanvasDepth*vcCanvasDepth).squareRoot(),
                             ct.arrayLength, texture.arrayLength))
            }

            renderEncoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
            renderEncoder.setVertexBytes(&viewProjection,
                                         length: MemoryLayout<matrix_float4x4>.stride * 2,
                                         index: 1)
            renderEncoder.setFragmentTexture(texture, index: 0)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            renderEncoder.endEncoding()
        }
    }

    /// Stereo overlay layer (approach B). The 2D overlay buffer (reVC's SCREEN x SCREEN
    /// HUD/2D/menu buffer) drawn ON TOP of the world slices, one per-eye view-projection,
    /// through the alpha-blending HUD pipeline. The in-game block (world + HUD) is
    /// skipped game-side while the pause menu is up, so this ONE buffer holds either the
    /// HUD (menu off) or the menu (menu on), both drawn HEAD-LOCKED (view.transform.inverse)
    /// -- they are flat quads on the same plane; the menu just uses its own depth/size
    /// (vcMenuDepth/vcMenuSize) so it can be larger than the HUD. Depth ignored (always on
    /// top). The compositor still reprojects against the reported deviceAnchor.
    private func encodeGameHud(drawables: [LayerRenderer.Drawable],
                               commandBuffer: MTLCommandBuffer,
                               texture: MTLTexture,
                               quadOverride: MTLBuffer? = nil) {
        let menuActive = vc_menu_active() != 0

        // quadOverride = the fullscreen stereo-screen quad, used for the loading splash so
        // it fills the FOV instead of the small HUD/menu panel.
        guard let quadVertexBuffer = quadOverride ?? (menuActive ? menuQuadVertexBuffer : hudQuadVertexBuffer) else { return }

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
            residencySet.addAllocations([texture, quadVertexBuffer])
            residencySet.commit()
            #endif

            guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                return
            }
            renderEncoder.label = menuActive ? "Game Menu Panel" : "Game HUD Overlay"
            renderEncoder.setCullMode(.none)
            renderEncoder.setRenderPipelineState(gameHudPipeline)
            renderEncoder.setDepthStencilState(noDepthState)   // always on top, no depth write

            let viewports = drawable.views.map { $0.textureMap.viewport }
            renderEncoder.setViewports(viewports)

            if drawable.views.count > 1 {
                var viewMappings = (0..<drawable.views.count).map {
                    MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                      renderTargetArrayIndexOffset: UInt32($0))
                }
                renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
            }

            var viewProjection = [matrix_identity_float4x4, matrix_identity_float4x4]
            for i in 0..<min(drawable.views.count, 2) {
                let view = drawable.views[i]
                let viewMatrix = view.transform.inverse   // head-locked (HUD and menu)
                let projectionMatrix = drawable.computeProjection(viewIndex: i)
                viewProjection[i] = projectionMatrix * viewMatrix
            }

            renderEncoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
            renderEncoder.setVertexBytes(&viewProjection,
                                         length: MemoryLayout<matrix_float4x4>.stride * 2,
                                         index: 1)
            renderEncoder.setFragmentTexture(texture, index: 0)
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

