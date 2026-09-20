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

    private let settings: SettingsStore
    private var work: Task<Void, Never>?

    init(settings: SettingsStore = SettingsStore()) {
        self.settings = settings
        sources = settings.syncSources.map { URL(fileURLWithPath: $0) }
        target = settings.syncTarget.map { URL(fileURLWithPath: $0) }
        appendSourceName = settings.syncAppendSourceName
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

        if sourcesSnapshot.count > 1 {
            var seenNames = Set<String>()
            for source in sourcesSnapshot {
                let name = source.lastPathComponent.lowercased()
                if seenNames.contains(name) {
                    errorMessage = "Two source folders are both called \"\(source.lastPathComponent)\". Rename one so they do not sync into the same target folder."
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
        work?.cancel()
        phase = .copying(done: 0, total: totalFiles, file: "")

        let throttle = Throttle<(Int, Int, String)>(interval: 0.1) { [weak self] value in
            guard let self, case .copying = self.phase else { return }
            self.phase = .copying(done: value.0, total: value.1, file: value.2)
        }
        let prefixFailures = allResults.count > 1

        work = Task.detached { [weak self] in
            var totalCopied = 0
            var allFailures: [CopyFailure] = []
            var tagged = 0
            var offset = 0
            var cancelledOverall = false

            for result in allResults {
                let files = result.diff.missing + result.diff.different
                let baseOffset = offset
                let outcome = await FolderSync.copy(files: files, destinationRoot: result.destination) { done, total, name in
                    throttle.send((baseOffset + done, totalFiles, name), force: done == total)
                }
                totalCopied += outcome.copied
                if prefixFailures {
                    let prefix = result.source.lastPathComponent
                    allFailures += outcome.failures.map { CopyFailure(file: "\(prefix)/\($0.file)", reason: $0.reason) }
                } else {
                    allFailures += outcome.failures
                }
                offset += files.count
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
