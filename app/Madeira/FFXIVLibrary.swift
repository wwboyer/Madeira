// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Trey Boyer
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UIKit

// FINAL FANTASY XIV in the library (docs/FFXIV_PATCHING.md, "Madeira's design"):
// its section, a fresh install, and Game details' Update. Installing makes the
// official folder, version files at 2012.01.01.0000.0000 and the boot programs
// from Square Enix's public boot patches, then the library entry; the game's
// own patches come from Play's sign-in (SquareEnixSignInSheet), whose
// "update needed" now carries the list, and run here (FFXIVPatcher.swift).

@MainActor final class FFXIVLibrary: ObservableObject {
    static let shared = FFXIVLibrary()

    /// The library's FINAL FANTASY XIV section, its install card and Game details' Update. Off with `env.MADEIRA_FFXIV = 0`.
    static var enabled: Bool { SteamSignIn.flag("MADEIRA_FFXIV", default: true) }

    /// The official install folder, inside drive_c: where an install on this device goes.
    nonisolated static let folder = "Program Files (x86)/SquareEnix/FINAL FANTASY XIV - A Realm Reborn"
    /// The version a fresh install reports for boot, game and each expansion.
    nonisolated static let baseVersion = "2012.01.01.0000.0000"
    nonisolated static let title = "FINAL FANTASY XIV Online"

    /// Where an install goes, relative to drive_c: the official folder on this device
    /// (`drive` nil), else the same SquareEnix folder on an external drive
    /// (ExternalDrives.swift, which links it in as drive_c/External/<name>).
    nonisolated static func relativeRoot(drive: String?) -> String {
        drive.map { "External/\($0)/SquareEnix/FINAL FANTASY XIV - A Realm Reborn" } ?? folder
    }

    /// The folder to read and write an install through: on an external drive its
    /// real location, after ExternalDrives checks the drive is connected, still
    /// the one registered, and writable.
    nonisolated static func nativeRoot(_ relative: String) throws -> URL {
        do {
            return try ExternalDrives.nativeURL(relative, write: true)
        } catch {
            let drive = ExternalDrives.driveName(library: relative)
            throw InstallError(drive.map { "The drive “\($0)” isn't connected or can't be written to. Connect it and try again." }
                               ?? error.localizedDescription)
        }
    }

    /// Whether an entry names one of the game's own programs (FFXIVInstall.programs),
    /// from its path alone: views call this, so it never touches the disk.
    static func isFFXIV(_ entry: LibraryEntry) -> Bool {
        guard entry.desktop != true, entry.steamAppID == nil, entry.epicAppName == nil, entry.itchGameID == nil, entry.eaOfferID == nil else { return false }
        let tail = entry.relativePath.lowercased().split(separator: "/").suffix(2).joined(separator: "/")
        return FFXIVInstall.programs.contains(tail)
    }

    struct Job: Equatable {
        enum Kind: Equatable { case install, update }
        let kind: Kind
        /// The entry being patched; nil while an install fetches its boot programs.
        var entryID: UUID?
        /// The install's folder relative to drive_c, and where it is written.
        let relativeRoot: String
        let root: URL
        var detail: String
        var done: Int64 = 0
        var total: Int64 = 0
        var paused = false
        /// Download the next patch to this device while one applies (the Update section's switch).
        var downloadAhead = false
        /// The patch being checked or applied, and the next one's download meanwhile.
        var current: Int?
        var ahead: String?
    }

