// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Trey Boyer
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Compression
import CryptoKit
import Foundation
import zlib

// FINAL FANTASY XIV patching: applying one patch file (ZiPatch) and running a
// patch list from sign-in (SquareEnixUpdate). Written from the facts in
// docs/FFXIV_PATCHING.md, which were checked first-hand; the same rules as
// tools/zipatch-inspect.py, whose chain rebuilt ex1 byte for byte. Anything that
// document doesn't confirm stops the run instead of being guessed.

enum FFXIVPatchError: LocalizedError, Equatable {
    case notAPatch(String)
    case damaged(String)
    case unsupported(String)
    case unsafePath(String)
    case download(String)
    case hashMismatch(String)
    case notEnoughSpace(needed: Int64, available: Int64)
    /// A history patch's reset (F R) met a repository that already has files.
    case resetOfNonEmpty(String)

    var errorDescription: String? {
        switch self {
        case .notAPatch(let name): return "\(name) isn't a FINAL FANTASY XIV patch file."
        case .damaged(let detail): return "A patch file is damaged: \(detail)."
        case .unsupported(let detail): return "A patch uses something Madeira can't apply yet: \(detail)."
        case .unsafePath(let path): return "A patch names a path outside the game folder: \(path)."
        case .download(let detail): return "A patch couldn't be downloaded: \(detail)."
        case .hashMismatch(let name): return "\(name) didn't match its checksum, so it was deleted. Try again."
        case .notEnoughSpace(let needed, let available):
            let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            return "Not enough free space: the next patch needs \(format(needed)), and \(format(available)) is free."
        case .resetOfNonEmpty(let folder):
            return "A patch would start \(folder) over, but it already has files. Delete the game's \(folder) folders and try again."
        }
    }
}

// MARK: - One patch file

/// Applies one ZiPatch file to a boot or game folder, chunk by chunk in file order.
struct ZiPatchApplier {
    /// The folder the patch's paths are relative to: `boot/` for boot patches, `game/` for the rest.
    let root: URL

    static let signature = Data([0x91, 0x5A, 0x49, 0x50, 0x41, 0x54, 0x43, 0x48, 0x0D, 0x0A, 0x1A, 0x0A])
    /// No chunk seen so far is near this; a larger size means a damaged file, not a big chunk.
    static let maxChunk = 256 << 20
    private static let block = 128
    /// A file block whose compressed size is this is stored raw.
    private static let uncompressed: UInt32 = 32000

    /// Applies the patch and returns how many of each chunk and command it ran
    /// (`SQPK:A`, `F:A`, …), for logs and tests.
    @discardableResult
    func apply(_ patch: URL) throws -> [String: Int] {
        let input = try FileHandle(forReadingFrom: patch)
        defer { try? input.close() }
        let name = patch.lastPathComponent
        guard try input.read(upToCount: 12) == Self.signature else { throw FFXIVPatchError.notAPatch(name) }
        var files = OpenFiles()
        defer { files.closeAll() }
        var counts: [String: Int] = [:]
        while true {
            guard let head = try input.read(upToCount: 8), head.count == 8 else {
                throw FFXIVPatchError.damaged("\(name) ends before its EOF_ chunk")
            }
            let size = Int(head.be32(0))
            let kind = String(decoding: head[head.startIndex + 4 ..< head.startIndex + 8], as: UTF8.self)
            guard size <= Self.maxChunk else { throw FFXIVPatchError.damaged("\(name) has a \(size)-byte \(kind) chunk") }
            guard let rest = try input.read(upToCount: size + 4), rest.count == size + 4 else {
                throw FFXIVPatchError.damaged("\(name) is cut off in a \(kind) chunk")
            }
            let payload = Data(rest.prefix(size))
            let stored = rest.be32(size)
            var crc = head.dropFirst(4).withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
            crc = payload.withUnsafeBytes { crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
            guard UInt32(crc) == stored else { throw FFXIVPatchError.damaged("\(name) fails its checksum in a \(kind) chunk") }
            counts[kind, default: 0] += 1
            switch kind {
            case "EOF_": return counts
            case "FHDR", "APLY": break
            case "ADIR", "DELD":
                let length = Int(payload.be32(0))
                guard payload.count >= 4 + length else { throw FFXIVPatchError.damaged("\(name) has a short \(kind) chunk") }
                let folder = try path(payload.cString(at: 4, length: length))
                if kind == "ADIR" {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                } else if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                    try FileManager.default.removeItem(at: folder)
                }
            case "SQPK":
                guard payload.count >= 5 else { throw FFXIVPatchError.damaged("\(name) has an empty SQPK chunk") }
                let command = Character(UnicodeScalar(payload[payload.startIndex + 4]))
                let label = try sqpk(command, Data(payload.dropFirst(5)), files: &files)
                counts["SQPK:" + label, default: 0] += 1
            default:
                throw FFXIVPatchError.unsupported("a \(kind) chunk in \(name)")
            }
        }
    }

