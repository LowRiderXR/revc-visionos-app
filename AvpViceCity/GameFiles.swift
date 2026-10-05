//
//  GameFiles.swift
//  AvpViceCity
//
//  Game-data installation for the launcher (multiview-plan.md "Spieldatei-Auswahl").
//
//  Layout (all under the app's Documents, which is visible in the Files app):
//    Documents/Game/                      the game data (excluded from iCloud/device backup)
//    Documents/Game.incoming/             staging while installing; never half-installed Game/
//    Documents/GTA Vice City User Files/  saves, gta_vc.set, reVC.ini -- never touched here
//
//  Source: a folder or a ZIP (iCloud Drive placeholders are downloaded first). The data root
//  is found by searching a few levels deep for models/gta3.img. Only the folders reVC opens
//  are copied (see `requiredFolders`/`optionalFolders`), everything else in the user's game
//  folder is ignored. After the copy the reVC add-on files (built from Source/reVC/gamefiles
//  into the bundle as revc-gamefiles.zip) are laid over the originals, then the staging
//  folder is renamed to Game/.
//
//  Migration (first start of this version): data folders still in the Documents root are
//  moved into Game/ after the saves and reVC.ini were backed up. Rule for the development
//  path: fresh data in the root REPLACES an existing Game/.
//

import Foundation

enum GameFilesError: LocalizedError {
    case noDocuments
    case noAccess(String)
    case notFound                      // no models/gta3.img anywhere in the selection
    case definitiveEdition
    case missingRequired([String])
    case notEnoughSpace(needed: Int64, free: Int64)
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noDocuments: return "Documents folder not found."
        case .noAccess(let n): return "No access to \(n)."
        case .notFound:
            return "No Vice City game data found: models/gta3.img is missing. Select a ZIP of a classic PC installation of GTA Vice City (2003)."
        case .definitiveEdition:
            return "This looks like GTA Vice City – The Definitive Edition. Only the classic PC version (2003, Steam or retail disc) works."
        case .missingRequired(let list):
            return "The game data is incomplete. Missing: " + list.prefix(8).joined(separator: ", ") + (list.count > 8 ? " and \(list.count - 8) more" : "") + "."
        case .notEnoughSpace(let needed, let free):
            let f = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            let n = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
            return "Not enough free space: \(n) needed, \(f) available."
        case .cancelled: return "Installation cancelled."
        case .failed(let w): return "Installation failed: \(w)"
        }
    }
}

/// Progress published to the UI while installing.
struct GameInstallProgress: Sendable {
    var phase: String = ""
    var fraction: Double? = nil      // nil = indeterminate
    var detail: String = ""
}

enum GameFiles {

    // MARK: locations

    static var documents: URL? { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first }
    static var gameFolder: URL? { documents?.appendingPathComponent("Game", isDirectory: true) }
    static var incomingFolder: URL? { documents?.appendingPathComponent("Game.incoming", isDirectory: true) }
    static var userFilesFolder: URL? { documents?.appendingPathComponent(SaveGameStore.userFilesName, isDirectory: true) }

    /// Folders reVC opens (data root relative, matched case-insensitively). Everything the
    /// PC installer adds beyond these (Icons, ReadMe, Redistributables, mss, exe...) is
    /// ignored. movies/ is skipped on visionOS (no intro movies) and not copied.
    static let requiredFolders = ["anim", "audio", "data", "models", "text", "txd"]
    static let optionalFolders = ["mp3", "skins", "neo"]
    static let optionalRootFiles = ["gamecontrollerdb.txt"]
    /// Files never copied even inside the folders above.
    static let ignoredFileNames: Set<String> = ["sound.cache", ".ds_store", "thumbs.db", "desktop.ini"]

