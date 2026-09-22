import CopierCore
import Foundation
import Observation

/// State of the Folder Sync screen: pick one or more source folders and a target,
/// compare, and copy what is missing.
@MainActor
@Observable
final class SyncModel {
    enum Phase {
        case idle
        case comparing(String)
        case compared
        case copying(done: Int, total: Int, file: String)
        case finished(copied: Int, tagged: Int, failures: [CopyFailure], cancelled: Bool)
    }

    /// A `path`/`size` pair ready to display — already prefixed with the source folder
    /// name when there is more than one source.
    struct SyncRow: Identifiable {
        var id: String { path }
        let path: String
        let size: Int64
    }

    /// Everything compare() found for one source, resolved against its own destination.
    struct SourceResult {
        let source: URL
        let destination: URL
        var diff: SyncDiff
        var tagUpdates: [TagUpdate]
        var sourceCount: Int
        var targetCount: Int
    }

    private(set) var phase: Phase = .idle

    var sources: [URL] {
        didSet {
            settings.syncSources = sources.map(\.path)
            if oldValue != sources { resetResults() }
        }
    }
    var target: URL? {
        didSet {
            settings.syncTarget = target?.path
            if oldValue != target { resetResults() }
        }
    }
    var appendSourceName: Bool {
        didSet {
            settings.syncAppendSourceName = appendSourceName
            if oldValue != appendSourceName { resetResults() }
        }
    }
    /// Copy Finder tags from the source files onto their counterparts in the target.
    var syncFinderTags: Bool = true

    private(set) var results: [SourceResult] = []
    private(set) var errorMessage: String?

    private(set) var bytesPerSecond: Double = 0
    private(set) var secondsRemaining: TimeInterval?
    private(set) var bytesCopied: Int64 = 0
    private(set) var bytesTotal: Int64 = 0
    private var speed = SpeedEstimator()

    private let settings: SettingsStore
    private var work: Task<Void, Never>?

    init(settings: SettingsStore = SettingsStore()) {
        self.settings = settings
        sources = settings.syncSources.map { URL(fileURLWithPath: $0) }
        target = settings.syncTarget.map { URL(fileURLWithPath: $0) }
        appendSourceName = settings.syncAppendSourceName
    }

    /// The "Back up to" destinations from Settings, offered as quick picks for the target.
    /// Read live so a destination added in Settings shows up without restarting.
    var suggestedTargets: [URL] {
        settings.transferDestinations.map { URL(fileURLWithPath: $0) }
    }

    // MARK: Sources

    /// Add folders, deduping by path and keeping the existing order.
    func addSources(_ urls: [URL]) {
        var updated = sources
        var seen = Set(updated.map(\.path))
        for url in urls where !seen.contains(url.path) {
            updated.append(url)
            seen.insert(url.path)
        }
        sources = updated
    }

    func removeSource(_ url: URL) {
        sources.removeAll { $0.path == url.path }
    }

    private func resetResults() {
        work?.cancel()
        work = nil
        results = []
        errorMessage = nil
        if case .compared = phase { phase = .idle }
        if isBusy { phase = .idle }
    }

    /// Where one source's files land. With several sources the source's own folder
    /// name is always appended, so they never collide in the target.
    func destination(for source: URL) -> URL? {
        guard let target else { return nil }
        let append = sources.count > 1 || appendSourceName
        return SyncTarget.resolve(source: source, target: target, appendSourceName: append)
    }

    /// Where files actually land for the single-source case — what the Target card
    /// shows. With no source or several sources this is just the raw target.
    var effectiveTarget: URL? {
        guard let target else { return nil }
        guard sources.count == 1, let source = sources.first else { return target }
        return destination(for: source)
    }

    // MARK: Aggregates over `results`

    var sourceCount: Int? {
        results.isEmpty ? nil : results.reduce(0) { $0 + $1.sourceCount }
    }

    var targetCount: Int? {
        results.isEmpty ? nil : results.reduce(0) { $0 + $1.targetCount }
    }

    /// Files that would be copied: missing plus different, across every source.
    var filesToCopy: [SyncFile] {
        results.flatMap { $0.diff.missing + $0.diff.different }
    }

    var bytesToCopy: Int64 {
        filesToCopy.reduce(0) { $0 + $1.size }
    }

    /// Files that do not exist in the target at all.
    var addedCount: Int { results.reduce(0) { $0 + $1.diff.missing.count } }

    /// Files that exist in the target with a different size — these get overwritten.
    var replacedCount: Int { results.reduce(0) { $0 + $1.diff.different.count } }

    var tagUpdates: [TagUpdate] { results.flatMap(\.tagUpdates) }

    /// Rows ready to display, prefixed with the source folder name when there is
    /// more than one source so files from different sources aren't confused.
    var displayFiles: [SyncRow] {
        guard results.count > 1 else {
            return filesToCopy.map { SyncRow(path: $0.relativePath, size: $0.size) }
        }
        return results.flatMap { result in
            let prefix = result.source.lastPathComponent
            return (result.diff.missing + result.diff.different).map {
                SyncRow(path: "\(prefix)/\($0.relativePath)", size: $0.size)
            }
        }
    }