    private func sqpk(_ command: Character, _ body: Data, files: inout OpenFiles) throws -> String {
        switch command {
        case "F": return "F:" + (try fileOperation(body, files: &files))
        case "A":
            try body.need(0x17)
            let offset = UInt64(body.be32(0x0B)) * UInt64(Self.block)
            let count = Int(body.be32(0x0F)), delete = Int(body.be32(0x13))
            try body.need(0x17 + count * Self.block)
            let handle = try files.open(try datPath(body, kind: "D"), create: true)
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: body[body.startIndex + 0x17 ..< body.startIndex + 0x17 + count * Self.block])
            if delete > 0 { try handle.write(contentsOf: Data(count: delete * Self.block)) }
        case "D":
            try body.need(0x13)
            let offset = UInt64(body.be32(0x0B)) * UInt64(Self.block)
            let count = Int(body.be32(0x0F))
            guard count > 0 else { throw FFXIVPatchError.damaged("a delete of no blocks") }
            let target = try datPath(body, kind: "D")
            let handle = try files.open(target, create: false)
            let size = try handle.seekToEnd(), end = offset + UInt64(count * Self.block)
            // A delete may start exactly at the end and so append empty blocks: base
            // game D2024.06.13 does it three times (2026-10-31). One that would leave a
            // gap before it has never been seen, so it isn't applied.
            guard offset <= size else {
                throw FFXIVPatchError.damaged("a delete beyond the end of \(target.deletingLastPathComponent().lastPathComponent)/" +
                                              "\(target.lastPathComponent) (from byte \(offset) to \(end); the file has \(size))")
            }
            // The empty-block header holds count - 1 (the ex1 rebuild; xiv.dev says count).
            var empty = Data(count: count * Self.block)
            for (index, value) in [UInt32(Self.block), 0, 0, UInt32(count - 1), 0].enumerated() {
                empty.setLE32(value, at: index * 4)
            }
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: empty)
        case "H":
            try body.need(11 + 1024)
            let fileKind = Character(UnicodeScalar(body[body.startIndex])), headerKind = Character(UnicodeScalar(body[body.startIndex + 1]))
            guard "DI".contains(fileKind), "VDI".contains(headerKind) else {
                throw FFXIVPatchError.unsupported("a header update of kind \(fileKind)\(headerKind)")
            }
            let handle = try files.open(try datPath(body, kind: fileKind), create: true)
            try handle.seek(toOffset: headerKind == "V" ? 0 : 1024)
            try handle.write(contentsOf: body[body.startIndex + 11 ..< body.startIndex + 11 + 1024])
        case "X", "T", "I": break   // patch info, target info, index add/delete: nothing to apply
        default:
            // E (expand) included: not seen in a patch yet, so not applied on xiv.dev's word.
            throw FFXIVPatchError.unsupported("the SQPK \(command) command")
        }
        return String(command)
    }

    private func fileOperation(_ body: Data, files: inout OpenFiles) throws -> String {
        try body.need(0x1B)
        let operation = Character(UnicodeScalar(body[body.startIndex]))
        let offset = body.be64(3)
        let length = Int(body.be32(0x13))
        let expansion = Int(body.be16(0x17))
        try body.need(0x1B + length)
        switch operation {
        case "R":
            // Opens each history patch with an empty path. What it removes is unconfirmed,
            // so it is only accepted where it can't matter: a repository with no files yet.
            // Its .ver/.bck files don't count: a fresh install writes them first, and the
            // patch list's sizes and file counts leave them out too.
            let folder = expansion == 0 ? "ffxiv" : "ex\(expansion)"
            for part in ["sqpack", "movie"] {
                let walker = FileManager.default.enumerator(at: root.appendingPathComponent(part).appendingPathComponent(folder),
                                                            includingPropertiesForKeys: [.isRegularFileKey])
                while let url = walker?.nextObject() as? URL {
                    if !["ver", "bck"].contains(url.pathExtension),
                       (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                        throw FFXIVPatchError.resetOfNonEmpty(folder)
                    }
                }
            }
        case "A":
            let target = try path(body.cString(at: 0x1B, length: length))
            let handle: FileHandle
            if offset == 0 {
                files.close(target)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path])
                }
                handle = try files.open(target, create: false)
            } else {
                handle = try files.open(target, create: true)
            }
            try handle.seek(toOffset: offset)
            try writeBlocks(body.dropFirst(0x1B + length), to: handle)
        case "D":
            let target = try path(body.cString(at: 0x1B, length: length))
            files.close(target)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        default:
            throw FFXIVPatchError.unsupported("the file operation \(operation)")
        }
        return String(operation)
    }

    /// A file operation's blocks: a 16-byte little-endian header (16, unused, compressed
    /// size, size), then raw or deflated data, each block padded to 128 bytes.
    private func writeBlocks(_ blocks: Data, to handle: FileHandle) throws {
        var position = blocks.startIndex
        while position + 16 <= blocks.endIndex {
            let header = blocks.le32(position - blocks.startIndex)
            guard header == 16 else { break }   // the padding after the last block
            let compressed = blocks.le32(position - blocks.startIndex + 8)
            let size = Int(blocks.le32(position - blocks.startIndex + 12))
            let raw = compressed == Self.uncompressed
            let length = raw ? size : Int(compressed)
            guard position + 16 + length <= blocks.endIndex else { throw FFXIVPatchError.damaged("a file block runs past its chunk") }
            let data = blocks[position + 16 ..< position + 16 + length]
            if raw {
                try handle.write(contentsOf: data)
            } else {
                var out = Data(count: size)
                let written = out.withUnsafeMutableBytes { target in
                    data.withUnsafeBytes { source in
                        compression_decode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, size,
                                                  source.bindMemory(to: UInt8.self).baseAddress!, length, nil, COMPRESSION_ZLIB)
                    }
                }
                guard written == size else { throw FFXIVPatchError.damaged("a file block doesn't inflate to its size") }
                try handle.write(contentsOf: out)
            }
            position += (length + 0x8F) & ~0x7F
        }
    }

    /// The data or index file an SQPK command names at offset 3: main ID, sub ID (its
    /// high byte is the expansion) and file number. `sqpack/{ffxiv|exN}/{main:02x}{sub:04x}.win32.datN`
    /// or `.win32.index` / `.win32.indexN`.
    private func datPath(_ body: Data, kind: Character) throws -> URL {
        let main = body.be16(3), sub = body.be16(5), number = body.be32(7)
        let folder = sub >> 8 == 0 ? "ffxiv" : "ex\(sub >> 8)"
        let suffix = kind == "D" ? "dat\(number)" : "index" + (number == 0 ? "" : "\(number)")
        return root.appendingPathComponent("sqpack").appendingPathComponent(folder)
            .appendingPathComponent(String(format: "%02x%04x.win32.", UInt32(main), UInt32(sub)) + suffix)
    }

    /// A patch-relative path inside the root; `..`, empty parts and absolute paths are refused.
    func path(_ text: String) throws -> URL {
        let parts = text.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false)
        guard !text.isEmpty, !text.hasPrefix("/"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") }) else {
            throw FFXIVPatchError.unsafePath(text)
        }
        return parts.reduce(root) { $0.appendingPathComponent(String($1)) }
    }
}

