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

// Diagnostic, default OFF. Move the game-slice shared-event wait into its OWN command
// buffer so the main command buffer's gpuStart..gpuEnd measures PURE compositing, and the
// wait buffer measures how long the compositor GPU idles waiting for the game slices to
// finish (a proxy for the game-slice GPU cost, which our metrics otherwise never show).
// Splits [vc-gpu] into composite vs. wait. VC_GPU_SPLIT=1. Real path unchanged when off.
nonisolated let vcGpuSplit = ProcessInfo.processInfo.environment["VC_GPU_SPLIT"] == "1"

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
// Diagnostic clear colour for the stereo pass (see encodeGameStereoScreen). Default off.
nonisolated let vcStereoClearMagenta: Bool = {
    ProcessInfo.processInfo.environment["VC_STEREO_CLEAR"] == "magenta"
}()
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

// VC_STEREO_LOG=1: host-side reprojection probe. Logs when the render-pose anchor match
// falls back from an EXACT pose_set_time hit to the nearest ring entry (stale anchor) --
// the suspected cause of the stereo divergence when the frame rate jumps (e.g. walking
// through an interior door: ~54 -> ~90 fps changes the buffer cadence).
nonisolated let vcStereoLog: Bool = {
    ProcessInfo.processInfo.environment["VC_STEREO_LOG"] == "1"
}()
nonisolated let vcMachToMs: Double = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return Double(tb.numer) / Double(tb.denom) / 1.0e6
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
// (default 2.0). VC_HUD_SIZE = fraction of the vertical FOV the quad fills at that
// depth (default 0.4); shrink it to pull the corners (radar, cash) into comfortable
// central view.
nonisolated let vcHudDepth: Float = {
    if let s = ProcessInfo.processInfo.environment["VC_HUD_DEPTH"], let d = Float(s), d > 0 {
        return d
    }
    return 2.0
}()
nonisolated let vcHudSize: Float = {
    // 0..1 fraction of the vertical FOV; 0 = HUD effectively hidden (zero-size quad).
    // Only an unset/invalid value falls back to the default.
    if let s = ProcessInfo.processInfo.environment["VC_HUD_SIZE"], let d = Float(s), d >= 0 {
        return d
    }
    return 0.35   // keep in sync with GameSettings.hudSizeDefault
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
// FOV the panel fills at that depth when it opens (default 0.25).
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
    return 0.25
}()
// Pause menu anchored IN THE ROOM (2026-10-06): while the menu is up, the menu panel AND
// the frozen world picture behind it are placed at the head pose captured when the menu
// opened, like the start menu (mono path, world-anchored quad). A head-locked panel moved
// with every head turn and caused motion sickness. Anchoring only the panel (an earlier
// attempt) left the background head-locked -> two conflicting motions; both must freeze.
// VC_MENU_ANCHOR=0 = old head-locked behaviour (A/B).
nonisolated let vcMenuAnchorInRoom: Bool = {
    ProcessInfo.processInfo.environment["VC_MENU_ANCHOR"] != "0"
}()
// Frozen WORLD picture behind the menu: default head-locked like during play (no picture
// edges when turning; user 2026-10-06). VC_MENU_WORLD=room freezes it in the room with
// the panel instead (edges become visible on large head turns).
nonisolated let vcMenuWorldInRoom: Bool = {
    ProcessInfo.processInfo.environment["VC_MENU_WORLD"] == "room"
}()
// Live world under the pause menu (default on, mirrors VC_MENU_LIVE on the C side): the
// game keeps running the eye passes with the live head pose while paused, so the world
// slices are fresh every frame -> shown head-locked like during play (look around, no
// edges), the menu panel alone stands in the room. Nothing is frozen; the panel is drawn
// with the RENDER anchor (A) like the slices, so the compositor reprojects both together.
nonisolated let vcMenuLiveWorld: Bool = {
    ProcessInfo.processInfo.environment["VC_MENU_LIVE"] != "0"
}()

/// Menu-open pose made UPRIGHT: keep position and yaw of the head, drop pitch and roll,
/// so the panel always stands level in front of the player even if the menu was opened
/// with a tilted head. Falls back to the full pose when looking straight up/down.
nonisolated func vcUprightPose(_ t: simd_float4x4) -> simd_float4x4 {
    let back = SIMD3<Float>(t.columns.2.x, 0, t.columns.2.z)   // device +Z = backward
    let len = simd_length(back)
    guard len > 0.2 else { return t }
    let b = back / len
    let up = SIMD3<Float>(0, 1, 0)
    let right = simd_normalize(simd_cross(up, b))
    return simd_float4x4(SIMD4<Float>(right, 0), SIMD4<Float>(up, 0), SIMD4<Float>(b, 0), t.columns.3)
}