    /// Where patches downloaded ahead wait on this device: Caches, which iOS may empty
    /// while Madeira isn't running (the download then starts again).
    nonisolated static var stagingFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("madeira-ffxiv-downloads", isDirectory: true)
    }
    /// What download-ahead keeps free on this device beyond the patch (FFXIVPatchRunner.stagingReserve).
    nonisolated static let stagingReserve: Int64 = 1 << 30

    @Published private(set) var job: Job?
    @Published var error: String?

    private var patches: [SquareEnixPatch] = []
    private var runTask: Task<Void, Error>?
    private var opened: ((LibraryEntry) -> Void)?
    private var retried: Set<String> = []
    private lazy var background: SteamDownloadBackground = {
        let background = SteamDownloadBackground(source: "Square Enix", suffix: "ffxiv")
        background.attach(active: { [weak self] in self?.job.map { !$0.paused } ?? false },
                          pause: { [weak self] in self?.pause() },
                          resume: { [weak self] in if self?.job?.paused == true { self?.resume() } })
        return background
    }()

    /// Whether a download or update is writing this entry's install (paused ones included).
    func isBusy(_ entryID: UUID) -> Bool { job?.entryID == entryID }

    private func log(_ line: String) { LogStore.shared.log("[ffxiv-patch] " + line) }

    // MARK: Space

    /// Free space a whole list needs: each repository's growth to its last patch's
    /// installed size (patch list field 2), the largest patch (downloaded before it
    /// is applied) and the runner's reserve. Walks the install, so not for views.
    nonisolated static func spaceNeeded(_ patches: [SquareEnixPatch], root: URL) -> Int64 {
        let runner = FFXIVPatchRunner(install: root)
        var growth: Int64 = 0
        for (repository, list) in Dictionary(grouping: patches, by: \.repository) {
            guard let last = list.last else { continue }
            growth += max(0, last.installedSize - runner.repositoryBytes(repository))
        }
        return growth + (patches.map(\.size).max() ?? 0) + runner.reserve
    }

    nonisolated static func freeSpace(at url: URL) -> Int64 {
        FFXIVPatchRunner.availableCapacity(at: url)
    }

    // MARK: Install

    /// A fresh install on this device (`drive` nil) or an external drive: the folders
    /// and version files, the boot programs from the boot patches, then a library
    /// entry, handed to `opened` (its Game details page, where Play's sign-in brings
    /// the game's patches). Every expansion is reported, as the official launcher
    /// does; whether the server leaves out ones the account lacks is unconfirmed.
    func install(drive: String?, opened: @escaping (LibraryEntry) -> Void) {
        guard job == nil else { error = "A FINAL FANTASY XIV download is already running."; return }
        error = nil
        let relative = Self.relativeRoot(drive: drive)
        let root: URL
        do { root = try Self.nativeRoot(relative) } catch { self.error = error.localizedDescription; return }
        self.opened = opened
        job = Job(kind: .install, entryID: nil, relativeRoot: relative, root: root, detail: "Preparing…")
        log("install: start on \(drive ?? "this device")")
        Task { @MainActor in
            do {
                let boot = try await Task.detached(priority: .utility) { try await Self.prepare(root: root, relative: relative) }.value
                patches = boot
                job?.total = boot.reduce(0) { $0 + $1.size }
                start()
            } catch {
                fail(error)
            }
        }
    }

    /// The folders and version files of a fresh install, then the boot check's list.
    nonisolated private static func prepare(root: URL, relative: String) async throws -> [SquareEnixPatch] {
        let files = FileManager.default
        if let walker = files.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            while let url = walker.nextObject() as? URL {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    throw InstallError("\(relative.replacingOccurrences(of: "/", with: " › ")) already has files. Add that copy with + instead, or delete it first.")
                }
            }
        }
        let versionFiles = [root.appendingPathComponent("boot/ffxivboot.ver"), root.appendingPathComponent("game/ffxivgame.ver")]
            + (1...5).map { root.appendingPathComponent("game/sqpack/ex\($0)/ex\($0).ver") }
        for file in versionFiles {
            try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(baseVersion.utf8).write(to: file, options: .atomic)
        }
        // The boot check is public; the server ignores the User-Agent (docs/SQUARE_ENIX_SIGNIN.md).
        let request = SquareEnixProtocol.bootCheckRequest(bootVersion: baseVersion, userAgent: SquareEnixLicense.windows.patchUserAgent)
        let (body, reply) = try await URLSession.shared.data(for: request)
        let status = (reply as? HTTPURLResponse)?.statusCode ?? 0
        guard case .update(let patches) = SquareEnixProtocol.bootCheck(status: status, body: body), !patches.isEmpty else {
            throw InstallError("Unable to download boot files from Square Enix's servers (HTTP \(status)). Try again later.")
        }
        return patches
    }

    struct InstallError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: Update

    /// Applies the patches sign-in reported for an entry's install, wherever it is.
    func update(entry: LibraryEntry, update: SquareEnixUpdate, downloadAhead: Bool = false) {
        guard job == nil else { error = "A FINAL FANTASY XIV download is already running."; return }
        guard !update.patches.isEmpty else { return }
        error = nil
        let relative = LibraryModel.shared.relativeRoot(entry)
        let root: URL
        do { root = try Self.nativeRoot(relative) } catch { self.error = error.localizedDescription; return }
        patches = update.patches
        job = Job(kind: .update, entryID: entry.id, relativeRoot: relative, root: root, detail: "Starting…", total: update.downloadBytes,
                  downloadAhead: downloadAhead)
        log("update: \(update.patches.count) \(update.stage.rawValue) patches, \(update.downloadBytes) bytes, to \(update.target ?? "?")" +
            (downloadAhead ? ", downloading ahead to this device" : ""))
        start()
    }

    /// Stops the run where it is; the journal and the partial download let it resume.
    func pause() {
        guard job != nil, job?.paused == false else { return }
        runTask?.cancel()
        runTask = nil
        job?.paused = true
        job?.detail = "Paused"
        log("paused")
    }

    func resume() {
        guard job?.paused == true else { return }
        job?.paused = false
        start()
    }

    /// Ends the run. Applied patches stay applied; Play's sign-in lists what is left.
    func cancel() {
        runTask?.cancel()
        runTask = nil
        if job != nil { background.downloadEnded(appID: 0, name: Self.title, outcome: .paused, queueEmpty: true) }
        job = nil
        patches = []
        opened = nil
        log("cancelled")
    }

    // MARK: Running

    private func start() {
        guard let job, !patches.isEmpty else { return }
        let patches = patches, root = job.root
        let offsets = patches.reduce(into: [Int64(0)]) { $0.append($0.last! + $1.size) }
        background.downloadStarted(appID: 0, name: Self.title)
        work = [:]
        workFloor = nil
        workReported = 0
        workChanged = Date()
        longestGap = 0
        taskLost = false
        watchForeground()
        var runner = FFXIVPatchRunner(install: root)
        runner.staging = Self.stagingFolder   // also where a partial download from an earlier run is looked for
        runner.downloadAhead = job.downloadAhead
        runner.stagingReserve = Self.stagingReserve
        self.job?.current = nil
        self.job?.ahead = nil
        runner.progress = { event in Task { @MainActor in FFXIVLibrary.shared.report(event, offsets: offsets) } }
        let configured = runner
        let task = Task.detached(priority: .utility) { try await configured.run(patches) }
        runTask = task
        Task { @MainActor in
            do {
                try await task.value
                guard runTask == task else { return }   // paused or cancelled meanwhile
                finished()
            } catch is CancellationError {
                // Paused or cancelled: pause() and cancel() keep the state.
            } catch FFXIVPatchError.resetOfNonEmpty(let folder) where runTask == task && startOver(folder, root: root) {
                start()
            } catch {
                guard runTask == task else { return }
                if (error as? URLError)?.code == .cancelled { return }
                fail(error)
            }
        }
    }

    // What iOS's progress for the background task counts (SteamDownloadBackground): each
    // patch four times its size, once each for downloading, checking, applying and size
    // checks (half for one before a repository's first patch, half for the one after
    // applying), so it keeps moving whichever of them is slow. iOS ends a continued-processing task whose
    // progress stops moving: on 2026-11-02 it did so seconds after Madeira left the
    // foreground, when download-ahead had kept every download out of the count and
    // checking and applying weren't counted at all.
    private struct Work {
        var downloaded: Int64 = 0, checked: Int64 = 0, applied: Int64 = 0, measuredBefore: Int64 = 0, measuredAfter: Int64 = 0
    }
    private var work: [Int: Work] = [:]
    /// The first patch not yet applied in this run; the ones before it count in full.
    private var workFloor: Int?
    private var workReported: Int64 = 0
    /// When the count last grew, the longest wait between two growths in the current
    /// patch (for its "applied" line), and when the last background progress line was
    /// written. A wait of `gapToLog` or more is logged with the event that ended it.
    private var workChanged = Date()
    private var longestGap: TimeInterval = 0
    private var backgroundLogged = Date.distantPast
    private static let gapToLog: TimeInterval = 10
    /// A wait of `lostTaskGap` or more that ended while Madeira wasn't in the foreground,
    /// with the run not paused: iOS would have expired a living background task (and the
    /// run would have paused), so the task is gone and Madeira was suspended instead.
    /// When Madeira is active again the task is replaced (SteamDownloadBackground.replaceLostTask).
    private var taskLost = false
    private static let lostTaskGap: TimeInterval = 30

    private func reportWork(offsets: [Int64], after event: String) {
        guard let floor = workFloor, let total = offsets.last else { return }
        let current = work.filter { $0.key >= floor }.values.reduce(Int64(0)) {
            $0 + $1.downloaded + $1.checked + $1.applied + $1.measuredBefore + $1.measuredAfter
        }
        let done = 4 * offsets[floor - 1] + current
        if done > workReported {
            let now = Date(), gap = now.timeIntervalSince(workChanged)
            longestGap = max(longestGap, gap)
            if gap >= Self.gapToLog { log(String(format: "progress gap %.1f s, ended by %@", gap, event)) }
            if gap >= Self.lostTaskGap, UIApplication.shared.applicationState != .active { taskLost = true }
            workChanged = now
            if UIApplication.shared.applicationState != .active, now.timeIntervalSince(backgroundLogged) >= 5 {
                backgroundLogged = now
                log(String(format: "background progress %.4f%% after %@", Double(done) / Double(max(1, 4 * total)) * 100, event))
            }
        }
        workReported = max(workReported, done)
        background.progress(doneBytes: UInt64(workReported), totalBytes: UInt64(max(1, 4 * total)))
    }

    /// Logs Madeira leaving and returning to the foreground while a run is going, so a
    /// background stop can be lined up with what the run was doing.
    private var watchingForeground = false
    private func watchForeground() {
        guard !watchingForeground else { return }
        watchingForeground = true
        for (name, text) in [(UIApplication.didEnterBackgroundNotification, "left the foreground"),
                             (UIApplication.didBecomeActiveNotification, "active again")] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let library = FFXIVLibrary.shared
                    guard let job = library.job else { return }
                    let since = Date().timeIntervalSince(library.workChanged)
                    library.log(String(format: "%@ (%@; %.1f s since progress last grew)", text,
                                       job.paused ? "paused" : job.detail, since))
                    guard name == UIApplication.didBecomeActiveNotification else { return }
                    if !job.paused, library.taskLost || since >= FFXIVLibrary.lostTaskGap {
                        library.log("the background task stopped without expiring while Madeira was away; asking iOS for a new one")
                        library.background.replaceLostTask()
                    }
                    library.taskLost = false
                }
            }
        }
    }

    /// A short label for logs: the kind of event, its patch number and bytes.
    private static func describe(_ event: FFXIVPatchRunner.Event) -> String {
        switch event {
        case .downloading(let index, _, _, let received, _): return "download of #\(index) at \(received)"
        case .checking(let index, _, _): return "check of #\(index) starting"
        case .checkProgress(let index, let bytes): return "check of #\(index) at \(bytes)"
        case .applying(let index, _, _): return "apply of #\(index) starting"
        case .applyProgress(let index, let bytes): return "apply of #\(index) at \(bytes)"
        case .measuring(let index, let bytes, _, let after): return "size check \(after ? "after" : "before") #\(index) at \(bytes)"
        case .applied(let index, _, _, _, _): return "#\(index) applied"
        case .measured: return "a size check"
        case .drive: return "the drive check"
        case .note: return "a note"
        }
    }

    private func report(_ event: FFXIVPatchRunner.Event, offsets: [Int64]) {
        guard job != nil, job?.paused == false else { return }
        let size = { (index: Int) in offsets[index] - offsets[index - 1] }
        defer {
            reportWork(offsets: offsets, after: Self.describe(event))
            if case .applied = event { longestGap = 0 }   // after the gap that ended with it was counted
        }
        switch event {
        case .downloading(let index, let count, let name, let received, let total):
            workFloor = workFloor ?? index
            work[index, default: Work()].downloaded = min(received, size(index))
            if let current = job?.current, index > current {
                // The next patch, downloading ahead while this one is checked or applied.
                job?.ahead = "Downloading next: \(name), \(ByteCountFormatter.string(fromByteCount: received, countStyle: .file))" +
                    " of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
                return
            }
            job?.ahead = nil
            job?.done = offsets[index - 1] + received
            job?.detail = "Downloading \(index) of \(count): \(name)"
        case .checking(let index, let count, let name):
            workFloor = workFloor ?? index
            work[index] = Work(downloaded: size(index), measuredBefore: work[index]?.measuredBefore ?? 0)
            job?.current = index
            job?.detail = "Checking \(index) of \(count): \(name)"
        case .checkProgress(let index, let bytes):
            work[index, default: Work(downloaded: size(index))].checked = min(bytes, size(index))
        case .applying(let index, let count, let name):
            workFloor = workFloor ?? index
            work[index] = Work(downloaded: size(index), checked: size(index), measuredBefore: work[index]?.measuredBefore ?? 0)
            job?.current = index
            job?.done = offsets[index]
            job?.detail = "Applying \(index) of \(count): \(name)"
        case .applyProgress(let index, let bytes):
            work[index, default: Work(downloaded: size(index), checked: size(index))].applied = min(bytes, size(index))
        case .measuring(let index, let bytes, let expected, let after):
            guard expected > 0 else { break }
            let share = Int64(Double(size(index) / 2) * min(1, Double(bytes) / Double(expected)))
            if after {
                work[index, default: Work()].measuredAfter = max(work[index]?.measuredAfter ?? 0, share)
            } else {
                work[index, default: Work()].measuredBefore = max(work[index]?.measuredBefore ?? 0, share)
            }
        case .applied(let index, _, let name, let version, let timing):
            workFloor = index + 1
            work = work.filter { $0.key > index }
            job?.done = offsets[index]
            job?.current = nil
            let patchBytes = size(index)
            let rate = { (bytes: Int64, seconds: Double) in seconds > 0 ? String(format: "%.1f MB/s", Double(bytes) / seconds / 1e6) : "-" }
            log("applied \(name)" + (version.map { ", now \($0)" } ?? "") + String(
                format: "; downloaded %lld bytes: network %.1f s (%@), drive writes %.1f s (%@); check %.1f s (%@); apply %.1f s (%@); longest progress gap %.1f s",
                timing.downloaded, timing.network, rate(timing.downloaded, timing.network),
                timing.downloadWrites, rate(timing.downloaded, timing.downloadWrites),
                timing.check, rate(patchBytes, timing.check), timing.apply, rate(patchBytes, timing.apply),
                max(longestGap, Date().timeIntervalSince(workChanged))))
        case .measured(let repository, let bytes, let expected):
            log("size check \(repository): \(bytes) bytes, the list says \(expected)" + (bytes == expected ? ", same" : ", DIFFERENT"))
        case .drive(let spins, let milliseconds, let file):
            log(String(format: "drive: median uncached random read %.2f ms in %@, so %@", milliseconds, file,
                       spins ? "a spinning disk: writes up to 256 KiB apart are joined and go straight to the drive"
                             : "flash: only touching writes are joined"))
        case .note(let text):
            log(text)
        }
    }

    /// A history patch's first part was interrupted while it applied: the files it
    /// found are its own partial work only when nothing of that repository is in
    /// the journal and its version file is missing or still the fresh-install
    /// version. Then (once) the repository's folders are cleared and the run
    /// retried; in any other case the reset is refused (docs/FFXIV_PATCHING.md).
    private func startOver(_ folder: String, root: URL) -> Bool {
        let repository = folder
        guard !retried.contains(repository) else { return false }
        let runner = FFXIVPatchRunner(install: root)
        guard !runner.applied().contains(where: { $0.hasPrefix(repository + "/") }) else { return false }
        let version = runner.versionFile(repository)
        if FileManager.default.fileExists(atPath: version.path) {
            guard (try? FFXIVInstall.version(at: version, name: version.lastPathComponent)) == Self.baseVersion else { return false }
        }
        retried.insert(repository)
        for part in ["sqpack", "movie"] {
            let top = root.appendingPathComponent("game").appendingPathComponent(part).appendingPathComponent(folder)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: top.path)) ?? [] {
                // The version files a fresh install wrote stay; everything else is the interrupted part's.
                if name.hasSuffix(".ver") || name.hasSuffix(".bck") { continue }
                try? FileManager.default.removeItem(at: top.appendingPathComponent(name))
            }
        }
        log("start over: cleared \(folder) after an interrupted first history part")
        return true
    }

    private func finished() {
        guard let job else { return }
        log("\(job.kind == .install ? "install boot" : "update"): done")
        background.downloadEnded(appID: 0, name: Self.title, outcome: .completed, queueEmpty: true)
        runTask = nil
        patches = []
        retried = []
        self.job = nil
        let model = LibraryModel.shared
        if job.kind == .install {
            let entry = model.entries.first { Self.isFFXIV($0) && model.relativeRoot($0) == job.relativeRoot }
                ?? LibraryEntry(title: Self.title, relativePath: job.relativeRoot + "/boot/ffxivboot64.exe", bits: 64)
            model.save(entry)
            Task { await model.refreshMetadata(entry.id) }
            opened?(entry)
            opened = nil
        } else if let id = job.entryID {
            Task { await model.refreshMetadata(id) }
        }
    }

    private func fail(_ failure: Error) {
        let message = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription
        log("stopped: \(message)" + (job.map { " (\($0.detail); at \($0.relativeRoot))" } ?? ""))
        if job != nil { background.downloadEnded(appID: 0, name: Self.title, outcome: .failed(message), queueEmpty: true) }
        runTask = nil
        job = nil
        patches = []
        opened = nil
        error = message
    }
}