/// The files a patch writes, kept open while it runs (a patch can hold tens of thousands
/// of commands for a handful of files).
private struct OpenFiles {
    private var handles: [String: FileHandle] = [:]

    mutating func open(_ url: URL, create: Bool) throws -> FileHandle {
        if let handle = handles[url.path] { return handle }
        if !FileManager.default.fileExists(atPath: url.path) {
            guard create else { throw FFXIVPatchError.damaged("a change to \(url.lastPathComponent), which doesn't exist") }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forUpdating: url)
        handles[url.path] = handle
        return handle
    }

    mutating func close(_ url: URL) {
        try? handles.removeValue(forKey: url.path)?.close()
    }

    mutating func closeAll() {
        for handle in handles.values { try? handle.synchronize(); try? handle.close() }
        handles = [:]
    }
}

// MARK: - A patch list

/// Runs a patch list against an installation folder (holding `boot/` and `game/`):
/// per patch, a free-space check, a resumable download, the size and SHA-1 checks,
/// applying, deleting, and the version files. A journal of applied patches lets an
/// interrupted run continue where it stopped.
struct FFXIVPatchRunner {
    /// Where one patch's time went, for the log: the network and the drive's writes
    /// while downloading, the read-back for the SHA-1 check, and applying.
    struct Timing: Equatable {
        var downloaded: Int64 = 0
        var network: Double = 0
        var downloadWrites: Double = 0
        var check: Double = 0
        var apply: Double = 0
    }

