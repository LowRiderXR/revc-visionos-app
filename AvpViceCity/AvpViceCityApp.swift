//
//  AvpViceCityApp.swift
//  AvpViceCity
//
//  Created by Christian Schmid on 10.08.2026.
//

import ARKit
import CompositorServices
import SwiftUI

struct ImmersiveSpaceContent: CompositorContent {

    var appModel: AppModel

    var body: some CompositorContent {
        CompositorLayer(configuration: self) { @MainActor layerRenderer in
            Renderer.startRenderLoop(layerRenderer, appModel: appModel, arSession: ARKitSession())
        }
    }
}

extension ImmersiveSpaceContent: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        let foveationEnabled = capabilities.supportsFoveation
        configuration.isFoveationEnabled = foveationEnabled

        let options: LayerRenderer.Capabilities.SupportedLayoutsOptions = foveationEnabled ? [.foveationEnabled] : []
        let supportedLayouts = capabilities.supportedLayouts(options: options)

        configuration.layout = supportedLayouts.contains(.layered) ? .layered : .dedicated

        // visionOS 26: raise the drawable's MAX render quality (PPD ceiling; memory cost).
        // Requires foveation. The per-frame renderQuality (GPU cost) is set on the
        // layerRenderer in the render loop. VC_MAX_RENDER_QUALITY (0..1, default 1.0).
        // VC_MAX_RENDER_QUALITY="off" -> do NOT touch maxRenderQuality (system default ~26 PPD
        // drawable) -- the A/B to test whether raising it is what introduced the memory growth.
        let mqEnv = ProcessInfo.processInfo.environment["VC_MAX_RENDER_QUALITY"]
        if foveationEnabled && mqEnv != "off" {
            let mq = mqEnv.flatMap { Float($0) } ?? 1.0
            configuration.maxRenderQuality = LayerRenderer.RenderQuality(max(0.0, min(1.0, mq)))
        }

        // Drawable colour format: default rgba16Float (HDR, 8 bytes/px). ALVR/Klepton use
        // bgra8Unorm_srgb (4 bytes/px) -> HALF the drawable memory. VC_DRAWABLE_8BIT=1 to A/B.
        if ProcessInfo.processInfo.environment["VC_DRAWABLE_8BIT"] == "1" {
            configuration.colorFormat = .bgra8Unorm_srgb
        }
        print("[vc-fmt] drawable colorFormat rawValue=\(configuration.colorFormat.rawValue)")
    }
}

@main
struct AvpViceCityApp: App {

    @State private var appModel = AppModel()

    init() {
        // Persisted launch settings (VC_HUD_SIZE / VC_MSAA) -> environment, BEFORE any
        // consumer (drawable config, render loop, reVC) reads them.
        GameSettings.applyToEnvironment()

        // Configure the audio session BEFORE OpenAL opens its device (that happens
        // later on the game thread). .playback is window-independent, so audio
        // survives closing the 2D window.
        GameAudioSession.configure()

        // Start observing game controllers at launch (main thread). Input flows
        // event-driven into the C seam; the render loop is untouched.
        GamepadInput.shared.start()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(appModel)
        }
        // On visionOS the window follows the Scene size, not the content's .frame.
        // Tie it to the content and give a small default so the launcher is compact.
        .windowResizability(.contentSize)
        .defaultSize(width: 340, height: 340)

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveSpaceContent(appModel: appModel)
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}