    /// Required files (data-root relative, lower case): files the 2003 PC release ships AND
    /// reVC opens by name. Files the game generates itself are deliberately absent:
    /// models/txd.img + txd.dir (CreateTxdImageForVideoCard, only for GPUs without DXT),
    /// data/waterpro.dat is shipped (and only rewritten in debug builds). data/paths/tracks.dat
    /// is GTA III only (Train.cpp behind GTA_TRAIN, not defined for VC). The radio stations
    /// are the nine ADF streams of StreamedNameTable.
    static let requiredFiles: [String] = [
        "models/gta3.img", "models/gta3.dir",
        "models/hud.txd", "models/fonts.txd", "models/fronten1.txd", "models/fronten2.txd",
        "models/particle.txd", "models/generic.txd", "models/coll/peds.col",
        "data/gta_vc.dat", "data/default.dat", "data/default.ide", "data/main.scm",
        "data/handling.cfg", "data/carcols.dat", "data/particle.cfg", "data/timecyc.dat",
        "data/water.dat", "data/waterpro.dat", "data/object.dat", "data/surface.dat",
        "data/maps/generic.ide",
        "anim/ped.ifp", "anim/cuts.img", "anim/cuts.dir",
        "audio/sfx.raw", "audio/sfx.sdt",
        "audio/wild.adf", "audio/flash.adf", "audio/kchat.adf", "audio/fever.adf", "audio/vrock.adf",
        "audio/vcpr.adf", "audio/espant.adf", "audio/emotion.adf", "audio/wave.adf",
        "text/american.gxt",
        "txd/loadsc0.txd",
    ]

    // MARK: status

    static func isInstalled() -> Bool {
        guard let g = gameFolder else { return false }
        return findCaseInsensitive(in: g, relative: "models/gta3.img") != nil
    }

    static func installedSize() -> Int64 {
        guard let g = gameFolder else { return 0 }
        return folderSize(g)
    }

    static func folderSize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let f as URL in e {
                if let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true {
                    total += Int64(v.fileSize ?? 0)
                }
            }
        }
        return total
    }

    /// Case-insensitive lookup of a relative path below `root` (reVC itself opens files
    /// case-insensitively via fcaseopen).
    static func findCaseInsensitive(in root: URL, relative: String) -> URL? {
        var cur = root
        for comp in relative.split(separator: "/").map(String.init) {
            guard let items = try? FileManager.default.contentsOfDirectory(at: cur, includingPropertiesForKeys: nil, options: []) else { return nil }
            guard let hit = items.first(where: { $0.lastPathComponent.lowercased() == comp.lowercased() }) else { return nil }
            cur = hit
        }
        return cur
    }

    // MARK: startup housekeeping

    /// Called at launch: removes a staging folder left behind by an interrupted install,
    /// migrates root-level data into Game/, excludes Game/ from backups.
    static func housekeeping() {
        guard let docs = documents, let game = gameFolder, let incoming = incomingFolder else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: incoming.path) {
            try? fm.removeItem(at: incoming)
            print("[vc-files] removed leftover \(incoming.lastPathComponent)")
        }
        migrateRootData(docs: docs, game: game)
        if fm.fileExists(atPath: game.path) { excludeFromBackup(game) }
    }

    static func excludeFromBackup(_ url: URL) {
        var u = url
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        do { try u.setResourceValues(v) } catch { print("[vc-files] excludeFromBackup failed: \(error)") }
    }

    /// Root-level data (the pre-Game/ layout and the Xcode development path) -> Game/.
    /// Saves + reVC.ini are backed up first; fresh root data replaces an existing Game/.
    private static func migrateRootData(docs: URL, game: URL) {
        let fm = FileManager.default
        guard findCaseInsensitive(in: docs, relative: "models/gta3.img") != nil else { return }
        print("[vc-files] migrating root-level game data into Game/")
        // 1. backup saves + ini
        if let user = userFilesFolder {
            let stamp = SaveGameStore.stamp()
            let b = user.appendingPathComponent("backup-\(stamp)", isDirectory: true)
            var toBackup = SaveGameStore.localSaves()
            let setFile = user.appendingPathComponent("gta_vc.set")
            if fm.fileExists(atPath: setFile.path) { toBackup.append(setFile) }
            let rootIni = docs.appendingPathComponent("reVC.ini")
            if fm.fileExists(atPath: rootIni.path) { toBackup.append(rootIni) }
            if !toBackup.isEmpty {
                try? fm.createDirectory(at: b, withIntermediateDirectories: true)
                for f in toBackup { try? fm.copyItem(at: f, to: b.appendingPathComponent(f.lastPathComponent)) }
                print("[vc-files]   backed up \(toBackup.count) files to \(b.lastPathComponent)")
            }
        }
        // 2. replace an existing Game/
        if fm.fileExists(atPath: game.path) {
            try? fm.removeItem(at: game)
            print("[vc-files]   existing Game/ replaced by the root data")
        }
        try? fm.createDirectory(at: game, withIntermediateDirectories: true)
        // 3. move the data folders (rename, same volume) -- movies too, to leave a clean root
        let movable = requiredFolders + optionalFolders + ["movies"]
        if let items = try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil, options: []) {
            for item in items {
                let name = item.lastPathComponent
                let lower = name.lowercased()
                if movable.contains(lower) || optionalRootFiles.contains(lower) {
                    do {
                        try fm.moveItem(at: item, to: game.appendingPathComponent(name))
                        print("[vc-files]   moved \(name)")
                    } catch { print("[vc-files]   move \(name) failed: \(error)") }
                }
            }
        }
        // 4. reVC.ini -> user files (the game reads it there from now on)
        let rootIni = docs.appendingPathComponent("reVC.ini")
        if fm.fileExists(atPath: rootIni.path), let user = userFilesFolder {
            try? fm.createDirectory(at: user, withIntermediateDirectories: true)
            let dst = user.appendingPathComponent("reVC.ini")
            if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
            try? fm.moveItem(at: rootIni, to: dst)
            print("[vc-files]   moved reVC.ini to \(SaveGameStore.userFilesName)")
        }
        excludeFromBackup(game)
    }

    // MARK: remove

    static func remove() throws {
        guard let game = gameFolder else { throw GameFilesError.noDocuments }
        if FileManager.default.fileExists(atPath: game.path) { try FileManager.default.removeItem(at: game) }
        print("[vc-files] Game/ removed")
    }
}