    enum Event: Equatable {
        case downloading(index: Int, count: Int, name: String, received: Int64, total: Int64)
        case checking(index: Int, count: Int, name: String)
        case applying(index: Int, count: Int, name: String)
        case applied(index: Int, count: Int, name: String, version: String?, timing: Timing)
        /// After a patch that completes a version: the repository's measured size and
        /// the list's figure for it (field 2), which should match.
        case measured(repository: String, bytes: Int64, expected: Int64)
    }

    let install: URL
    var work: URL { install.appendingPathComponent(".madeira-patches") }
    var session: URLSession = .shared
    /// The download piece size; each piece is one range request, the unit of resuming.
    var piece: Int64 = 64 << 20
    /// Kept free beyond what a patch is known to need.
    var reserve: Int64 = 512 << 20
    var progress: (Event) -> Void = { _ in }

    func run(_ patches: [SquareEnixPatch]) async throws {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let done = Set(journal())
        var sizes: [String: Int64] = [:]
        for (offset, patch) in patches.enumerated() where !done.contains(key(patch)) {
            try Task.checkCancellation()
            let index = offset + 1, name = patch.url.lastPathComponent
            if sizes[patch.repository] == nil { sizes[patch.repository] = repositoryBytes(patch.repository) }
            let file = work.appendingPathComponent("\(patch.repository)-\(name)")
            try checkSpace(for: patch, have: fileSize(file), current: sizes[patch.repository] ?? 0)
            var timing = try await download(patch, to: file, index: index, count: patches.count)
            progress(.checking(index: index, count: patches.count, name: name))
            var clock = Date()
            try verify(patch, file: file)
            timing.check = Date().timeIntervalSince(clock)
            progress(.applying(index: index, count: patches.count, name: name))
            clock = Date()
            try ZiPatchApplier(root: root(patch.repository)).apply(file)
            timing.apply = Date().timeIntervalSince(clock)
            try FileManager.default.removeItem(at: file)
            if patch.setsVersion {
                let version = versionFile(patch.repository)
                try FileManager.default.createDirectory(at: version.deletingLastPathComponent(), withIntermediateDirectories: true)
                for url in [version, version.deletingPathExtension().appendingPathExtension("bck")] {
                    try Data(patch.target.utf8).write(to: url, options: .atomic)
                }
            }
            try record(patch)
            if patch.setsVersion {
                // An integrity check, not a stop: an existing install may hold files no patch made.
                // Every part of a split patch carries the size after its last part (base game
                // D2024.10.25.0000.0000 to .0003.0000), so only a set's last part is compared.
                let measured = repositoryBytes(patch.repository)
                let next = patches.dropFirst(offset + 1).first { $0.repository == patch.repository }
                if next?.installedSize != patch.installedSize {
                    progress(.measured(repository: patch.repository, bytes: measured, expected: patch.installedSize))
                }
                sizes[patch.repository] = measured
            } else {
                sizes[patch.repository] = patch.installedSize
            }
            progress(.applied(index: index, count: patches.count, name: name, version: patch.setsVersion ? patch.target : nil, timing: timing))
        }
        // Every patch is in: the journal has done its job.
        try? FileManager.default.removeItem(at: work)
    }

