//
//  ZipReader.swift
//  AvpViceCity
//
//  Minimal, dependency-free ZIP reader for the game-file installer: central directory
//  (incl. ZIP64), stored and deflate entries, streaming extraction with CRC-32 check.
//  Deflate is decoded with Apple's Compression framework (COMPRESSION_ZLIB = raw deflate,
//  exactly what ZIP entries use).
//
//  Covers the cases the user listed: archives from Windows Explorer (names in the OEM/ANSI
//  code page, no UTF-8 flag), from the macOS Finder (UTF-8 flag, __MACOSX/ and ._ resource
//  forks -- skipped by the caller), names with spaces and umlauts, and hostile paths
//  ("../", absolute) -- `ZipEntry.safeRelativePath` rejects those.
//

import Foundation
import Compression
import zlib

struct ZipEntry {
    let name: String            // as stored (decoded), may contain "/" separators
    let isDirectory: Bool
    let method: UInt16          // 0 = stored, 8 = deflate
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let crc32: UInt32
    let localHeaderOffset: UInt64

    /// Path components after normalisation; nil if the path tries to escape (.., absolute,
    /// drive letter) or is empty.
    var safeComponents: [String]? {
        var n = name.replacingOccurrences(of: "\\", with: "/")
        if n.hasPrefix("/") { return nil }
        if n.count >= 2, n[n.index(n.startIndex, offsetBy: 1)] == ":" { return nil }   // C:
        let parts = n.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.isEmpty { return nil }
        for p in parts where p == ".." || p == "." { return nil }
        n = parts.joined(separator: "/")
        return parts
    }
}

enum ZipError: LocalizedError {
    case notAZip
    case corrupt(String)
    case unsupportedMethod(UInt16, String)
    case crcMismatch(String)
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .notAZip:                     return "The file is not a ZIP archive."
        case .corrupt(let w):              return "ZIP archive is damaged (\(w))."
        case .unsupportedMethod(let m, let n): return "Unsupported compression method \(m) for \(n)."
        case .crcMismatch(let n):          return "Checksum mismatch while extracting \(n)."
        case .unsafePath(let n):           return "Refused unsafe path in archive: \(n)."
        }
    }
}