// MARK: - installer

@Observable
@MainActor
final class GameInstaller {
    var progress = GameInstallProgress()
    var running = false
    private(set) var cancelRequested = false

    func cancel() { cancelRequested = true }

    /// Installs from a folder or a ZIP file. Throws GameFilesError / ZipError.
    func install(from selection: URL) async throws {
        running = true; cancelRequested = false
        defer { running = false }
        guard let incoming = GameFiles.incomingFolder, let game = GameFiles.gameFolder, let docs = GameFiles.documents else {
            throw GameFilesError.noDocuments
        }
        guard selection.startAccessingSecurityScopedResource() else { throw GameFilesError.noAccess(selection.lastPathComponent) }
        defer { selection.stopAccessingSecurityScopedResource() }

        let fm = FileManager.default
        if fm.fileExists(atPath: incoming.path) { try fm.removeItem(at: incoming) }
        try fm.createDirectory(at: incoming, withIntermediateDirectories: true)
        var ok = false
        defer { if !ok { try? fm.removeItem(at: incoming) } }

        let isZip = selection.pathExtension.lowercased() == "zip"
        if isZip {
            try await ensureDownloaded(selection)
            try await installFromZip(selection, into: incoming, docs: docs)
        } else {
            try await installFromFolder(selection, into: incoming, docs: docs)
        }
        try overlayAddons(into: incoming)
        try Self.validate(root: incoming)

        progress = GameInstallProgress(phase: "Finishing…", fraction: nil, detail: "")
        if fm.fileExists(atPath: game.path) { try fm.removeItem(at: game) }
        try fm.moveItem(at: incoming, to: game)
        GameFiles.excludeFromBackup(game)
        ok = true
        print("[vc-files] installed into Game/ (\(ByteCountFormatter.string(fromByteCount: GameFiles.folderSize(game), countStyle: .file)))")
    }

    // MARK: folder source

    private func installFromFolder(_ selection: URL, into incoming: URL, docs: URL) async throws {
        progress = GameInstallProgress(phase: "Looking for game data…", fraction: nil)
        guard let root = Self.findDataRoot(folder: selection, depth: 4) else {
            if Self.looksLikeDefinitiveEdition(folder: selection) { throw GameFilesError.definitiveEdition }
            throw GameFilesError.notFound
        }
        let files = Self.collectFiles(root: root)
        guard !files.isEmpty else { throw GameFilesError.notFound }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        try Self.checkFreeSpace(docs: docs, needed: total)

        // iCloud placeholders: download first
        let placeholders = files.filter { Self.isPlaceholder($0.src) }
        if !placeholders.isEmpty {
            for (i, p) in placeholders.enumerated() {
                if cancelRequested { throw GameFilesError.cancelled }
                progress = GameInstallProgress(phase: "Downloading from iCloud Drive…", fraction: Double(i) / Double(placeholders.count), detail: p.src.lastPathComponent)
                try await ensureDownloaded(p.src, countPrefix: "\(i + 1)/\(placeholders.count)  ")
            }
        }

        var done: Int64 = 0
        let fm = FileManager.default
        for f in files {
            if cancelRequested { throw GameFilesError.cancelled }
            progress = GameInstallProgress(phase: "Copying…", fraction: total > 0 ? Double(done) / Double(total) : nil,
                                           detail: "\(f.rel)  (\(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)))")
            let dst = incoming.appendingPathComponent(f.rel)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await Task.detached(priority: .userInitiated) { try fm.copyItem(at: f.src, to: dst) }.value
            done += f.size
        }
    }