    func root(_ repository: String) -> URL {
        install.appendingPathComponent(repository == "boot" ? "boot" : "game")
    }

    /// `boot/ffxivboot.ver`, `game/ffxivgame.ver` or `game/sqpack/exN/exN.ver`.
    func versionFile(_ repository: String) -> URL {
        switch repository {
        case "boot": return install.appendingPathComponent("boot/ffxivboot.ver")
        case "ffxiv": return install.appendingPathComponent("game/ffxivgame.ver")
        default: return install.appendingPathComponent("game/sqpack/\(repository)/\(repository).ver")
        }
    }

    // MARK: Downloading

    private func download(_ patch: SquareEnixPatch, to file: URL, index: Int, count: Int) async throws -> Timing {
        var timing = Timing()
        let name = patch.url.lastPathComponent
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        var have = fileSize(file)
        guard have <= patch.size else {
            try FileManager.default.removeItem(at: file)
            throw FFXIVPatchError.download("\(name) grew past its listed size; it was deleted")
        }
        let output = try FileHandle(forWritingTo: file)
        defer { try? output.close() }
        try output.seekToEnd()
        while have < patch.size {
            try Task.checkCancellation()
            let last = min(have + piece, patch.size) - 1
            var request = URLRequest(url: patch.url, timeoutInterval: 60)
            request.setValue("bytes=\(have)-\(last)", forHTTPHeaderField: "Range")
            let (data, reply): (Data, URLResponse)
            let asked = Date()
            do { (data, reply) = try await session.data(for: request) } catch is CancellationError { throw CancellationError() }
            catch { throw FFXIVPatchError.download("\(name): \((error as? URLError)?.code.rawValue ?? -1)") }
            guard let http = reply as? HTTPURLResponse, http.statusCode == 206, Int64(data.count) == last - have + 1 else {
                throw FFXIVPatchError.download("\(name): HTTP \((reply as? HTTPURLResponse)?.statusCode ?? 0) for a range")
            }
            let received = Date()
            timing.network += received.timeIntervalSince(asked)
            try output.write(contentsOf: data)
            timing.downloadWrites += Date().timeIntervalSince(received)
            timing.downloaded += Int64(data.count)
            have += Int64(data.count)
            progress(.downloading(index: index, count: count, name: name, received: have, total: patch.size))
        }
        let syncing = Date()
        try output.synchronize()
        timing.downloadWrites += Date().timeIntervalSince(syncing)
        return timing
    }

