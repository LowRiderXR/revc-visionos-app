//
//  ContentView.swift
//  AvpViceCity
//
//  Created by Christian Schmid on 10.08.2026.
//

import SwiftUI

struct ContentView: View {

    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow

    // Persisted across launches. Keys == env-var names the renderer reads
    // (see GameSettings). Changing these here writes UserDefaults immediately;
    // GameSettings.applyToEnvironment() pushes them to the environment on start.
    @AppStorage("VC_HUD_SIZE") private var hudSize: Double = GameSettings.hudSizeDefault
    @AppStorage("VC_MSAA") private var msaa: Int = GameSettings.msaaDefault
    @AppStorage("VC_RES") private var res: Int = GameSettings.resDefault

    var body: some View {
        VStack(spacing: 18) {
            Text("Vice City — visionOS")
                .font(.title2).fontWeight(.bold)

            VStack(alignment: .leading, spacing: 14) {
                // HUD-Größe
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("HUD-Größe")
                        Spacer()
                        Text(String(format: "%.2f×", hudSize))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $hudSize, in: 0...1, step: 0.05)
                }

                // MSAA (Kantenglättung)
                VStack(alignment: .leading, spacing: 4) {
                    Text("MSAA (Kantenglättung)")
                    Picker("MSAA", selection: $msaa) {
                        ForEach(GameSettings.msaaOptions, id: \.self) { n in
                            Text(n == 0 ? "Aus" : "\(n)×").tag(n)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                // Auflösung pro Auge (VC_RES-Stufe)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Auflösung/Auge")
                        Spacer()
                        Text(GameSettings.resLabel(res))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Picker("Auflösung", selection: $res) {
                        ForEach(GameSettings.resOptions, id: \.self) { n in
                            Text("\(n)").tag(n)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

            Button(action: startGame) {
                Label("Vice City starten", systemImage: "play.fill")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(appModel.immersiveSpaceState != .closed)

            Text("Einstellungen werden gespeichert.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 320)
    }

    private func startGame() {
        // Persisted settings -> environment, so the render loop + reVC read the chosen
        // values for THIS session (they read env after the immersive space opens).
        GameSettings.applyToEnvironment()

        Task { @MainActor in
            guard appModel.immersiveSpaceState == .closed else { return }
            appModel.immersiveSpaceState = .inTransition
            switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
            case .opened:
                appModel.immersiveSpaceState = .open
                dismissWindow(id: "main")        // Startfenster ausblenden
            case .userCancelled, .error:
                appModel.immersiveSpaceState = .closed
            @unknown default:
                appModel.immersiveSpaceState = .closed
            }
        }
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
