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
    /// Writes up to this many bytes apart are joined by reading the gap in between
    /// (0: only writes that touch). For a spinning disk (FFXIVPatchRunner.driveSpins).
    var gapFill = 0

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
        var files = OpenFiles(gap: gapFill)
        defer { files.closeAll() }
        var counts: [String: Int] = [:]
        // Each chunk in its own autorelease pool: FileHandle's reads hand back autoreleased
        // buffers, and a run that never suspends (download-ahead) would otherwise keep a
        // whole patch's worth of them alive until it does.
        while try autoreleasepool(invoking: { () throws -> Bool in
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
                case "EOF_":
                    try files.finish()   // the buffered writes, then the files' contents to the drive
                    return false
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
            return true
        }) {}
        return counts
    }

    private func sqpk(_ command: Character, _ body: Data, files: inout OpenFiles) throws -> String {
        switch command {
        case "F": return "F:" + (try fileOperation(body, files: &files))
        case "A":
            try body.need(0x17)
            let offset = UInt64(body.be32(0x0B)) * UInt64(Self.block)
            let count = Int(body.be32(0x0F)), delete = Int(body.be32(0x13))
            try body.need(0x17 + count * Self.block)
            let target = try datPath(body, kind: "D")
            try files.write(body[body.startIndex + 0x17 ..< body.startIndex + 0x17 + count * Self.block], to: target, at: offset, create: true)
            if delete > 0 {
                try files.write(Data(count: delete * Self.block), to: target, at: offset + UInt64(count * Self.block), create: true)
            }
        case "D":
            try body.need(0x13)
            let offset = UInt64(body.be32(0x0B)) * UInt64(Self.block)
            let count = Int(body.be32(0x0F))
            guard count > 0 else { throw FFXIVPatchError.damaged("a delete of no blocks") }
            let target = try datPath(body, kind: "D")
            let size = try files.size(of: target), end = offset + UInt64(count * Self.block)
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
            try files.write(empty, to: target, at: offset, create: false)
        case "H":
            try body.need(11 + 1024)
            let fileKind = Character(UnicodeScalar(body[body.startIndex])), headerKind = Character(UnicodeScalar(body[body.startIndex + 1]))
            guard "DI".contains(fileKind), "VDI".contains(headerKind) else {
                throw FFXIVPatchError.unsupported("a header update of kind \(fileKind)\(headerKind)")
            }
            try files.write(body[body.startIndex + 11 ..< body.startIndex + 11 + 1024], to: try datPath(body, kind: fileKind),
                            at: headerKind == "V" ? 0 : 1024, create: true)
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
            if offset == 0 {
                try files.close(target)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path])
                }
            }
            try writeBlocks(body.dropFirst(0x1B + length), to: target, at: offset, files: &files)
        case "D":
            let target = try path(body.cString(at: 0x1B, length: length))
            try files.close(target)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        default:
            throw FFXIVPatchError.unsupported("the file operation \(operation)")
        }
        return String(operation)
    }

    /// A file operation's blocks: a 16-byte little-endian header (16, unused, compressed
    /// size, size), then raw or deflated data, each block padded to 128 bytes.
    private func writeBlocks(_ blocks: Data, to target: URL, at start: UInt64, files: inout OpenFiles) throws {
        var position = blocks.startIndex
        var offset = start
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
                try files.write(data, to: target, at: offset, create: true)
                offset += UInt64(size)
            } else {
                var out = Data(count: size)
                let written = out.withUnsafeMutableBytes { target in
                    data.withUnsafeBytes { source in
                        compression_decode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, size,
                                                  source.bindMemory(to: UInt8.self).baseAddress!, length, nil, COMPRESSION_ZLIB)
                    }
                }
                guard written == size else { throw FFXIVPatchError.damaged("a file block doesn't inflate to its size") }
                try files.write(out, to: target, at: offset, create: true)
                offset += UInt64(size)
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
/// of commands for a handful of files), and one buffered write: a write that continues
/// exactly where the buffered one ends joins it, anything else writes it out first. The
/// bytes and their order are unchanged; an external drive just gets ~6x fewer, larger
/// writes (base game D2025.09.09: 13,693 writes become 2,115).
private struct OpenFiles {
    private var handles: [String: FileHandle] = [:]
    private var pending: (path: String, url: URL, offset: UInt64, data: Data)?
    static let maxPending = 8 << 20
    /// On a spinning disk: a write starting at most this far past the buffer's end joins
    /// it, with the bytes in between read from the file and written back unchanged. They
    /// are current, because every earlier write to them has been written out already.
    let gap: Int