// The 90 Hz frame budget in milliseconds (1/90 s). Full-length bar == budget;
// longer/red means over budget.
nonisolated let vcFrameBudgetMs = 1000.0 / 90.0   // 11.1 ms

// GPU frame time is only known in the command buffer's completion handler, which
// runs off the render thread — hold it in a tiny lock-guarded box the render
// thread reads next frame.
final class FrameStats: @unchecked Sendable {
    private let lock = NSLock()
    private var _gpuMs: Double = 0
    // Compositor-pass GPU-time window (min/max/avg over the log interval) for [vc-gpu].
    private var _sum = 0.0, _min = 0.0, _max = 0.0, _last = 0.0
    private var _count = 0
    var gpuMs: Double { lock.lock(); defer { lock.unlock() }; return _gpuMs }
    func setGPUMs(_ v: Double) { lock.lock(); _gpuMs = v; lock.unlock() }
    // Record one command buffer's GPU duration (ms). Feeds both the overlay bars
    // (_gpuMs) and the [vc-gpu] window stats.
    func recordGPUMs(_ v: Double) {
        lock.lock(); defer { lock.unlock() }
        _gpuMs = v; _last = v; _sum += v; _count += 1
        if _count == 1 || v < _min { _min = v }
        if v > _max { _max = v }
    }
    // (last, avg, min, max, n) over the window, then reset. nil if no samples yet.
    func drainGPUStats() -> (Double, Double, Double, Double, Int)? {
        lock.lock(); defer { lock.unlock() }
        if _count == 0 { return nil }
        let r = (_last, _sum / Double(_count), _min, _max, _count)
        _sum = 0; _count = 0; _min = 0; _max = 0
        return r
    }