extension LibraryModel {
    /// An FFXIV entry's install folder relative to drive_c (two folders above its program).
    func relativeRoot(_ entry: LibraryEntry) -> String {
        entry.relativePath.split(separator: "/").dropLast(2).joined(separator: "/")
    }
}

// MARK: - Library section

/// The library's FINAL FANTASY XIV section: the game's entries (drawn by the
/// library's own cells), an install card when there are none, and a running job.
struct FFXIVSection<Cells: View>: View {
    let entries: [LibraryEntry]
    let open: (LibraryEntry) -> Void
    @ViewBuilder let cells: ([LibraryEntry]) -> Cells
    @ObservedObject private var ffxiv = FFXIVLibrary.shared
    @ObservedObject private var model = LibraryModel.shared
    @AppStorage("madeiraLibraryHideFFXIV") private var hidden = false
    @State private var installing = false

    var body: some View {
        let collapsible = SteamGamesSection.collapsible
        VStack(alignment: .leading, spacing: 14) {
            LibrarySectionHeader(title: "FINAL FANTASY XIV", count: entries.count, collapsed: collapsible ? $hidden : nil) {
                if ffxiv.job != nil, ffxiv.job?.paused == false { ProgressView().accessibilityLabel("Downloading FINAL FANTASY XIV") }
            }
            if !(hidden && collapsible) {
                if let job = ffxiv.job, job.kind == .install, job.entryID == nil {
                    FFXIVJobStatus(job: job)
                } else if entries.isEmpty {
                    FFXIVInstallCard { installing = true }
                }
                if let error = ffxiv.error, ffxiv.job == nil, !installing {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(.red)
                }
                if !entries.isEmpty {
                    cells(entries)
                    if ffxiv.job == nil {
                        Button("Install a new copy…") { installing = true }.font(.subheadline)
                    }
                }
            }
        }
        .sheet(isPresented: $installing) {
            FFXIVInstallSheet { entry in
                // Let the sheet finish closing before the details page opens.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { open(entry) }
            }
        }
    }
}