    var canCompare: Bool {
        !sources.isEmpty && target != nil && !isBusy
    }

    /// The target may not exist yet — it is created on copy. What must exist is a
    /// writable folder somewhere above it. Otherwise an unmounted NAS share compares as
    /// "0 files" and the copy fails on every file with a permission error from `/Volumes`.
    private func targetProblem(_ target: URL) -> String? {
        let fileManager = FileManager.default
        var existing = target.standardizedFileURL
        while !fileManager.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            if parent.path == existing.path { break }
            existing = parent
        }
        if target.path.hasPrefix("/Volumes/"), existing.path == "/Volumes" || existing.path == "/" {
            return "The volume for \"\(target.path)\" is not mounted."
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: existing.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "\"\(existing.path)\" is a file, so \"\(target.lastPathComponent)\" cannot be created inside it."
        }
        if !fileManager.isWritableFile(atPath: existing.path) {
            return "No write access to \"\(existing.path)\", so the target folder cannot be created."
        }
        return nil
    }

    var isBusy: Bool {
        switch phase {
        case .comparing, .copying: return true
        default: return false
        }
    }

    /// Comparing/copying step text: plain for one source, "Source 2 of 3" for several.
    private static func stepText(_ label: String, _ index: Int, _ total: Int) -> String {
        total > 1 ? "\(label) \(index + 1) of \(total)" : label
    }

    /// Walk every source against its own destination and diff them.
    func compare() {
        let sourcesSnapshot = sources
        guard !sourcesSnapshot.isEmpty, let target else { return }
        work?.cancel()
        errorMessage = nil
        results = []

        // A rescan can start from `.compared`; without dropping back to idle the cleared
        // results would read as "everything is already in the target".
        if let problem = targetProblem(target) {
            errorMessage = problem
            phase = .idle
            return
        }

        if sourcesSnapshot.count > 1 {
            var seenNames = Set<String>()
            for source in sourcesSnapshot {
                let name = source.lastPathComponent.lowercased()
                if seenNames.contains(name) {
                    errorMessage = "Two source folders are both called \"\(source.lastPathComponent)\". Rename one so they do not sync into the same target folder."
                    phase = .idle
                    return
                }
                seenNames.insert(name)
            }
        }

        let append = sourcesSnapshot.count > 1 || appendSourceName
        let destinations = sourcesSnapshot.map { SyncTarget.resolve(source: $0, target: target, appendSourceName: append) }
        let syncTags = syncFinderTags
        let total = sourcesSnapshot.count
        phase = .comparing(Self.stepText("Source", 0, total))

        work = Task.detached { [weak self] in
            var collected: [SourceResult] = []
            for index in sourcesSnapshot.indices {
                let source = sourcesSnapshot[index]
                let destination = destinations[index]
                do {
                    await MainActor.run { self?.phase = .comparing(Self.stepText("Source", index, total)) }
                    let sourceFiles = try await FolderSync.walk(source)
                    if Task.isCancelled { return }
                    await MainActor.run { self?.phase = .comparing(Self.stepText("Target", index, total)) }
                    let targetFiles = (try? await FolderSync.walk(destination)) ?? []
                    let result = FolderSync.diff(source: sourceFiles, destination: targetFiles)

                    var updates: [TagUpdate] = []
                    if syncTags {
                        await MainActor.run { self?.phase = .comparing(Self.stepText("Tags", index, total)) }
                        // Both trees were just walked — read the tags of those files instead
                        // of walking everything a second time.
                        let sourceTags = FinderTags.read(urls: sourceFiles.map(\.url))
                        let targetTags = FinderTags.read(urls: targetFiles.map(\.url))
                        updates = TagPlanner.updates(
                            for: result.present,
                            sourceTags: sourceTags,
                            destinationTags: targetTags
                        )
                        updates += TagPlanner.copyUpdates(
                            for: result.missing + result.different,
                            sourceTags: sourceTags,
                            destinationTags: targetTags,
                            destinationRoot: destination
                        )
                    }

                    if Task.isCancelled { return }
                    collected.append(
                        SourceResult(
                            source: source,
                            destination: destination,
                            diff: result,
                            tagUpdates: updates,
                            sourceCount: sourceFiles.count,
                            targetCount: targetFiles.count
                        )
                    )
                } catch {
                    if Task.isCancelled { return }
                    await MainActor.run {
                        self?.errorMessage = error.localizedDescription
                        self?.phase = .idle
                    }
                    return
                }
            }

            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                self.results = collected
                self.phase = .compared
            }
        }
    }

    /// Copy the missing/different files for every source and write the pending tag
    /// updates. Stops at the first source whose copy is cancelled.
    func copyMissing() {
        let allResults = results
        guard !allResults.isEmpty else { return }
        let totalFiles = allResults.reduce(0) { $0 + $1.diff.missing.count + $1.diff.different.count }
        let totalUpdates = allResults.reduce(0) { $0 + $1.tagUpdates.count }
        guard totalFiles > 0 || totalUpdates > 0 else { return }
        // The share may have gone away between compare and copy.
        if let target, let problem = targetProblem(target) {
            errorMessage = problem
            return
        }
        work?.cancel()
        errorMessage = nil
        phase = .copying(done: 0, total: totalFiles, file: "")
        bytesTotal = bytesToCopy
        speed = SpeedEstimator()
        bytesCopied = 0
        bytesPerSecond = 0
        secondsRemaining = nil

        let throttle = Throttle<CopyTick>(interval: 0.1) { [weak self] tick in
            guard let self, case .copying = self.phase else { return }
            self.phase = .copying(done: tick.filesDone, total: tick.filesTotal, file: tick.file)
            self.bytesCopied = tick.bytesDone
            self.speed.update(bytesDone: tick.bytesDone, at: ProcessInfo.processInfo.systemUptime)
            self.bytesPerSecond = self.speed.bytesPerSecond
            self.secondsRemaining = self.speed.timeRemaining(bytesDone: tick.bytesDone, bytesTotal: self.bytesTotal)
        }
        let prefixFailures = allResults.count > 1

        work = Task.detached { [weak self] in
            var totalCopied = 0
            var allFailures: [CopyFailure] = []
            var tagged = 0
            var offset = 0
            var bytesOffset: Int64 = 0
            var cancelledOverall = false

            for result in allResults {
                let files = result.diff.missing + result.diff.different
                let baseOffset = offset
                let baseBytesOffset = bytesOffset
                let tracker = CopyTickTracker(filesDone: baseOffset)
                let outcome = await FolderSync.copy(
                    files: files,
                    destinationRoot: result.destination,
                    progress: { done, total, name in
                        let snapshot = tracker.fileProgressed(filesDone: baseOffset + done, name: name)
                        throttle.send(
                            CopyTick(
                                filesDone: snapshot.filesDone,
                                filesTotal: totalFiles,
                                file: snapshot.file,
                                bytesDone: baseBytesOffset + snapshot.bytesDone
                            ),
                            force: done == total
                        )
                    },
                    onBytes: { chunk in
                        let snapshot = tracker.bytesProgressed(chunk)
                        throttle.send(
                            CopyTick(
                                filesDone: snapshot.filesDone,
                                filesTotal: totalFiles,
                                file: snapshot.file,
                                bytesDone: baseBytesOffset + snapshot.bytesDone
                            )
                        )
                    }
                )
                totalCopied += outcome.copied
                if prefixFailures {
                    let prefix = result.source.lastPathComponent
                    allFailures += outcome.failures.map { CopyFailure(file: "\(prefix)/\($0.file)", reason: $0.reason) }
                } else {
                    allFailures += outcome.failures
                }
                offset += files.count
                bytesOffset += files.reduce(0) { $0 + $1.size }
                if outcome.cancelled {
                    cancelledOverall = true
                    break
                }
            }

            if !cancelledOverall {
                writes: for result in allResults {
                    for update in result.tagUpdates {
                        if Task.isCancelled {
                            cancelledOverall = true
                            break writes
                        }
                        if (try? FinderTags.write(update.tags, to: update.destinationURL)) != nil { tagged += 1 }
                    }
                }
            }

            await MainActor.run {
                guard let self else { return }
                self.phase = .finished(
                    copied: totalCopied,
                    tagged: tagged,
                    failures: allFailures,
                    cancelled: cancelledOverall
                )
                self.bytesPerSecond = 0
                self.secondsRemaining = nil
                // A cancelled run left work behind: keep the results so it can be resumed.
                if !cancelledOverall {
                    self.results = []
                }
            }
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        // A finished-with-cancel phase is set by the copy task itself; only a cancelled
        // comparison drops straight back to idle.
        if case .comparing = phase { phase = results.isEmpty ? .idle : .compared }
    }
}