    init(gap: Int = 0) { self.gap = gap }

    mutating func write<Bytes: DataProtocol>(_ bytes: Bytes, to url: URL, at offset: UInt64, create: Bool) throws {
        // Only scalars are read here: binding `pending` itself would add a second
        // reference to its buffer and make every append copy it.
        if pending?.path == url.path, let start = pending?.offset, let count = pending?.data.count,
           start + UInt64(count) == offset, count + bytes.count <= Self.maxPending {
            pending?.data.append(contentsOf: bytes)   // in place: `pending` holds the only reference
            return
        }
        if gap > 0, pending?.path == url.path, let start = pending?.offset, let count = pending?.data.count,
           offset > start + UInt64(count), offset - (start + UInt64(count)) <= UInt64(gap),
           Int(offset - start) + bytes.count <= Self.maxPending {
            let end = start + UInt64(count), length = Int(offset - end)
            let handle = try open(url, create: false)
            try handle.seek(toOffset: end)
            var between = try handle.read(upToCount: length) ?? Data()
            if between.count < length { between.append(Data(count: length - between.count)) }   // past the end: a hole reads as zeros
            pending?.data.append(between)
            pending?.data.append(contentsOf: bytes)
            return
        }
        try flush()
        _ = try open(url, create: create)
        var data = Data(capacity: max(bytes.count, 1 << 20))
        data.append(contentsOf: bytes)
        pending = (url.path, url, offset, data)
    }

    /// Writes the buffered bytes out.
    mutating func flush() throws {
        guard let current = pending else { return }
        pending = nil
        let handle = try open(current.url, create: false)
        try handle.seek(toOffset: current.offset)
        try handle.write(contentsOf: current.data)
    }

    /// A file's size with everything written so far.
    mutating func size(of url: URL) throws -> UInt64 {
        if pending?.path == url.path { try flush() }
        return try open(url, create: false).seekToEnd()
    }

    /// The end of a patch: every buffered write out, and the files' contents on the drive.
    mutating func finish() throws {
        try flush()
        for handle in handles.values { try handle.synchronize() }
    }

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

    mutating func close(_ url: URL) throws {
        if pending?.path == url.path { try flush() }
        try? handles.removeValue(forKey: url.path)?.close()
    }

    /// After a patch ends, applied or not: closes everything. A patch that stopped part
    /// way is applied again from its start, so its unwritten buffer doesn't matter.
    mutating func closeAll() {
        pending = nil
        for handle in handles.values { try? handle.close() }
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
        /// The drive was timed: the median of uncached random 4 KiB reads in `file`.
        case drive(spins: Bool, milliseconds: Double, file: String)
        /// Anything else worth a log line.
        case note(String)
    }

    let install: URL
    var work: URL { install.appendingPathComponent(".madeira-patches") }
    var session: URLSession = .shared
    /// The download piece size; each piece is one range request, the unit of resuming.
    var piece: Int64 = 64 << 20
    /// Kept free beyond what a patch is known to need.
    var reserve: Int64 = 512 << 20
    var progress: (Event) -> Void = { _ in }