/// The FINAL FANTASY XIV section's parts besides its game cards, for the zoomable grid
/// (LibraryGridPage.swift), whose own cards show the entries: an install running, the
/// install card when there are no entries, an error, and the link to install a new copy.
struct FFXIVGridExtras: View {
    let hasEntries: Bool
    let open: (LibraryEntry) -> Void
    @ObservedObject private var ffxiv = FFXIVLibrary.shared
    @State private var installing = false

    /// What the block's height follows: the grid measures it again when this changes.
    @MainActor static func signature(hasEntries: Bool) -> String {
        let library = FFXIVLibrary.shared, job = library.job
        let installing = job.map { $0.kind == .install && $0.entryID == nil } ?? false
        return "\(hasEntries) \(installing) \(job?.paused ?? false) \(job?.ahead != nil) \(library.error != nil) \(job != nil)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let job = ffxiv.job, job.kind == .install, job.entryID == nil {
                FFXIVJobStatus(job: job)
            } else if !hasEntries {
                FFXIVInstallCard { installing = true }
            }
            if let error = ffxiv.error, ffxiv.job == nil {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(.red)
            }
            if hasEntries && ffxiv.job == nil {
                Button("Install a new copy…") { installing = true }.font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $installing) {
            FFXIVInstallSheet { entry in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { open(entry) }
            }
        }
    }
}

