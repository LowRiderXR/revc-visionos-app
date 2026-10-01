//
//  SaveGameTransfer.swift
//  AvpViceCity
//
//  Export / import of the reVC save games and settings from the launcher.
//
//  Where the game keeps them on visionOS (see visionos.cpp vc_fs / _psGetUserFilesFolder):
//    Documents/GTA Vice City User Files/GTAVCsf1.b ... GTAVCsf8.b   save slots
//    Documents/GTA Vice City User Files/gta_vc.set                  menu settings
//    <data root>/reVC.ini                                            reVC settings (data root =
//                                                                    Documents, Documents/Game or
//                                                                    Documents/GTAVC, whichever
//                                                                    holds models/)
//
//  Export copies saves + both settings files into a NEW time-stamped sub-folder of the chosen
//  folder, so earlier backups are never overwritten. Import takes the saves by default and the
//  settings only when asked (they hold device-specific values: draw distance, map memory --
//  an M5 export must not overwrite the M2 defaults). Before the first overwrite, the current
//  saves are copied to a backup-<stamp> folder inside the user-files folder.
//

import Foundation

enum SaveGameTransferError: LocalizedError {
    case noDocuments
    case noAccess(URL)
    case noSavesFound(URL)

    var errorDescription: String? {
        switch self {
        case .noDocuments:        return "Documents folder not found."
        case .noAccess(let u):    return "No access to \(u.lastPathComponent)."
        case .noSavesFound(let u): return "No save games (GTAVCsf*.b) found in \(u.lastPathComponent)."
        }
    }
}

/// What an import would do, shown to the user before anything is written.
struct SaveImportPlan: Identifiable {
    var id: String { source.path }
    let selection: URL              // the folder the user picked (security scope lives here)
    let source: URL                 // folder actually holding the saves (selection or a VC-Saves-* child)
    let saveFiles: [URL]            // GTAVCsf*.b found in the source
    let conflictingSlots: [Int]     // slots that already exist locally
    let settingsFiles: [URL]        // gta_vc.set / reVC.ini found in the source
    var slotNumbers: [Int] { saveFiles.compactMap(SaveGameStore.slotNumber(of:)).sorted() }
}

struct SaveImportResult {
    let importedSaves: Int
    let importedSettings: Int
    let backupFolder: URL?
}

enum SaveGameStore {

    static let userFilesName = "GTA Vice City User Files"
    static let saveFileRegex = try! NSRegularExpression(pattern: "^GTAVCsf([1-8])\\.b$", options: [.caseInsensitive])
    static let settingsNames = ["gta_vc.set", "reVC.ini"]

    static var documents: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    static var userFilesFolder: URL? {
        documents?.appendingPathComponent(userFilesName, isDirectory: true)
    }