    /// The size, then the SHA-1 of every block; a mismatch deletes the file.
    private func verify(_ patch: SquareEnixPatch, file: URL) throws {
        let name = patch.url.lastPathComponent
        guard fileSize(file) == patch.size else { throw FFXIVPatchError.download("\(name) isn't its listed size") }
        guard !patch.sha1.isEmpty else { return }   // boot lists carry no hashes
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        for expected in patch.sha1 {
            var hasher = Insecure.SHA1()
            var left = patch.hashBlockSize
            while left > 0, let chunk = try input.read(upToCount: min(left, 4 << 20)), !chunk.isEmpty {
                hasher.update(data: chunk)
                left -= chunk.count
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == expected.lowercased() else {
                try? FileManager.default.removeItem(at: file)
                throw FFXIVPatchError.hashMismatch(name)
            }
        }
    }

    // MARK: Space

    /// Room for the rest of the download plus the repository's growth.
    private func checkSpace(for patch: SquareEnixPatch, have: Int64, current: Int64) throws {
        let needed = (patch.size - have) + max(0, patch.installedSize - current) + reserve
        let available = Self.availableCapacity(at: install)   // read afresh for every patch
        if available < needed { throw FFXIVPatchError.notEnoughSpace(needed: needed, available: available) }
    }

    /// Free space on the volume holding `url`, read through a fresh URL (resource
    /// values are cached on a URL). An external drive may not report the "important
    /// usage" figure, so the plain available capacity stands in for it.
    static func availableCapacity(at url: URL) -> Int64 {
        let values = try? URL(fileURLWithPath: url.path).resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }

    /// What the patch list's installed-size field counts: the repository's files,
    /// `.ver` and `.bck` aside (docs/FFXIV_PATCHING.md, "Game patch lists").
    func repositoryBytes(_ repository: String) -> Int64 {
        var folders: [URL] = []
        var loose: [URL] = []
        switch repository {
        // The boot folder may also hold files no patch makes (the official app's 390 MB
        // shader cache); they only make this larger, which the space check absorbs.
        case "boot": folders = [install.appendingPathComponent("boot")]
        default:
            let folder = repository == "ffxiv" ? "ffxiv" : repository
            folders = [install.appendingPathComponent("game/sqpack/\(folder)"), install.appendingPathComponent("game/movie/\(folder)")]
            if repository == "ffxiv" {
                loose = (try? FileManager.default.contentsOfDirectory(at: install.appendingPathComponent("game"),
                                                                      includingPropertiesForKeys: [.isRegularFileKey])) ?? []
            }
        }
        var files = loose.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        for folder in folders {
            let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
            while let url = walker?.nextObject() as? URL {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(url) }
            }
        }
        return files.filter { !["ver", "bck"].contains($0.pathExtension) }.reduce(0) { $0 + fileSize($1) }
    }

    /// From the file system each time: URL resource values are cached on the URL.
    private func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: Journal

    private var journalFile: URL { work.appendingPathComponent("applied.txt") }
    private func key(_ patch: SquareEnixPatch) -> String { "\(patch.repository)/\(patch.url.lastPathComponent)" }

    /// The patches applied so far (`repository/name`), from the journal.
    func applied() -> [String] { journal() }

    private func journal() -> [String] {
        ((try? String(contentsOf: journalFile, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func record(_ patch: SquareEnixPatch) throws {
        let line = Data((key(patch) + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: journalFile) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
        } else {
            try line.write(to: journalFile, options: .atomic)
        }
    }
}

// MARK: - Byte reading

private extension Data {
    func byte(_ offset: Int) -> UInt8 { self[startIndex + offset] }
    func be16(_ offset: Int) -> UInt16 { UInt16(byte(offset)) << 8 | UInt16(byte(offset + 1)) }
    func be32(_ offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 << 8 | UInt32(byte(offset + $1)) } }
    func be64(_ offset: Int) -> UInt64 { (0..<8).reduce(0) { $0 << 8 | UInt64(byte(offset + $1)) } }
    func le32(_ offset: Int) -> UInt32 { (0..<4).reversed().reduce(0) { $0 << 8 | UInt32(byte(offset + $1)) } }

    mutating func setLE32(_ value: UInt32, at offset: Int) {
        for index in 0..<4 { self[startIndex + offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }

    /// Throws unless the data holds at least `count` bytes.
    func need(_ count: Int) throws {
        if self.count < count { throw FFXIVPatchError.damaged("a command shorter than its fields") }
    }

    /// A null-terminated UTF-8 string in a field of `length` bytes.
    func cString(at offset: Int, length: Int) -> String {
        let field = self[startIndex + offset ..< startIndex + offset + length]
        return String(decoding: field.prefix { $0 != 0 }, as: UTF8.self)
    }
}