struct FFXIVInstallCard: View {
    var install: () -> Void
    var body: some View {
        Button(action: install) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.circle").font(.system(size: 30)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Install FINAL FANTASY XIV").font(.headline)
                    Text("Download the game from Square Enix's servers. You'll need a Square Enix account to sign in.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }.padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
}

private func ffxivBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
}

struct FFXIVInstallSheet: View {
    var opened: (LibraryEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var ffxiv = FFXIVLibrary.shared
    @ObservedObject private var drives = ExternalDrives.shared
    /// The external drive to install on, by name; empty for this device.
    @State private var drive = ""
    @State private var free: Int64?

    /// The external drives connected now (ExternalDrives.swift), by name.
    private var connected: [String] { drives.folders.filter { drives.mounted[$0.id] != nil }.map(\.name) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Install on", selection: $drive) {
                        Text(UIDevice.current.userInterfaceIdiom == .pad ? "This iPad" : "This iPhone").tag("")
                        ForEach(connected, id: \.self) { Text($0).tag($0) }
                    }
                    LabeledContent("Folder", value: FFXIVLibrary.relativeRoot(drive: drive.isEmpty ? nil : drive)
                        .replacingOccurrences(of: "External/", with: "").replacingOccurrences(of: "/", with: " › "))
                    if let free { LabeledContent("Free there", value: ffxivBytes(free)) }
                } footer: {
                    Text("Madeira first downloads the game's boot programs (about 22 MB). Then sign in to your Square Enix account from the library entry by pressing Play to download the rest of the game.")
                }
                if let error = ffxiv.error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
                Section {
                    Button("Install") {
                        ffxiv.install(drive: drive.isEmpty ? nil : drive, opened: opened)
                        if ffxiv.error == nil { dismiss() }
                    }
                    .disabled(ffxiv.job != nil || !(drive.isEmpty || connected.contains(drive)))
                }
            }
            .navigationTitle("Install FINAL FANTASY XIV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: drive) {
                free = nil
                let place = drive.isEmpty ? nil : "External/" + drive
                let documents = LibraryModel.documents
                free = await Task.detached {
                    guard let place else { return FFXIVLibrary.freeSpace(at: documents) }
                    return (try? ExternalDrives.nativeURL(place)).map { FFXIVLibrary.freeSpace(at: $0) }
                }.value
            }
        }
    }
}