/// One reader is used from one task at a time (the installer extracts sequentially), so the
/// shared FileHandle is safe; hence the unchecked Sendable for the detached copy tasks.
nonisolated final class ZipReader: @unchecked Sendable {
    private let handle: FileHandle
    private let fileSize: UInt64
    private(set) var entries: [ZipEntry] = []

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        fileSize = try handle.seekToEnd()
        try readCentralDirectory()
    }

    deinit { try? handle.close() }

    // MARK: central directory

    private func read(at offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        guard let d = try handle.read(upToCount: count), d.count == count else { throw ZipError.corrupt("short read") }
        return d
    }

    private func readCentralDirectory() throws {
        // EOCD: scan the last 64 KB + 22 for 0x06054b50
        let tail = Int(min(fileSize, UInt64(65_536 + 22)))
        guard tail >= 22 else { throw ZipError.notAZip }
        let tailData = try read(at: fileSize - UInt64(tail), count: tail)
        var eocdPos = -1
        var i = tail - 22
        while i >= 0 {
            if tailData[i] == 0x50, tailData[i+1] == 0x4b, tailData[i+2] == 0x05, tailData[i+3] == 0x06 { eocdPos = i; break }
            i -= 1
        }
        guard eocdPos >= 0 else { throw ZipError.notAZip }
        var count = UInt64(tailData.u16(eocdPos + 10))
        var cdSize = UInt64(tailData.u32(eocdPos + 12))
        var cdOffset = UInt64(tailData.u32(eocdPos + 16))

        // ZIP64: locator sits 20 bytes before the EOCD
        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            let locPos = eocdPos - 20
            if locPos >= 0, tailData.u32(locPos) == 0x0706_4b50 {
                let z64Off = tailData.u64(locPos + 8)
                let z64 = try read(at: z64Off, count: 56)
                guard z64.u32(0) == 0x0606_4b50 else { throw ZipError.corrupt("zip64 eocd") }
                count = z64.u64(32)
                cdSize = z64.u64(40)
                cdOffset = z64.u64(48)
            }
        }
        guard cdOffset + cdSize <= fileSize else { throw ZipError.corrupt("central directory offset") }
        let cd = try read(at: cdOffset, count: Int(cdSize))
        var p = 0
        var list: [ZipEntry] = []
        list.reserveCapacity(Int(min(count, 100_000)))
        while p + 46 <= cd.count, cd.u32(p) == 0x0201_4b50 {
            let flags = cd.u16(p + 8)
            let method = cd.u16(p + 10)
            let crc = cd.u32(p + 16)
            var csize = UInt64(cd.u32(p + 20))
            var usize = UInt64(cd.u32(p + 24))
            let nameLen = Int(cd.u16(p + 28))
            let extraLen = Int(cd.u16(p + 30))
            let commentLen = Int(cd.u16(p + 32))
            var lho = UInt64(cd.u32(p + 42))
            let nameData = cd.subdata(in: (p + 46)..<(p + 46 + nameLen))
            let extra = cd.subdata(in: (p + 46 + nameLen)..<(p + 46 + nameLen + extraLen))
            // ZIP64 extra field 0x0001: the 0xFFFFFFFF fields follow in order usize, csize, lho
            var e = 0
            while e + 4 <= extra.count {
                let id = extra.u16(e), len = Int(extra.u16(e + 2))
                if id == 0x0001 {
                    var q = e + 4
                    if usize == 0xFFFF_FFFF, q + 8 <= e + 4 + len { usize = extra.u64(q); q += 8 }
                    if csize == 0xFFFF_FFFF, q + 8 <= e + 4 + len { csize = extra.u64(q); q += 8 }
                    if lho == 0xFFFF_FFFF, q + 8 <= e + 4 + len { lho = extra.u64(q); q += 8 }
                }
                e += 4 + len
            }
            let name = ZipReader.decodeName(nameData, utf8Flag: flags & 0x0800 != 0)
            list.append(ZipEntry(name: name, isDirectory: name.hasSuffix("/"), method: method,
                                 compressedSize: csize, uncompressedSize: usize, crc32: crc, localHeaderOffset: lho))
            p += 46 + nameLen + extraLen + commentLen
        }
        entries = list
    }

    /// UTF-8 when flagged or valid; otherwise the Windows OEM code page (850 on German
    /// systems, 437 on US) is the usual source -- try CP850 via the matching Foundation
    /// encoding, then Latin-1 as the last resort. Only used for matching + relative paths.
    static func decodeName(_ d: Data, utf8Flag: Bool) -> String {
        if let s = String(data: d, encoding: .utf8) { return s }
        let cp850 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatin1.rawValue)))
        if let s = String(data: d, encoding: cp850) { return s }
        return String(data: d, encoding: .isoLatin1) ?? d.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: extraction

    /// Extracts one entry to `dest` (parent must exist), verifying CRC-32. `progress` gets the
    /// uncompressed bytes written so far for this entry.
    func extract(_ entry: ZipEntry, to dest: URL, progress: ((UInt64) -> Void)? = nil) throws {
        guard entry.method == 0 || entry.method == 8 else { throw ZipError.unsupportedMethod(entry.method, entry.name) }
        // local header: name/extra lengths there may differ from the central directory
        let lh = try read(at: entry.localHeaderOffset, count: 30)
        guard lh.u32(0) == 0x0403_4b50 else { throw ZipError.corrupt("local header of \(entry.name)") }
        let dataStart = entry.localHeaderOffset + 30 + UInt64(lh.u16(26)) + UInt64(lh.u16(28))
        try handle.seek(toOffset: dataStart)

        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let out = try FileHandle(forWritingTo: dest)
        defer { try? out.close() }

        var crc: uLong = 0
        var written: UInt64 = 0
        var remaining = entry.compressedSize
        let chunk = 1 << 20

        if entry.method == 0 {
            while remaining > 0 {
                let n = Int(min(UInt64(chunk), remaining))
                guard let d = try handle.read(upToCount: n), !d.isEmpty else { throw ZipError.corrupt("truncated \(entry.name)") }
                d.withUnsafeBytes { crc = crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt(d.count)) }
                try out.write(contentsOf: d)
                written += UInt64(d.count); remaining -= UInt64(d.count)
                progress?(written)
            }
        } else {
            var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                throw ZipError.corrupt("inflate init")
            }
            defer { compression_stream_destroy(&stream) }
            let outBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
            defer { outBuf.deallocate() }
            var input = Data()
            var inputDone = false
            var finished = false
            while !finished {
                if input.isEmpty && !inputDone {
                    let n = Int(min(UInt64(chunk), remaining))
                    if n == 0 { inputDone = true }
                    else {
                        guard let d = try handle.read(upToCount: n), !d.isEmpty else { throw ZipError.corrupt("truncated \(entry.name)") }
                        input = d; remaining -= UInt64(d.count)
                        if remaining == 0 { inputDone = true }
                    }
                }
                let status: compression_status = try input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> compression_status in
                    stream.src_ptr = src.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer<UInt8>(bitPattern: 1)!
                    stream.src_size = src.count
                    stream.dst_ptr = outBuf
                    stream.dst_size = chunk
                    let flags = inputDone ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                    let st = compression_stream_process(&stream, flags)
                    let produced = chunk - stream.dst_size
                    if produced > 0 {
                        crc = crc32(crc, outBuf, uInt(produced))
                        try out.write(contentsOf: Data(bytesNoCopy: outBuf, count: produced, deallocator: .none))
                        written += UInt64(produced)
                        progress?(written)
                    }
                    let consumed = src.count - stream.src_size
                    input = consumed >= input.count ? Data() : input.subdata(in: consumed..<input.count)
                    return st
                }
                switch status {
                case COMPRESSION_STATUS_END: finished = true
                case COMPRESSION_STATUS_OK: continue
                default: throw ZipError.corrupt("inflate failed in \(entry.name)")
                }
            }
        }
        guard UInt32(truncatingIfNeeded: crc) == entry.crc32 else { throw ZipError.crcMismatch(entry.name) }
        guard written == entry.uncompressedSize else { throw ZipError.corrupt("size mismatch in \(entry.name)") }
    }
}

nonisolated private extension Data {
    func u16(_ o: Int) -> UInt16 { UInt16(self[startIndex + o]) | UInt16(self[startIndex + o + 1]) << 8 }
    func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 }
    func u64(_ o: Int) -> UInt64 { UInt64(u32(o)) | UInt64(u32(o + 4)) << 32 }
}
