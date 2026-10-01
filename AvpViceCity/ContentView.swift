//
//  ContentView.swift
//  AvpViceCity
//
//  Created by Christian Schmid on 10.08.2026.
//

import SwiftUI
import UniformTypeIdentifiers

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
    @AppStorage("VC_AIM_SENSITIVITY") private var aimSensitivity: Double = GameSettings.aimSensitivityDefault
    @AppStorage("VC_MULTIVIEW") private var multiview: Bool = GameSettings.multiviewDefault

    // Save-game export / import (SaveGameTransfer.swift). Folder pickers via fileImporter;
    // the import shows its plan first and takes settings only when the toggle is on.
    @State private var showExportPicker = false
    @State private var showImportPicker = false
    @State private var importPlan: SaveImportPlan? = nil
    @State private var importSettingsToo = false
    @State private var transferMessage: String? = nil

    var body: some View {
        VStack(spacing: 22) {
            Text("Vice City - visionOS")
                .font(.title2).fontWeight(.bold)

            VStack(alignment: .leading, spacing: 18) {
                // HUD size
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("HUD Size")
                        Spacer()
                        Text(String(format: "%.2fx", hudSize))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $hudSize, in: 0...1, step: 0.05)
                }

                // MSAA (anti-aliasing)
                VStack(alignment: .leading, spacing: 4) {
                    Text("MSAA (Anti-Aliasing)")
                    Picker("MSAA", selection: $msaa) {
                        ForEach(GameSettings.msaaOptions, id: \.self) { n in
                            Text(n == 0 ? "Off" : "\(n)x").tag(n)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                // Render resolution per eye (VC_RES step)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Resolution per Eye")
                        Spacer()
                        Text(GameSettings.resLabel(res))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Picker("Resolution", selection: $res) {
                        ForEach(GameSettings.resOptions, id: \.self) { n in
                            Text("\(n)").tag(n)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                // One-pass rendering (OVR_multiview): both eyes in one world pass.
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("One-Pass Rendering (Multiview)", isOn: $multiview)
                    Text("Both eyes in a single pass: lower CPU load, steadier frame rate. Turn off only if something looks wrong.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                // Aim sensitivity (right stick)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Aim Sensitivity")
                        Spacer()
                        Text(String(format: "%.2fx", aimSensitivity))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $aimSensitivity, in: 0.1...2.0, step: 0.05)
                }

                // Back to the device defaults (M5: MSAA 4; M2: MSAA 2). Launcher settings
                // only -- the in-game options (draw distance, map memory) have their own
                // "restore defaults" in the game menu.
                HStack {
                    Spacer()
                    Button {
                        hudSize = GameSettings.hudSizeDefault
                        msaa = GameSettings.msaaDefault
                        res = GameSettings.resDefault
                        aimSensitivity = GameSettings.aimSensitivityDefault
                        multiview = GameSettings.multiviewDefault
                    } label: {
                        Label("Reset to \(GameSettings.isM2Device ? "M2" : "M5") Defaults", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(appModel.immersiveSpaceState != .closed)
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

            // Save games: export to a folder of your choice (new time-stamped sub-folder),
            // import from a folder (saves only by default; asks before replacing slots).
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Save Games")
                    Spacer()
                    Text("\(SaveGameStore.localSaves().count) slot(s)")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button { showExportPicker = true } label: {
                        Label("Export…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .disabled(appModel.immersiveSpaceState != .closed || SaveGameStore.localSaves().isEmpty)
                    Button { showImportPicker = true } label: {
                        Label("Import…", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                    }
                    .disabled(appModel.immersiveSpaceState != .closed)
                }
                .buttonStyle(.bordered)
                Text("Export copies the saves and settings into a dated folder. Import takes saves only, unless you also choose settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

            Button(action: startGame) {
                Label("Start Vice City", systemImage: "play.fill")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(appModel.immersiveSpaceState != .closed)

            Text("Settings are saved automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 440)
        .fileImporter(isPresented: $showExportPicker, allowedContentTypes: [.folder]) { result in
            handleExport(result)
        }
        .fileImporter(isPresented: $showImportPicker, allowedContentTypes: [.folder]) { result in
            handleImportSelection(result)
        }
        .sheet(item: $importPlan) { plan in
            importSheet(plan)
        }
        .alert("Save Games", isPresented: Binding(get: { transferMessage != nil }, set: { if !$0 { transferMessage = nil } })) {
            Button("OK", role: .cancel) { transferMessage = nil }
        } message: {
            Text(transferMessage ?? "")
        }
    }

    // MARK: save-game transfer

    private func handleExport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let folder):
            do {
                let r = try SaveGameStore.export(to: folder)
                transferMessage = "\(r.files) file(s) exported to \(r.folder.lastPathComponent)."
            } catch {
                transferMessage = "Export failed: \(error.localizedDescription)"
            }
        case .failure(let error):
            transferMessage = "Export cancelled: \(error.localizedDescription)"
        }
    }

    private func handleImportSelection(_ result: Result<URL, Error>) {
        switch result {
        case .success(let folder):
            do {
                importSettingsToo = false
                importPlan = try SaveGameStore.planImport(from: folder)
            } catch {
                transferMessage = "Import: \(error.localizedDescription)"
            }
        case .failure(let error):
            transferMessage = "Import cancelled: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func importSheet(_ plan: SaveImportPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Save Games").font(.title3).fontWeight(.bold)
            Text("From: \(plan.source.lastPathComponent)").font(.caption).foregroundStyle(.secondary)
            Text("Slots found: \(plan.slotNumbers.map(String.init).joined(separator: ", "))")
            if plan.conflictingSlots.isEmpty {
                Text("No existing slot will be replaced.").foregroundStyle(.secondary)
            } else {
                Text("Replaces existing slot(s): \(plan.conflictingSlots.map(String.init).joined(separator: ", ")). The current files are copied to a backup folder first.")
                    .foregroundStyle(.orange)
            }
            if !plan.settingsFiles.isEmpty {
                Toggle("Also import settings (\(plan.settingsFiles.map { $0.lastPathComponent }.joined(separator: ", ")))", isOn: $importSettingsToo)
                Text("Settings hold device-specific values (draw distance, map memory). Leave this off when moving saves between an M5 and an M2.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel", role: .cancel) { importPlan = nil }
                Spacer()
                Button(plan.conflictingSlots.isEmpty ? "Import" : "Replace \(plan.conflictingSlots.count) and Import") {
                    do {
                        let r = try SaveGameStore.performImport(plan, includeSettings: importSettingsToo)
                        var msg = "\(r.importedSaves) save(s) imported"
                        if r.importedSettings > 0 { msg += ", \(r.importedSettings) settings file(s)" }
                        if let b = r.backupFolder { msg += ". Previous files backed up to \(b.lastPathComponent)" }
                        transferMessage = msg + "."
                    } catch {
                        transferMessage = "Import failed: \(error.localizedDescription)"
                    }
                    importPlan = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 420)
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
                dismissWindow(id: "main")        // hide the launcher window
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