    /// Where downloads go with `downloadAhead` (this device's own storage), and where a
    /// partial download left there is looked for in any case.
    var staging: URL?
    /// Download each patch to `staging` and the next one while this one applies, so the
    /// network doesn't wait for a slow drive. Only while `staging`'s volume keeps
    /// `stagingReserve` free beyond the patch; otherwise it downloads to `work` in turn.
    var downloadAhead = false
    var stagingReserve: Int64 = 1 << 30
    /// The gap writes are joined across: nil decides by timing the drive (driveSpins),
    /// a number forces it (0: never; for tests).
    var gapFill: Int?
    static let spinningGap = 256 << 10
    /// A median random read slower than this means a spinning disk (flash: well under 1 ms).
    static let spinningMilliseconds = 2.5

    func run(_ patches: [SquareEnixPatch]) async throws {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        if let staging { try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true) }
        let done = Set(journal())
        let todo = patches.enumerated().filter { !done.contains(key($0.element)) }
        var sizes: [String: Int64] = [:]
        var gap = gapFill
        var ahead: (offset: Int, file: URL, task: Task<Timing, Error>)?
        defer { ahead?.task.cancel() }
        for (step, (offset, patch)) in todo.enumerated() {
            try Task.checkCancellation()
            let index = offset + 1, name = patch.url.lastPathComponent
            if sizes[patch.repository] == nil { sizes[patch.repository] = repositoryBytes(patch.repository) }
            var file: URL
            var timing: Timing
            if let early = ahead, early.offset == offset {
                ahead = nil
                file = early.file
                timing = try await withTaskCancellationHandler { try await early.task.value } onCancel: { early.task.cancel() }
            } else {
                file = place(for: patch)
                try checkDownloadRoom(for: patch, at: file, growth: inWork(file)
                                      ? max(0, patch.installedSize - (sizes[patch.repository] ?? 0)) : 0)
                timing = try await download(patch, to: file, index: index, count: patches.count)
            }
            // The next patch downloads while this one is checked and applied.
            if downloadAhead, staging != nil, step + 1 < todo.count {
                let (nextOffset, next) = todo[step + 1]
                let nextFile = place(for: next)
                if inWork(nextFile) {
                    progress(.note("download-ahead: no room on this device for \(next.url.lastPathComponent), so it downloads in turn"))
                } else {
                    let runner = self
                    let task = Task { try await runner.download(next, to: nextFile, index: nextOffset + 1, count: patches.count) }
                    ahead = (nextOffset, nextFile, task)
                }
            }
            progress(.checking(index: index, count: patches.count, name: name))
            var clock = Date()
            do {
                try verify(patch, file: file)
            } catch FFXIVPatchError.hashMismatch {
                // verify deleted it. Once, download it again from the start: a download cut
                // off by the app being stopped has failed this way when resumed (2026-10-31).
                progress(.note("\(name) didn't match its checksum; downloading it again"))
                file = place(for: patch)
                try checkDownloadRoom(for: patch, at: file, growth: inWork(file)
                                      ? max(0, patch.installedSize - (sizes[patch.repository] ?? 0)) : 0)
                let again = try await download(patch, to: file, index: index, count: patches.count)
                timing.downloaded += again.downloaded
                timing.network += again.network
                timing.downloadWrites += again.downloadWrites
                progress(.checking(index: index, count: patches.count, name: name))
                clock = Date()
                try verify(patch, file: file)
            }
            timing.check = Date().timeIntervalSince(clock)
            try checkGrowth(for: patch, current: sizes[patch.repository] ?? 0)
            if gap == nil, let probe = Self.timeRandomReads(under: install.appendingPathComponent("game/sqpack")) {
                let spins = probe.milliseconds > Self.spinningMilliseconds
                progress(.drive(spins: spins, milliseconds: probe.milliseconds, file: probe.file))
                gap = spins ? Self.spinningGap : 0
            }
            progress(.applying(index: index, count: patches.count, name: name))
            clock = Date()
            try ZiPatchApplier(root: root(patch.repository), gapFill: gap ?? 0).apply(file)
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
        // Every patch is in: the journal has done its job, and nothing is left to download.
        try? FileManager.default.removeItem(at: work)
        if let staging { try? FileManager.default.removeItem(at: staging) }
    }