    // MARK: zip source

    private func installFromZip(_ zipURL: URL, into incoming: URL, docs: URL) async throws {
        progress = GameInstallProgress(phase: "Reading archive…", fraction: nil)
        let reader = try ZipReader(url: zipURL)
        // data root inside the archive: the directory holding models/gta3.img
        var rootPrefix: [String]? = nil
        for e in reader.entries where !e.isDirectory {
            guard let comps = e.safeComponents, comps.count >= 2 else { continue }
            if comps[comps.count - 1].lowercased() == "gta3.img", comps[comps.count - 2].lowercased() == "models" {
                let prefix = Array(comps.dropLast(2))
                if prefix.first?.lowercased() == "__macosx" { continue }
                if rootPrefix == nil || prefix.count < rootPrefix!.count { rootPrefix = prefix }
            }
        }
        guard let prefix = rootPrefix else {
            let looksDE = reader.entries.contains { ($0.safeComponents ?? []).contains { $0.lowercased() == "gameface" || $0.lowercased().hasSuffix(".pak") } }
            throw looksDE ? GameFilesError.definitiveEdition : GameFilesError.notFound
        }
        // select entries
        var selected: [(entry: ZipEntry, rel: String)] = []
        for e in reader.entries where !e.isDirectory {
            guard let comps = e.safeComponents else { throw ZipError.unsafePath(e.name) }
            guard comps.count > prefix.count else { continue }
            if comps.first?.lowercased() == "__macosx" { continue }
            if comps.last!.hasPrefix("._") { continue }
            var match = true
            for (i, p) in prefix.enumerated() where comps[i].lowercased() != p.lowercased() { match = false; break }
            if !match { continue }
            let rel = Array(comps.dropFirst(prefix.count))
            let top = rel[0].lowercased()
            if rel.count == 1 {
                if !GameFiles.optionalRootFiles.contains(top) { continue }
            } else if !(GameFiles.requiredFolders.contains(top) || GameFiles.optionalFolders.contains(top)) { continue }
            if GameFiles.ignoredFileNames.contains(rel.last!.lowercased()) { continue }
            selected.append((e, rel.joined(separator: "/")))
        }
        guard !selected.isEmpty else { throw GameFilesError.notFound }
        let total = selected.reduce(Int64(0)) { $0 + Int64($1.entry.uncompressedSize) }
        try Self.checkFreeSpace(docs: docs, needed: total)

        var done: Int64 = 0
        let fm = FileManager.default
        for s in selected {
            if cancelRequested { throw GameFilesError.cancelled }
            let base = done
            progress = GameInstallProgress(phase: "Unpacking…", fraction: total > 0 ? Double(done) / Double(total) : nil,
                                           detail: "\(s.rel)  (\(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)))")
            let dst = incoming.appendingPathComponent(s.rel)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            let entry = s.entry
            try await Task.detached(priority: .userInitiated) {
                try reader.extract(entry, to: dst) { written in
                    _ = written; _ = base   // per-file progress stays file-granular (UI updates per file)
                }
            }.value
            done += Int64(entry.uncompressedSize)
        }
    }

    // MARK: add-ons from the bundle

    /// Lays the reVC add-on files (revc-gamefiles.zip in the bundle, built from
    /// Source/reVC/gamefiles) over the copied originals. Missing resource = skipped with a log.
    private func overlayAddons(into incoming: URL) throws {
        guard let zip = Bundle.main.url(forResource: "revc-gamefiles", withExtension: "zip") else {
            print("[vc-files] revc-gamefiles.zip not in bundle -- add-ons not overlaid (dev build without the script phase)")
            return
        }
        progress = GameInstallProgress(phase: "Applying reVC files…", fraction: nil)
        let reader = try ZipReader(url: zip)
        let fm = FileManager.default
        var n = 0
        for e in reader.entries where !e.isDirectory {
            guard let comps = e.safeComponents else { throw ZipError.unsafePath(e.name) }
            if comps.first?.lowercased() == "__macosx" || comps.last!.hasPrefix("._") { continue }
            // the originals may use a different case (TEXT vs text): replace the existing file
            let rel = comps.joined(separator: "/")
            let dst = GameFiles.findCaseInsensitive(in: incoming, relative: rel) ?? incoming.appendingPathComponent(rel)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try reader.extract(e, to: dst)
            n += 1
        }
        print("[vc-files] overlaid \(n) reVC add-on files")
    }