/// One throttled progress sample for a copy run: file counts (already offset across
/// sources) plus the bytes copied so far (also offset across sources).
private struct CopyTick: Sendable {
    var filesDone: Int
    var filesTotal: Int
    var file: String
    var bytesDone: Int64
}

/// Tracks the running totals for a single source's copy, shared between the per-file
/// `progress` closure and the per-chunk `onBytes` closure — both fire off the main
/// actor, on `TransferService`'s own task, so the shared state needs a lock.
private final class CopyTickTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var filesDone: Int
    private var currentFile = ""
    private var bytesDone: Int64 = 0

    /// `filesDone` starts at the count already finished by earlier sources, so the
    /// first chunks of a later source do not make the counter jump back to zero.
    init(filesDone: Int) {
        self.filesDone = filesDone
    }

    /// A file finished (or failed): advance the file count and name.
    func fileProgressed(filesDone: Int, name: String) -> (filesDone: Int, file: String, bytesDone: Int64) {
        lock.lock()
        defer { lock.unlock() }
        self.filesDone = filesDone
        self.currentFile = name
        return (self.filesDone, self.currentFile, self.bytesDone)
    }

    /// A chunk was written: advance the byte count.
    func bytesProgressed(_ chunk: Int64) -> (filesDone: Int, file: String, bytesDone: Int64) {
        lock.lock()
        defer { lock.unlock() }
        bytesDone += chunk
        return (self.filesDone, self.currentFile, self.bytesDone)
    }
}