    // Separate window for the game-slice event-wait (VC_GPU_SPLIT): how long the
    // compositor GPU idles on encodeWaitForEvent until the game slices are done.
    private var _wsum = 0.0, _wmin = 0.0, _wmax = 0.0, _wlast = 0.0
    private var _wcount = 0
    func recordWaitMs(_ v: Double) {
        lock.lock(); defer { lock.unlock() }
        _wlast = v; _wsum += v; _wcount += 1
        if _wcount == 1 || v < _wmin { _wmin = v }
        if v > _wmax { _wmax = v }
    }
    func drainWaitStats() -> (Double, Double, Double, Double, Int)? {
        lock.lock(); defer { lock.unlock() }
        if _wcount == 0 { return nil }
        let r = (_wlast, _wsum / Double(_wcount), _wmin, _wmax, _wcount)
        _wsum = 0; _wcount = 0; _wmin = 0; _wmax = 0
        return r
    }
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
    // Same, with the foveation-unwarp fragment (VC_FOVEATE): unwarps the rate-mapped slice.
    let gameStereoFoveatedPipeline: MTLRenderPipelineState
    // Stereo HUD layer: the transparent 2D overlay on a head-locked quad, blended
    // over the world slices (premultiplied alpha). Reuses the cinema quad shaders.
    let gameHudPipeline: MTLRenderPipelineState
    // Depth-disabled state for the full-screen stereo blit (always fills).
    let noDepthState: MTLDepthStencilState
    var didSetRenderQuality = false        // one-time: raise renderQuality + log the rate map
    var lastHostMemLog: Double = 0         // throttle for the host-device memory probe
    var lastGpuLogTime: Double = 0         // throttle for the [vc-gpu] compositor GPU-time log
    var gameSharedEvent: MTLSharedEvent?   // id<MTLSharedEvent> from the game side (lazy)
    var gameQuadVertexBuffer: MTLBuffer?   // cinema quad, rebuilt when the texture aspect changes
    var gameQuadAspect: Float = 0          // width/height the cinema vertex buffer was built for
    var stereoScreenVertexBuffer: MTLBuffer?  // stereo quad (far distance), rebuilt on aspect change
    var stereoScreenAspect: Float = 0         // width/height the stereo vertex buffer was built for
    var foveRateBuffer: MTLBuffer?            // foveation rate-map parameter data for the unwarp shader
    var foveRateMapPtr: UnsafeMutableRawPointer?  // the C rate map the param buffer was built from
    var didPushFoveCurve = false             // one-time: sampled the compositor optical curve + pushed to reVC
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
    var menuFrozenPose: simd_float4x4?     // device pose (origin<-anchor) captured at menu-open; menu + frozen world hang there
    var heldIndex: UInt32 = 0
    var heldWaitValue: UInt64 = 0
    var hasHeldFrame = false
    var heldEyeCount: UInt32 = 1           // 1 = mono/cinema, 2 = stereo array; drives the display path
    var heldWorldValid = false             // the held frame's eye slices were rendered (C: world_valid)
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
            gameStereoFoveatedPipeline = try Self.buildGameStereoPipeline(device: device, layerRenderer: layerRenderer,
                                                                          vertex: "vc_stereo_vertex",
                                                                          fragment: "vc_stereo_fragment_foveated")
            gameHudPipeline = try Self.buildHudPipeline(device: device, layerRenderer: layerRenderer)
            statsBarPipeline = try Self.buildStatsBarPipeline(device: device, layerRenderer: layerRenderer)
        } catch {
            fatalError("Unable to compile game-quad/stereo/stats pipeline state. Error info: \(error)")
        }

        self.depthState = Self.buildDepthStencilState(device: device)
        self.noDepthState = Self.buildNoDepthStencilState(device: device)

        worldTracking = WorldTrackingProvider()
        print("[vc-stats] VC_DEBUG_STATS \(vcDebugStats ? "ENABLED" : "disabled"), budget=\(vcFrameBudgetMs) ms")
        Self.logMultiviewCaps(device: device)
        // VC_MV_SPIKE=1 -> isolation matrix + full stage-1 bar test (amplification);
        // VC_MV_SPIKE=2 -> isolation matrix only;
        // VC_MV_SPIKE=3 -> instanced layer-routing test (ANGLE's multiview
        //                  emulation pattern: render_target_array_index from
        //                  instance_id, shared V curve) — the stage-3 gate.
        let spikeMode = ProcessInfo.processInfo.environment["VC_MV_SPIKE"]
        if spikeMode == "1" || spikeMode == "2" {
            MultiviewSpike.isolationTest(device: device)
            if spikeMode == "1" {
                MultiviewSpike.run(device: device)
            }
        } else if spikeMode == "3" {
            MultiviewSpike.runInstanced(device: device)
        }
    }

    // Multiview plan, stage 0: pure capability queries, no render-path changes.
    // Logged once at startup; filter the Xcode console for "mv-caps".
    private static func logMultiviewCaps(device: MTLDevice) {
        let families: [(String, MTLGPUFamily)] = [
            ("apple5", .apple5), ("apple6", .apple6), ("apple7", .apple7),
            ("apple8", .apple8), ("apple9", .apple9), ("metal3", .metal3),
        ]
        let supported = families.filter { device.supportsFamily($0.1) }.map { $0.0 }
        print("[mv-caps] device=\(device.name) families=\(supported.joined(separator: ","))")

        // Counts <= 1 trigger an API validation error per the docs, so probing
        // starts at 2. maxAmp stays 1 if amplification is entirely unsupported.
        var maxAmp = 1
        for count in 2...16 where device.supportsVertexAmplificationCount(count) {
            maxAmp = count
        }
        print("[mv-caps] maxVertexAmplificationCount=\(maxAmp)")

        var maxRateMapLayers = 0
        for layers in 1...16 where device.supportsRasterizationRateMap(layerCount: layers) {
            maxRateMapLayers = layers
        }
        print("[mv-caps] rasterizationRateMap maxLayerCount=\(maxRateMapLayers)")

        // Self-built two-layer map: layer 0 uniform 1.0, layer 1 with an edge
        // falloff. Different physical sizes per layer prove the layers are
        // honored independently — creation alone doesn't prove rendering works
        // (that's stage 1), but a nil here would kill the plan early.
        let zones = 8
        let layer0 = MTLRasterizationRateLayerDescriptor(sampleCount: MTLSizeMake(zones, zones, 0))
        let layer1 = MTLRasterizationRateLayerDescriptor(sampleCount: MTLSizeMake(zones, zones, 0))
        for i in 0..<zones {
            let edge = min(Float(i), Float(zones - 1 - i)) / Float(zones / 2)
            let rate = max(0.3, min(1.0, 0.3 + edge))
            layer0.horizontal[i] = 1.0
            layer0.vertical[i] = 1.0
            layer1.horizontal[i] = rate
            layer1.vertical[i] = rate
        }
        let desc = MTLRasterizationRateMapDescriptor()
        desc.screenSize = MTLSizeMake(2048, 2048, 0)
        desc.setLayer(layer0, at: 0)
        desc.setLayer(layer1, at: 1)
        desc.label = "mv-caps two-layer probe"
        if let map = device.makeRasterizationRateMap(descriptor: desc) {
            let p0 = map.physicalSize(layer: 0)
            let p1 = map.physicalSize(layer: 1)
            let g = map.physicalGranularity
            print("[mv-caps] twoLayerMap=OK layerCount=\(map.layerCount) screen=2048x2048"
                  + " phys0=\(p0.width)x\(p0.height) phys1=\(p1.width)x\(p1.height)"
                  + " granularity=\(g.width)x\(g.height)")
        } else {
            print("[mv-caps] twoLayerMap=FAILED (makeRasterizationRateMap returned nil)")
        }
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

        // Compositor-pass GPU time (base clear + game-quad sample + present), measured
        // directly from the command buffer's GPU start/end — the number the foveation win
        // is compared against, not inferred from startframe. Always recorded (cheap);
        // logged throttled below as [vc-gpu], and read by the VC_DEBUG_STATS overlay bars.
        do {
            let stats = self.frameStats
            commandBuffer.addCompletedHandler { cb in
                stats.recordGPUMs((cb.gpuEndTime - cb.gpuStartTime) * 1000.0)
            }
        }

        let drawables = frame.queryDrawables()
        guard !drawables.isEmpty else { return }

        // Leak split: the C [vc-mem] logs the ANGLE device (g_mtlDevice). This logs the HOST
        // (compositor/Swift) device. Same value & both grow -> one shared device (leak could
        // be compositor drawables too); only ANGLE grows -> the leak is reVC/ANGLE-side.
        do {
            let now = CFAbsoluteTimeGetCurrent()
            if vc_perf_log() != 0, now - lastHostMemLog >= 2.0 {
                lastHostMemLog = now
                print(String(format: "[vc-mem-host] hostDevice.currentAllocatedSize=%llu MB", UInt64(device.currentAllocatedSize) / 1_000_000))
            }
        }

        // Compositor-pass GPU time, measured directly (not inferred from startframe).
        // Always-on in stereo like [vc-frame], ~1 s cadence: min/max catch the cutscene
        // spike, avg the steady cost. This is the baseline the foveation win is measured
        // against — with vs. without a rate map on the same scene.
        if vc_render_mode() == VC_MODE_STEREO {
            let nowGpu = CFAbsoluteTimeGetCurrent()
            if nowGpu - lastGpuLogTime >= 1.0, let g = frameStats.drainGPUStats() {
                lastGpuLogTime = nowGpu
                if vcGpuSplit, let w = frameStats.drainWaitStats() {
                    // Split: g = pure compositing, w = idle wait for the game slices.
                    print(String(format: "[vc-gpu] composite avg=%.1f min=%.1f max=%.1f | wait(game slices) avg=%.1f min=%.1f max=%.1f ms (n=%d)",
                                 g.1, g.2, g.3, w.1, w.2, w.3, g.4))
                } else {
                    // Combined: this includes the GPU-side encodeWaitForEvent on the game
                    // slices, so it is wait+composite, not pure compositing (set VC_GPU_SPLIT=1).
                    print(String(format: "[vc-gpu] wait+composite: last=%.1f avg=%.1f min=%.1f max=%.1f ms (n=%d)",
                                 g.0, g.1, g.2, g.3, g.4))
                }
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
                // Multiview plan, stage 0: what the compositor's own rate map
                // reports about layering — the reference our self-built map
                // must match.
                let perLayer = (0..<rm.layerCount)
                    .map { rm.physicalSize(layer: $0) }
                    .map { "\($0.width)x\($0.height)" }
                    .joined(separator: ",")
                print("[mv-caps] compositorMap layerCount=\(rm.layerCount)"
                      + " maps=\(drawables[0].rasterizationRateMaps.count)"
                      + " views=\(drawables[0].views.count)"
                      + " physPerLayer=\(perLayer)"
                      + " texArrayLength=\(tex.arrayLength) texType=\(tex.textureType.rawValue)")
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
            // Opaque black with cleared depth (the compositor reprojects with the depth
            // texture; an uncleared one is undefined), then present so the frame completes.
            encodeBlackFrame(drawables: drawables, commandBuffer: commandBuffer, label: "Empty frame (awaiting device anchor)")
            for drawable in drawables {
                drawable.encodePresent(commandBuffer: commandBuffer)
            }
            committedFrameIndex += 1
            commandBuffer.encodeSignalEvent(self.endFrameEvent, value: committedFrameIndex)
            commandBuffer.commit()
            frame.endSubmission()
            return
        }

        frame.startSubmission()

        // Foveation: sample the compositor's own optical rate curve (once) and hand it to
        // reVC, so the slice rate map matches the Vision Pro lenses (dense zone on the true
        // off-centre optical axis) instead of a hand-picked bell.
        pushFoveationCurveIfNeeded(drawables[0])

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
        if vc_perf_log() != 0, nowPresent - lastPresentLogTime >= 1.0 {
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
        // With the live world under the menu (vcMenuLiveWorld) the slices ARE baked at pose
        // A again and the room-anchored panel is drawn with A too -> report A as in play.
        if vcReprojFix, vc_render_mode() == VC_MODE_STEREO, (vc_menu_active() == 0 || vcMenuLiveWorld),
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
        // Cinema: colour alpha 0 so passthrough shows around the 2.5 m screen. Stereo: OPAQUE
        // black (alpha 1). Every stereo content pass that .loads onto this base (splash quad,
        // HUD/menu panel, stats) leaves the band outside its quad at the base value; with
        // alpha 0 that band was transparent during the title/menu, the loading splash and
        // the splash-target fades -- "seeing through under the black plane" (M2, 2026-10-09).
        // Depth is reverse-Z (clear 0 = far). Single-sample straight into the drawable
        // textures (the removed template cube was the only MSAA user).
        let baseAlpha: Double = vc_render_mode() == VC_MODE_STEREO ? 1.0 : 0.0
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.colorTextures[0]
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: baseAlpha)
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
        if vc_perf_log() != 0, now - lastHeadLogTime >= 1.0 {
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

    /// Sample one rate map's per-axis local sampling rate (d physical / d screen) at
    /// `zones` points across each axis, by differencing physicalCoordinates. The rate is
    /// ~1 at the optical centre and falls toward the edges; the peak is off-centre per eye.
    private func sampleAxisRates(_ rm: MTLRasterizationRateMap, layer: Int, zones: Int) -> ([Float], [Float]) {
        let ss = rm.screenSize
        let W = Float(ss.width), H = Float(ss.height)
        let midX = W * 0.5, midY = H * 0.5
        var h = [Float](repeating: 0, count: zones)
        var v = [Float](repeating: 0, count: zones)
        for i in 0..<zones {
            let sx = (Float(i) + 0.5) / Float(zones) * W
            let stepX = Swift.max(1.0, W / Float(zones) * 0.5)
            let x0 = Swift.max(0, sx - stepX * 0.5), x1 = Swift.min(W, sx + stepX * 0.5)
            let a = rm.physicalCoordinates(screenCoordinates: MTLCoordinate2DMake(x0, midY), layer: layer)
            let b = rm.physicalCoordinates(screenCoordinates: MTLCoordinate2DMake(x1, midY), layer: layer)
            h[i] = (x1 - x0) > 0 ? Float(b.x - a.x) / (x1 - x0) : 0

            let sy = (Float(i) + 0.5) / Float(zones) * H
            let stepY = Swift.max(1.0, H / Float(zones) * 0.5)
            let y0 = Swift.max(0, sy - stepY * 0.5), y1 = Swift.min(H, sy + stepY * 0.5)
            let c = rm.physicalCoordinates(screenCoordinates: MTLCoordinate2DMake(midX, y0), layer: layer)
            let d = rm.physicalCoordinates(screenCoordinates: MTLCoordinate2DMake(midX, y1), layer: layer)
            v[i] = (y1 - y0) > 0 ? Float(d.y - c.y) / (y1 - y0) : 0
        }
        return (h, v)
    }

    /// Once, when foveation is wanted: sample the compositor's optical rate curve from the
    /// per-eye drawable rate maps, envelope across eyes, peak-normalize, floor, log, and
    /// push to reVC (which builds the slice rate map from it). Klepton's sampleCurve.
    private func pushFoveationCurveIfNeeded(_ drawable: LayerRenderer.Drawable) {
        guard !didPushFoveCurve, vc_foveation_wanted() != 0 else { return }
        let maps = drawable.rasterizationRateMaps
        guard !maps.isEmpty else { return }   // foveation not enabled on the layer -> nothing to sample
        let zones = 32
        var h = [Float](repeating: 0, count: zones)
        var v = [Float](repeating: 0, count: zones)
        // A stereo drawable exposes ONE rate map with a LAYER PER EYE (each eye's optical
        // axis is nasally shifted, mirror-image). Envelope (max per zone) across all layers
        // of all maps, so the single shared slice curve never renders EITHER eye coarser
        // than it needs -> symmetric, wide sharp band covering both optical axes.
        var totalLayers = 0
        for rm in maps {
            for layer in 0..<Swift.max(1, rm.layerCount) {
                let (eh, ev) = sampleAxisRates(rm, layer: layer, zones: zones)
                for i in 0..<zones { h[i] = Swift.max(h[i], eh[i]); v[i] = Swift.max(v[i], ev[i]) }
                totalLayers += 1
            }
        }
        // The eyes are mirror-symmetric; the single shared curve must be too. Envelope each
        // axis with its mirror so the sharp band covers BOTH optical axes and neither eye is
        // rendered coarser than it needs. Robust even if only one layer was available.
        h = (0..<zones).map { Swift.max(h[$0], h[zones - 1 - $0]) }
        v = (0..<zones).map { Swift.max(v[$0], v[zones - 1 - $0]) }

        let floorRate: Float = {
            if let s = ProcessInfo.processInfo.environment["VC_FOVEATE_EDGE"], let f = Float(s), f > 0.01, f <= 1 { return f }
            return 0.05
        }()
        func normalize(_ a: inout [Float]) {
            let peak = Swift.max(a.max() ?? 1, 1e-4)
            for i in a.indices { a[i] = Swift.max(a[i] / peak, floorRate) }
        }
        normalize(&h); normalize(&v)
        didPushFoveCurve = true
        print("[vc-fove-swift] sampled compositor curve: zones=\(zones) maps=\(maps.count) layers=\(totalLayers) floor=\(floorRate)")
        print("[vc-fove-swift]   H=" + h.map { String(format: "%.2f", $0) }.joined(separator: " "))
        print("[vc-fove-swift]   V=" + v.map { String(format: "%.2f", $0) }.joined(separator: " "))
        h.withUnsafeBufferPointer { hp in
            v.withUnsafeBufferPointer { vp in
                vc_set_foveation_curve(hp.baseAddress, Int32(zones), vp.baseAddress, Int32(zones))
            }
        }
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
            heldWorldValid = ready.world_valid != 0
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
                    if vcStereoLog {
                        let d = near.key > t ? near.key - t : t - near.key
                        print(String(format: "[vc-reproj] FALLBACK: no exact pose_set_time match, using nearest anchor deltaMs=%.1f ringCount=%d",
                                     Double(d) * vcMachToMs, renderAnchorRing.count))
                    }
                } else if vcStereoLog {
                    print("[vc-reproj] FALLBACK: ring empty, no anchor for pose_set_time (reprojecting from current pose)")
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
            // Overlay (HUD/menu) aspect. When reVC pins its 2D layout to the 4:3 DESIGN
            // aspect (vc_hud_aspect_fixed -- needed because the near-square buffer from
            // VC_RES=2 up otherwise pushes the 640-wide menu design off the right edge),
            // the layout fills the WHOLE overlay texture but comes out horizontally
            // squeezed by (4:3)/textureAspect. A 4:3 quad undoes exactly that, at full
            // texture resolution -- which is why we squeeze in the texture instead of
            // shrinking the buffer to 16:9 (that would cost 40-60% of the pixels per
            // glyph). With the fix off the layout is AR-corrected for the texture aspect,
            // so the quad keeps the texture aspect. Not applied to the world quad or the
            // splash: the splash is drawn fullscreen (no SCREEN_SCALE_AR) and stays full-FOV.
            let overlayAspect: Float = vc_hud_aspect_fixed() != 0 ? (4.0 / 3.0) : aspect
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
                if hudQuadVertexBuffer == nil || hudQuadAspect != overlayAspect {
                    let proj = drawables.first?.computeProjection(viewIndex: 0) ?? matrix_identity_float4x4
                    let p5 = proj.columns.1.y
                    let fullHalfH = (p5 != 0) ? vcHudDepth / p5 : vcHudDepth
                    let hh = vcHudSize * fullHalfH
                    let hw = hh * overlayAspect
                    let verts = gameQuadVertices(halfWidth: hw, halfHeight: hh,
                                                 distance: vcHudDepth, centerY: 0.0)
                    hudQuadVertexBuffer = verts.withUnsafeBytes {
                        device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [.storageModeShared])
                    }
                    hudQuadVertexBuffer?.label = "HudQuadVertices"
                    hudQuadAspect = overlayAspect
                }
                // Menu panel quad: same construction but at vcMenuDepth / vcMenuSize.
                // Drawn world-anchored (frozen pose) while the pause menu is up.
                if menuQuadVertexBuffer == nil || menuQuadAspect != overlayAspect {
                    let proj = drawables.first?.computeProjection(viewIndex: 0) ?? matrix_identity_float4x4
                    let p5 = proj.columns.1.y
                    let fullHalfH = (p5 != 0) ? vcMenuDepth / p5 : vcMenuDepth
                    let hh = vcMenuSize * fullHalfH
                    let hw = hh * overlayAspect
                    let verts = gameQuadVertices(halfWidth: hw, halfHeight: hh,
                                                 distance: vcMenuDepth, centerY: 0.0)
                    menuQuadVertexBuffer = verts.withUnsafeBytes {
                        device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [.storageModeShared])
                    }
                    menuQuadVertexBuffer?.label = "MenuQuadVertices"
                    menuQuadAspect = overlayAspect
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
        if vc_perf_log() != 0, nowPath - lastPathLogTime >= 1.0 {
            lastPathLogTime = nowPath
            print("[vc-quad] path: branch=\(heldEyeCount >= 2 ? "STEREO" : "cinema") heldEyeCount=\(heldEyeCount) heldType=\(gameTexture.textureType.rawValue) heldArrayLen=\(gameTexture.arrayLength) wait=\(waitValue)")
        }

        // Gate the display pass on the game's GPU. Skip when there is no event
        // (fallback path) or no value (VC_NOFENCE) — waiting on a value that is
        // never signalled would stall the frame.
        if let event = gameSharedEvent, waitValue != 0 {
            if vcGpuSplit, let wcb = commandQueue.makeCommandBuffer() {
                // Measurement: the wait runs in its OWN command buffer, committed before the
                // main one on the same queue (so ordering still gates the composite on a
                // complete slice). Its gpuStart..gpuEnd = the idle wait for the game slices;
                // the main buffer then measures pure compositing.
                wcb.label = "GameEventWait(measure)"
                wcb.encodeWaitForEvent(event, value: waitValue)
                let stats = self.frameStats
                wcb.addCompletedHandler { cb in
                    stats.recordWaitMs((cb.gpuEndTime - cb.gpuStartTime) * 1000.0)
                }
                wcb.commit()
            } else {
                commandBuffer.encodeWaitForEvent(event, value: waitValue)
            }
        }

        // Save load in progress (mono frontend frames OR stereo): the confirm dialog,
        // "please wait" message and splash cycle through the buffer ring and flicker in
        // stereo. Show a stable BLACK for the whole load, regardless of eye_count, until
        // the world render resumes (the game's fade-in then takes over). Checked BEFORE the
        // eye_count branch because the loading frames are mono (eye_count=1).
        if vc_loading_active() != 0 {
            encodeBlackFrame(drawables: drawables, commandBuffer: commandBuffer, label: "Load black")
            return
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
                encodeBlackFrame(drawables: drawables, commandBuffer: commandBuffer, label: "Splash black hold")
                return
            }

            let menuActive = vc_menu_active() != 0
            // Never display slices that were not rendered for the held publish: frontend,
            // splash and loading frames carry eye_count=2 but no eye passes, so their array
            // slices are stale or (first New Game after launch) never written at all. The
            // fixed black hold above only covers a few frames; when the first world frame
            // takes longer (New Game: shader builds, streaming) the stale slices showed as a
            // flash (2026-10-09). State-driven: black until a world_valid frame is held. The
            // frozen-world menu picture counts as valid once captured from a valid frame.
            let worldValid = (menuActive && !vcMenuLiveWorld && frozenWorldTexture != nil) || heldWorldValid
            if !worldValid {
                encodeBlackFrame(drawables: drawables, commandBuffer: commandBuffer, label: "No valid world yet")
                return
            }
            if menuActive {
                // Frozen picture only when the game does NOT render under the menu.
                if !vcMenuLiveWorld, frozenWorldTexture == nil, heldWorldValid { frozenWorldTexture = gameTexture }
                // Freeze the (upright) head pose once per menu session; the panel is drawn
                // relative to it (see menuViewMatrix).
                if menuFrozenPose == nil, let a = drawables.first?.deviceAnchor {
                    menuFrozenPose = vcUprightPose(a.originFromAnchorTransform)
                }
            } else {
                frozenWorldTexture = nil
                menuFrozenPose = nil
            }
            let worldTexture = (menuActive && !vcMenuLiveWorld) ? (frozenWorldTexture ?? gameTexture) : gameTexture
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

        // Foveation unwarp: if the slices were rendered with a rate map, cache its
        // parameter data (once) so the fragment shader can convert logical->physical when
        // sampling the warped slice. nil when VC_FOVEATE is off -> plain sampling path.
        var foveActive = false
        if !vcStereoTestFill, let ratePtr = vc_foveation_rate_map() {
            if foveRateBuffer == nil || foveRateMapPtr != ratePtr {
                let rateMap = Unmanaged<AnyObject>.fromOpaque(ratePtr).takeUnretainedValue() as! MTLRasterizationRateMap
                let sa = rateMap.parameterDataSizeAndAlign
                if let buf = device.makeBuffer(length: sa.size, options: [.storageModeShared]) {
                    rateMap.copyParameterData(buffer: buf, offset: 0)
                    buf.label = "FoveationRateParams"
                    foveRateBuffer = buf
                    foveRateMapPtr = ratePtr
                }
            }
            foveActive = (foveRateBuffer != nil)
        }

        for drawable in drawables {
            let renderPassDescriptor = MTLRenderPassDescriptor()
            renderPassDescriptor.colorAttachments[0].texture = drawable.colorTextures[0]
            // This is the first pass that touches the drawable in a stereo frame, so CLEAR
            // it: the compositor's drawable contents are undefined, and the quad does not
            // cover the whole frustum (it is sized to the symmetric FOV scale p0/p5 while
            // the real per-eye frustum is off-centre, more so downwards). With .load the
            // uncovered band showed stale/undefined pixels -- visible on the M2 during the
            // black fade-in as "seeing through below the black plane" (2026-10-08).
            renderPassDescriptor.colorAttachments[0].loadAction = .clear
            // Diagnostic: VC_STEREO_CLEAR=magenta paints the drawable area the quad does NOT
            // cover in magenta, so a head-locked stripe can be attributed to the quad edge
            // (magenta) or to slice content (keeps its colour). Default black.
            renderPassDescriptor.colorAttachments[0].clearColor = vcStereoClearMagenta
                ? MTLClearColor(red: 1, green: 0, blue: 1, alpha: 1)
                : MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            renderPassDescriptor.depthAttachment.texture = drawable.depthTextures[0]
            renderPassDescriptor.depthAttachment.loadAction = .clear
            renderPassDescriptor.depthAttachment.clearDepth = 0.0   // reverse-Z: 0 = far
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
            renderEncoder.setRenderPipelineState(vcStereoTestFill ? gameStereoTestPipeline
                                                 : (foveActive ? gameStereoFoveatedPipeline : gameStereoPipeline))
            if foveActive, let rb = foveRateBuffer {
                // Bind the rate map parameter data + slice size for the unwarp fragment.
                renderEncoder.setFragmentBuffer(rb, offset: 0, index: 0)
                var texSize = SIMD2<Float>(Float(texture.width), Float(texture.height))
                renderEncoder.setFragmentBytes(&texSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            }
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
                // Head-locked while playing AND (by default) during the pause menu, so
                // the frozen picture has no visible edges; VC_MENU_WORLD=room hangs it in
                // the room with the panel (menuViewMatrix).
                let viewMatrix = (vcMenuWorldInRoom && !vcMenuLiveWorld)
                    ? menuViewMatrix(view: view, drawable: drawable)
                    : view.transform.inverse
                let projectionMatrix = drawable.computeProjection(viewIndex: i)
                viewProjection[i] = projectionMatrix * viewMatrix
            }

            let nowDraw = CFAbsoluteTimeGetCurrent()
            if vc_perf_log() != 0, nowDraw - lastStereoDrawLogTime >= 1.0 {
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

    /// Opaque black frame: colour black with alpha 1 AND depth cleared (reverse-Z far), over
    /// the whole drawable including the band outside the quads. Used for the load hold, the
    /// splash hold and the "no valid world yet" state, so no path can show stale slices or a
    /// transparent region.
    private func encodeBlackFrame(drawables: [LayerRenderer.Drawable], commandBuffer: MTLCommandBuffer, label: String) {
        for drawable in drawables {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = drawable.colorTextures[0]
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            rp.colorAttachments[0].storeAction = .store
            rp.depthAttachment.texture = drawable.depthTextures[0]
            rp.depthAttachment.loadAction = .clear
            rp.depthAttachment.clearDepth = 0.0   // reverse-Z: 0 = far
            rp.depthAttachment.storeAction = .store
            rp.rasterizationRateMap = drawable.rasterizationRateMaps.first
            if layerRenderer.configuration.layout == .layered {
                rp.renderTargetArrayLength = drawable.views.count
            }
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rp) {
                enc.label = label
                enc.endEncoding()
            }
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
                // HUD and splash: head-locked. Menu panel: in the room at the menu-open
                // pose (menuViewMatrix falls back to head-locked when not in the menu).
                let viewMatrix = (menuActive && quadOverride == nil)
                    ? menuViewMatrix(view: view, drawable: drawable)
                    : view.transform.inverse
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

    /// View matrix for quads whose vertices are defined in device (head) space. Playing:
    /// head-locked (view.transform.inverse). Pause menu with VC_MENU_ANCHOR on: the quad is
    /// placed in the ROOM at the pose frozen when the menu opened -- world->eye of the
    /// current frame times the frozen device->world pose -- so turning the head leaves the
    /// panel (and the frozen world picture) where they were.
    private func menuViewMatrix(view: LayerRenderer.Drawable.View, drawable: LayerRenderer.Drawable) -> simd_float4x4 {
        if vcMenuAnchorInRoom, vc_menu_active() != 0, let pose = menuFrozenPose {
            // Live world: use the RENDER anchor (A) that the slices were baked with and
            // that is reported to the compositor, so panel and world reproject together.
            let anchor = (vcMenuLiveWorld && vcReprojFix) ? (heldRenderAnchor ?? drawable.deviceAnchor) : drawable.deviceAnchor
            if let anchor {
                return (anchor.originFromAnchorTransform * view.transform).inverse * pose
            }
        }
        return view.transform.inverse
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
                // Digital Crown / immersive space dismissed. Same as the quit path below:
                // there is no clean in-process re-open (game singletons + ANGLE don't
                // re-init), so re-entering from the launcher would just render black.
                // Terminate instead -- a fresh launch starts clean.
                print("[vc-loop] layer invalidated (Digital Crown) -> terminating app")
                exit(0)
            } else if layerRenderer.state == .paused {
                Task { @MainActor in
                    appModel.immersiveSpaceState = .inTransition
                }
                layerRenderer.waitUntilRunning()
                continue
            } else if vc_wants_quit() != 0 {
                // Game asked to quit (pause-menu Quit -> RsGlobal.quit). There is no
                // clean "resume from launcher" path (game singletons + ANGLE don't
                // re-init in-process), so terminate: a fresh launch starts clean. The
                // game thread has already unwound its own loop on RsGlobal.quit.
                print("[vc-loop] quit requested -> terminating app")
                exit(0)
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

