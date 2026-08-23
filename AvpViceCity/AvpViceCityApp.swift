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
    }
}

@main
struct AvpViceCityApp: App {

    @State private var appModel = AppModel()

    init() {
        // Start observing game controllers at launch (main thread). Input flows
        // event-driven into the C seam; the render loop is untouched.
        GamepadInput.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
        }

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveSpaceContent(appModel: appModel)
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}