    /// Whether a download is in the install's work folder (not this device's staging folder).
    private func inWork(_ file: URL) -> Bool {
        file.deletingLastPathComponent().standardizedFileURL.path == work.standardizedFileURL.path
    }

    /// Where a patch downloads: a partial download already there, wherever it is; with
    /// downloadAhead, this device's staging folder while it has room; else the work folder.
    private func place(for patch: SquareEnixPatch) -> URL {
        let name = "\(patch.repository)-\(patch.url.lastPathComponent)"
        let local = staging?.appendingPathComponent(name), drive = work.appendingPathComponent(name)
        if let local, FileManager.default.fileExists(atPath: local.path) { return local }
        if FileManager.default.fileExists(atPath: drive.path) { return drive }
        if downloadAhead, let local, let staging,
           Self.availableCapacity(at: staging) >= patch.size + stagingReserve { return local }
        return drive
    }

    // MARK: Timing the drive

    /// The median of 32 uncached random 4 KiB reads in the largest file (at least 256 MiB)
    /// under `folder`, or nil when there is none yet. iOS can't say whether a drive spins,
    /// but a head that has to move takes 5 to 15 ms per read and flash well under 1.
    static func timeRandomReads(under folder: URL) -> (milliseconds: Double, file: String)? {
        var largest: (url: URL, size: Int64)?
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else { continue }
            if size.int64Value > (largest?.size ?? (256 << 20) - 1) { largest = (url, size.int64Value) }
        }
        guard let largest else { return nil }
        let fd = open(largest.url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var buffer = [UInt8](repeating: 0, count: 4096)
        let pages = largest.size / 4096
        var times: [Double] = []
        for attempt in 0...32 {
            let page = Int64.random(in: 0..<pages)
            let started = DispatchTime.now().uptimeNanoseconds
            guard pread(fd, &buffer, 4096, off_t(page * 4096)) == 4096 else { return nil }
            // The first read may wake a sleeping disk: it isn't counted.
            if attempt > 0 { times.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6) }
        }
        times.sort()
        return (times[times.count / 2], largest.url.lastPathComponent)
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
            try autoreleasepool { try output.write(contentsOf: data) }
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
        guard fileSize(file) == patch.size else {
            try? FileManager.default.removeItem(at: file)   // wrong content either way: downloaded again
            throw FFXIVPatchError.hashMismatch(name)
        }
        guard !patch.sha1.isEmpty else { return }   // boot lists carry no hashes
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        for expected in patch.sha1 {
            var hasher = Insecure.SHA1()
            var left = patch.hashBlockSize
            while left > 0, let read = try autoreleasepool(invoking: { () throws -> Int? in
                guard let chunk = try input.read(upToCount: min(left, 4 << 20)), !chunk.isEmpty else { return nil }
                hasher.update(data: chunk)
                return chunk.count
            }) {
                left -= read
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == expected.lowercased() else {
                try? FileManager.default.removeItem(at: file)
                throw FFXIVPatchError.hashMismatch(name)
            }
        }
    }

    // MARK: Space

    /// Room on the download's volume for the rest of it, plus `growth` when that is also
    /// the install's volume (downloading to the work folder).
    private func checkDownloadRoom(for patch: SquareEnixPatch, at file: URL, growth: Int64) throws {
        let needed = (patch.size - fileSize(file)) + growth + reserve
        let available = Self.availableCapacity(at: file.deletingLastPathComponent())   // read afresh every time
        if available < needed { throw FFXIVPatchError.notEnoughSpace(needed: needed, available: available) }
    }

    /// Room on the install's volume for the repository's growth, before applying.
    private func checkGrowth(for patch: SquareEnixPatch, current: Int64) throws {
        let needed = max(0, patch.installedSize - current) + reserve
        let available = Self.availableCapacity(at: install)
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
