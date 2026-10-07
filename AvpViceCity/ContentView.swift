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

    // Save-game export / import (SaveGameTransfer.swift). Folder pickers via fileImporter;
    // the import shows its plan first and takes settings only when the toggle is on.
    @State private var showExportPicker = false
    @State private var showImportPicker = false
    @State private var importPlan: SaveImportPlan? = nil
    @State private var importSettingsToo = false
    @State private var transferMessage: String? = nil
    // "Last export: …" next to the Export button (local only; 0 = never exported).
    @AppStorage("VC_LAST_EXPORT_DATE") private var lastExportTimestamp: Double = 0

    // Game files (GameFiles.swift): install from a folder or ZIP into Documents/Game/.
    @State private var installer = GameInstaller()
    @State private var showInstallPicker = false
    @State private var showInstallProgress = false
    @State private var showInstructions = false
    @State private var installMessage: String? = nil
    @State private var gameInstalled = GameFiles.isInstalled()
    @State private var gameSize: Int64 = GameFiles.installedSize()

    private var lastExportText: String {
        guard lastExportTimestamp > 0 else { return "Never exported" }
        let d = Date(timeIntervalSince1970: lastExportTimestamp)
        return "Last export: " + d.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        VStack(spacing: 22) {
            Text("reVC for visionOS")
                .font(.title2).fontWeight(.bold)

            // Two columns: render/controls settings left, save games + game files right.
            // The right-hand cards stretch to the left column's height so both columns
            // end on the same line.
            HStack(alignment: .top, spacing: 20) {
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
                    } label: {
                        Label("Reset to \(GameSettings.isM2Device ? "M2" : "M5") Defaults", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(appModel.immersiveSpaceState != .closed)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

            VStack(spacing: 20) {
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
                HStack {
                    Text(lastExportText)
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                }
                Text("Export copies the saves and settings into a dated folder. Import takes saves only, unless you also choose settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .fixedSize(horizontal: false, vertical: true)   // never shorter than the text needs (no "Grand T…")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

            // Game files: the original PC game data, installed once into Documents/Game/.
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Game Files")
                    Spacer()
                    if gameInstalled {
                        Label("Installed, \(ByteCountFormatter.string(fromByteCount: gameSize, countStyle: .file))", systemImage: "checkmark.circle.fill")
                            .font(.caption).monospacedDigit().foregroundStyle(.green)
                    } else {
                        Label("Not installed", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button { showInstructions = true } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showInstructions, arrowEdge: .trailing) { instructionsPopover }
                }
                // No Remove button: broken or new data is handled by Replace, and space is
                // freed by exporting the saves and deleting the app -- one less way to
                // delete something by accident.
                Button { showInstallPicker = true } label: {
                    Label(gameInstalled ? "Replace…" : "Install…", systemImage: "folder.badge.plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(appModel.immersiveSpaceState != .closed)
                // Literal strings so the markdown link is parsed (Text(String) would not).
                // The Rockstar Store "Grand Theft Auto: The Trilogy" is the classic 2005
                // compilation of the original games (checked 2026-10-05), not the Definitive Edition.
                if gameInstalled {
                    Text("To replace, choose a ZIP of your Vice City PC folder, for example from iCloud Drive. Original PC version only, not the Definitive Edition ([Rockstar Store](https://store.rockstargames.com/game/buy-grand-theft-auto-the-trilogy)).")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("To install, choose a ZIP of your Vice City PC folder, for example from iCloud Drive. You need the original PC version, not the Definitive Edition; it is sold as [Grand Theft Auto: The Trilogy](https://store.rockstargames.com/game/buy-grand-theft-auto-the-trilogy) in the Rockstar Store. The (i) button explains the steps.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .fixedSize(horizontal: false, vertical: true)   // never shorter than the text needs (no "Grand T…")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)

            Button(action: startGame) {
                Label("Start Vice City", systemImage: "play.fill")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(appModel.immersiveSpaceState != .closed || !gameInstalled)

            Text(gameInstalled ? "Settings are saved automatically." : "Install the game files to start.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 780)
        .onAppear(perform: refreshGameStatus)
        .fileImporter(isPresented: $showInstallPicker, allowedContentTypes: [.zip]) { result in
            handleInstallSelection(result)
        }
        .sheet(isPresented: $showInstallProgress) { installProgressSheet.interactiveDismissDisabled() }
        .alert("Game Files", isPresented: Binding(get: { installMessage != nil }, set: { if !$0 { installMessage = nil } })) {
            Button("OK", role: .cancel) { installMessage = nil }
        } message: {
            Text(installMessage ?? "")
        }
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
                lastExportTimestamp = Date().timeIntervalSince1970
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

    // MARK: game files

    private func refreshGameStatus() {
        gameInstalled = GameFiles.isInstalled()
        gameSize = gameInstalled ? GameFiles.installedSize() : 0
    }

    private func handleInstallSelection(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            showInstallProgress = true
            Task { @MainActor in
                do {
                    try await installer.install(from: url)
                    refreshGameStatus()
                    installMessage = "Game files installed (\(ByteCountFormatter.string(fromByteCount: gameSize, countStyle: .file)))."
                } catch {
                    refreshGameStatus()
                    installMessage = error.localizedDescription
                }
                showInstallProgress = false
            }
        case .failure(let error):
            installMessage = "Install cancelled: \(error.localizedDescription)"
        }
    }

    private var installProgressSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Installing Game Files").font(.title3).fontWeight(.bold)
            Text(installer.progress.phase.isEmpty ? "Preparing…" : installer.progress.phase)
            if let f = installer.progress.fraction {
                ProgressView(value: f)
            } else {
                ProgressView()
            }
            Text(installer.progress.detail)
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(2).frame(minHeight: 32, alignment: .top)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { installer.cancel() }
                    .disabled(installer.cancelRequested)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var instructionsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where to find the game files").font(.headline)
            Text("You need the original PC version of GTA Vice City. The Definitive Edition does not work. The original is sold as [Grand Theft Auto: The Trilogy](https://store.rockstargames.com/game/buy-grand-theft-auto-the-trilogy) in the Rockstar Store.")
            Text("Rockstar Games Launcher: Settings → My installed games → Grand Theft Auto: Vice City → View installation folder.")
            Text("Retail disc: the installation folder, usually C:\\Program Files\\Rockstar Games\\Grand Theft Auto Vice City.")
            Text("Compress that folder into a ZIP file and bring it to the Vision Pro via iCloud Drive (recommended) or AirDrop. Then tap Install and select the ZIP.")
            Text("Save games and settings are stored separately and survive a Replace.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(20)
        .frame(width: 400)
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