    /// Same candidate order as visionos.cpp vc_fs: Documents, Documents/Game, Documents/GTAVC.
    static var dataRoot: URL? {
        guard let docs = documents else { return nil }
        for cand in [docs, docs.appendingPathComponent("Game"), docs.appendingPathComponent("GTAVC")] {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: cand.appendingPathComponent("models").path, isDirectory: &isDir), isDir.boolValue {
                return cand
            }
        }
        return docs
    }

    static func slotNumber(of url: URL) -> Int? {
        let name = url.lastPathComponent
        let range = NSRange(name.startIndex..., in: name)
        guard let m = saveFileRegex.firstMatch(in: name, range: range), m.numberOfRanges == 2,
              let r = Range(m.range(at: 1), in: name) else { return nil }
        return Int(name[r])
    }

    /// Local save files currently present.
    static func localSaves() -> [URL] {
        guard let folder = userFilesFolder else { return [] }
        return listSaves(in: folder)
    }

    static func listSaves(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return items.filter { slotNumber(of: $0) != nil }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Local settings files (gta_vc.set in the user folder, reVC.ini at the data root).
    static func localSettings() -> [URL] {
        var out: [URL] = []
        if let u = userFilesFolder?.appendingPathComponent("gta_vc.set"), FileManager.default.fileExists(atPath: u.path) { out.append(u) }
        if let i = dataRoot?.appendingPathComponent("reVC.ini"), FileManager.default.fileExists(atPath: i.path) { out.append(i) }
        return out
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmm"
        return f.string(from: Date())
    }

    // MARK: export

    /// Copies saves + settings into `<target>/VC-Saves-<stamp>/`. Returns the created folder
    /// and the number of files copied.
    static func export(to target: URL) throws -> (folder: URL, files: Int) {
        guard target.startAccessingSecurityScopedResource() else { throw SaveGameTransferError.noAccess(target) }
        defer { target.stopAccessingSecurityScopedResource() }
        let fm = FileManager.default
        var dest = target.appendingPathComponent("VC-Saves-\(stamp())", isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dest.path) {   // two exports within the same minute
            dest = target.appendingPathComponent("VC-Saves-\(stamp())-\(n)", isDirectory: true); n += 1
        }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var count = 0
        for src in localSaves() + localSettings() {
            try fm.copyItem(at: src, to: dest.appendingPathComponent(src.lastPathComponent))
            count += 1
        }
        print("[vc-saves] export: \(count) files -> \(dest.path)")
        return (dest, count)
    }

    // MARK: import

    /// Inspects the chosen folder (the folder itself; if it holds no saves but exactly one
    /// VC-Saves-* sub-folder, that one). Nothing is written.
    static func planImport(from source: URL) throws -> SaveImportPlan {
        guard source.startAccessingSecurityScopedResource() else { throw SaveGameTransferError.noAccess(source) }
        defer { source.stopAccessingSecurityScopedResource() }
        var folder = source
        var saves = listSaves(in: folder)
        if saves.isEmpty {
            let subs = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("VC-Saves-") }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }   // newest first
            if let newest = subs.first {
                folder = newest
                saves = listSaves(in: folder)
            }
        }
        guard !saves.isEmpty else { throw SaveGameTransferError.noSavesFound(source) }
        let localSlots = Set(localSaves().compactMap(slotNumber(of:)))
        let conflicts = saves.compactMap(slotNumber(of:)).filter { localSlots.contains($0) }.sorted()
        let settings = settingsNames.map { folder.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        return SaveImportPlan(selection: source, source: folder, saveFiles: saves, conflictingSlots: conflicts, settingsFiles: settings)
    }

    /// Executes a plan. Existing local saves/settings that would be replaced are first copied
    /// to `<user files>/backup-<stamp>/`.
    static func performImport(_ plan: SaveImportPlan, includeSettings: Bool) throws -> SaveImportResult {
        guard let userFolder = userFilesFolder, let root = dataRoot else { throw SaveGameTransferError.noDocuments }
        // the plan's folder may be a sub-folder of the picked folder; the security scope belongs
        // to the picked one
        guard plan.selection.startAccessingSecurityScopedResource() else { throw SaveGameTransferError.noAccess(plan.selection) }
        defer { plan.selection.stopAccessingSecurityScopedResource() }
        let fm = FileManager.default
        try fm.createDirectory(at: userFolder, withIntermediateDirectories: true)

        // backup of everything that will be overwritten
        var toBackup: [URL] = []
        for src in plan.saveFiles {
            let dst = userFolder.appendingPathComponent(src.lastPathComponent)
            if fm.fileExists(atPath: dst.path) { toBackup.append(dst) }
        }
        if includeSettings {
            for src in plan.settingsFiles {
                let dst = destination(forSettings: src, userFolder: userFolder, root: root)
                if fm.fileExists(atPath: dst.path) { toBackup.append(dst) }
            }
        }
        var backupFolder: URL? = nil
        if !toBackup.isEmpty {
            let b = userFolder.appendingPathComponent("backup-\(stamp())", isDirectory: true)
            try fm.createDirectory(at: b, withIntermediateDirectories: true)
            for f in toBackup {
                let dst = b.appendingPathComponent(f.lastPathComponent)
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: f, to: dst)
            }
            backupFolder = b
        }

        var nSaves = 0, nSettings = 0
        for src in plan.saveFiles {
            let dst = userFolder.appendingPathComponent(src.lastPathComponent)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
            nSaves += 1
        }
        if includeSettings {
            for src in plan.settingsFiles {
                let dst = destination(forSettings: src, userFolder: userFolder, root: root)
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: src, to: dst)
                nSettings += 1
            }
        }
        print("[vc-saves] import: \(nSaves) saves, \(nSettings) settings files from \(plan.source.path); backup: \(backupFolder?.path ?? "none")")
        return SaveImportResult(importedSaves: nSaves, importedSettings: nSettings, backupFolder: backupFolder)
    }

    private static func destination(forSettings src: URL, userFolder: URL, root: URL) -> URL {
        src.lastPathComponent.lowercased() == "revc.ini"
            ? root.appendingPathComponent("reVC.ini")
            : userFolder.appendingPathComponent(src.lastPathComponent)
    }
}