    // MARK: helpers

    /// Files to copy from a data root: everything inside the required/optional folders plus
    /// the optional root files, minus the ignored names. Synchronous (directory enumerator).
    static func collectFiles(root: URL) -> [(src: URL, rel: String, size: Int64)] {
        var files: [(src: URL, rel: String, size: Int64)] = []
        let fm = FileManager.default
        let topItems = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [])) ?? []
        for item in topItems {
            let lower = item.lastPathComponent.lowercased()
            var isDir: ObjCBool = false
            fm.fileExists(atPath: item.path, isDirectory: &isDir)
            if isDir.boolValue, GameFiles.requiredFolders.contains(lower) || GameFiles.optionalFolders.contains(lower) {
                if let e = fm.enumerator(at: item, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []) {
                    for case let f as URL in e {
                        guard let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
                        if GameFiles.ignoredFileNames.contains(f.lastPathComponent.lowercased()) { continue }
                        let rel = f.path.hasPrefix(root.path) ? String(f.path.dropFirst(root.path.count + 1)) : f.lastPathComponent
                        files.append((f, rel, Int64(v.fileSize ?? 0)))
                    }
                }
            } else if !isDir.boolValue, GameFiles.optionalRootFiles.contains(lower) {
                let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                files.append((item, item.lastPathComponent, Int64(size)))
            }
        }
        return files
    }

    static func findDataRoot(folder: URL, depth: Int) -> URL? {
        if GameFiles.findCaseInsensitive(in: folder, relative: "models/gta3.img") != nil { return folder }
        guard depth > 0, let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }
        for item in items {
            if item.lastPathComponent == "__MACOSX" { continue }
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
               let hit = findDataRoot(folder: item, depth: depth - 1) { return hit }
        }
        return nil
    }

    static func looksLikeDefinitiveEdition(folder: URL) -> Bool {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return false }
        var n = 0
        for case let f as URL in e {
            n += 1; if n > 5000 { break }
            let l = f.lastPathComponent.lowercased()
            if l == "gameface" || l.hasSuffix(".pak") || l.hasSuffix("-windowsnoeditor.pak") { return true }
        }
        return false
    }

    static func validate(root: URL) throws {
        var missing: [String] = []
        for rel in GameFiles.requiredFiles where GameFiles.findCaseInsensitive(in: root, relative: rel) == nil {
            missing.append(rel)
        }
        if !missing.isEmpty { throw GameFilesError.missingRequired(missing) }
    }

    static func checkFreeSpace(docs: URL, needed: Int64) throws {
        let v = try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = v?.volumeAvailableCapacityForImportantUsage ?? Int64.max
        let margin: Int64 = 200 * 1024 * 1024
        if free < needed + margin { throw GameFilesError.notEnoughSpace(needed: needed + margin, free: free) }
    }

    static func isPlaceholder(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              v.isUbiquitousItem == true, let st = v.ubiquitousItemDownloadingStatus else { return false }
        return st != .current
    }

    /// Starts the iCloud download of a placeholder and waits for it, publishing the
    /// percentage (NSMetadataQuery on the item; polled every half second).
    private func ensureDownloaded(_ url: URL, countPrefix: String = "") async throws {
        guard Self.isPlaceholder(url) else { return }
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        let name = url.lastPathComponent
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope, NSMetadataQueryUbiquitousDataScope,
                              NSMetadataQueryAccessibleUbiquitousExternalDocumentsScope]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemPathKey, url.path)
        query.start()
        defer { query.stop() }
        var ticks = 0
        while Self.isPlaceholder(url) {
            if cancelRequested { throw GameFilesError.cancelled }
            ticks += 1
            query.disableUpdates()
            let pct = (query.results.first as? NSMetadataItem)?.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? Double
            query.enableUpdates()
            let detail = pct.map { "\(countPrefix)\(name)  \(Int($0))%" } ?? "\(countPrefix)\(name)"
            progress = GameInstallProgress(phase: "Downloading from iCloud Drive…", fraction: pct.map { $0 / 100.0 }, detail: detail)
            try await Task.sleep(nanoseconds: 500_000_000)
            if ticks > 7200 { throw GameFilesError.failed("iCloud download of \(name) did not finish") }   // 1 h
        }
    }
}