/// A running job's progress, with Pause/Resume and Cancel.
struct FFXIVJobStatus: View {
    let job: FFXIVLibrary.Job
    @ObservedObject private var ffxiv = FFXIVLibrary.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if job.total > 0 {
                ProgressView(value: Double(min(job.done, job.total)), total: Double(job.total))
            } else {
                ProgressView()
            }
            Text(job.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            if let ahead = job.ahead { Text(ahead).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if job.total > 0 {
                Text("\(ffxivBytes(job.done)) of \(ffxivBytes(job.total))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 16) {
                if job.paused {
                    Button("Resume") { ffxiv.resume() }
                } else {
                    Button("Pause") { ffxiv.pause() }
                }
                Button("Cancel", role: .destructive) { ffxiv.cancel() }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

/// Game details' update for a FINAL FANTASY XIV entry: what Play's sign-in found
/// pending, its sizes and the Update button, or the running job.
struct FFXIVUpdateSection: View {
    let entry: LibraryEntry
    let install: FFXIVInstall
    @Binding var update: SquareEnixUpdate?
    @ObservedObject private var ffxiv = FFXIVLibrary.shared
    @State private var space: (needed: Int64, free: Int64)?
    /// Download-ahead: off until chosen, then remembered. It writes every patch to this
    /// device's storage once more, which wears its flash.
    @AppStorage("madeiraFFXIVDownloadAhead") private var downloadAhead = false
    @State private var phoneFree: Int64?

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    var body: some View {
        if let job = ffxiv.job, ffxiv.isBusy(entry.id) {
            Section("Update") { FFXIVJobStatus(job: job) }
        } else if let update {
            Section {
                LabeledContent("Patches", value: "\(update.patches.count)")
                if let target = update.target { LabeledContent("Version", value: target) }
                LabeledContent("Download", value: ffxivBytes(update.downloadBytes))
                if let space {
                    LabeledContent("Space needed", value: ffxivBytes(space.needed))
                    LabeledContent("Free", value: ffxivBytes(space.free))
                }
                Toggle(isOn: $downloadAhead) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Download ahead to this \(device)")
                        Text(aheadNote(update)).font(.caption).foregroundStyle(.secondary)
                        if let warning = aheadWarning(update) {
                            Text(warning).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                Button("Update") {
                    ffxiv.update(entry: entry, update: update, downloadAhead: downloadAhead)
                    if ffxiv.error == nil { self.update = nil }
                }
                .disabled(ffxiv.job != nil || space == nil || (space.map { $0.free < $0.needed } ?? true))
                Button("Not Now", role: .cancel) { self.update = nil }
            } header: {
                Text("Update")
            } footer: {
                Text(footer(update))
            }
            .task(id: update) {
                let staging = FFXIVLibrary.stagingFolder.deletingLastPathComponent()
                phoneFree = await Task.detached { FFXIVLibrary.freeSpace(at: staging) }.value
                let relative = LibraryModel.shared.relativeRoot(entry), patches = update.patches
                space = await Task.detached(priority: .utility) {
                    // The real folder, so an install on a drive measures that drive.
                    guard let root = try? FFXIVLibrary.nativeRoot(relative) else { return nil }
                    return (FFXIVLibrary.spaceNeeded(patches, root: root), FFXIVLibrary.freeSpace(at: root))
                }.value
            }
        } else if let error = ffxiv.error, ffxiv.job == nil {
            Section("Update") { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
        }
    }

    private func footer(_ update: SquareEnixUpdate) -> String {
        var text = update.stage == .boot
            ? "The game's boot programs need an update. After updating, press Play to sign in."
            : "A new game update was found. After updating, press Play to sign in."
        if let space, space.free < space.needed { text += " This device does not have enough free space to install the update. Free up some space and try again." }
        return text
    }

    /// Whether the game is on an external drive (ExternalDrives.swift).
    private var onExternalDrive: Bool { ExternalDrives.driveName(library: LibraryModel.shared.relativeRoot(entry)) != nil }

    /// What download-ahead keeps on this device at most: the patch being applied, the
    /// next one, and the reserve.
    private func aheadNeed(_ update: SquareEnixUpdate) -> Int64 {
        2 * (update.patches.map(\.size).max() ?? 0) + FFXIVLibrary.stagingReserve
    }

    /// Download-ahead's case for this install: recommended for a game on an external
    /// drive, whose connection is usually its slowest part, and what it costs.
    private func aheadNote(_ update: SquareEnixUpdate) -> String {
        let need = ffxivBytes(aheadNeed(update))
        if onExternalDrive {
            return "Recommended for an external drive. The next patch file downloads to this \(device)'s internal storage while the current patch file is installed to the external drive. " +
                "This requires \(need) of free space on this \(device) and adds additional wear to the internal storage."
        }
        return "The next patch file downloads while the current patch is installed. This requires \(need) of free space on this \(device)."
    }

    /// When this device has too little room: download-ahead then mostly stands aside.
    private func aheadWarning(_ update: SquareEnixUpdate) -> String? {
        guard let phoneFree, phoneFree < aheadNeed(update) else { return nil }
        return "This \(device) has \(ffxivBytes(phoneFree)) free, so " +
            (onExternalDrive ? "larger patches will download to the drive instead." : "larger patches will download one at a time.")
    }
}
