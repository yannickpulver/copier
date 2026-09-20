import CopierCore
import Foundation
import Observation

/// State of the Folder Sync screen: pick two folders, compare, copy what is missing.
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

    private(set) var phase: Phase = .idle

    var source: URL? {
        didSet { settings.syncSource = source?.path }
    }
    var target: URL? {
        didSet { settings.syncTarget = target?.path }
    }
    var appendSourceName: Bool {
        didSet { settings.syncAppendSourceName = appendSourceName }
    }
    /// Copy Finder tags from the source files onto their counterparts in the target.
    var syncFinderTags: Bool = true

    private(set) var sourceCount: Int?
    private(set) var targetCount: Int?
    private(set) var diff: SyncDiff?
    private(set) var tagUpdates: [TagUpdate] = []
    private(set) var errorMessage: String?

    private let settings: SettingsStore
    private var work: Task<Void, Never>?

    init(settings: SettingsStore = SettingsStore()) {
        self.settings = settings
        source = settings.syncSource.map { URL(fileURLWithPath: $0) }
        target = settings.syncTarget.map { URL(fileURLWithPath: $0) }
        appendSourceName = settings.syncAppendSourceName
    }

    /// Where files actually land, after the "append source folder name" option.
    var effectiveTarget: URL? {
        guard let source, let target else { return target }
        return SyncTarget.resolve(source: source, target: target, appendSourceName: appendSourceName)
    }

    /// Files that would be copied: missing plus different.
    var filesToCopy: [SyncFile] {
        guard let diff else { return [] }
        return diff.missing + diff.different
    }

    var bytesToCopy: Int64 {
        filesToCopy.reduce(0) { $0 + $1.size }
    }

    /// Files that do not exist in the target at all.
    var addedCount: Int { diff?.missing.count ?? 0 }

    /// Files that exist in the target with a different size — these get overwritten.
    var replacedCount: Int { diff?.different.count ?? 0 }

    var canCompare: Bool {
        source != nil && target != nil && !isBusy
    }

    var isBusy: Bool {
        switch phase {
        case .comparing, .copying: return true
        default: return false
        }
    }

    /// Walk both sides and diff them.
    func compare() {
        guard let source, let destination = effectiveTarget else { return }
        work?.cancel()
        errorMessage = nil
        diff = nil
        tagUpdates = []
        phase = .comparing("Source")

        let syncTags = syncFinderTags
        work = Task.detached { [weak self] in
            do {
                let sourceFiles = try await FolderSync.walk(source)
                await MainActor.run { self?.phase = .comparing("Target") }
                let targetFiles = (try? await FolderSync.walk(destination)) ?? []
                let result = FolderSync.diff(source: sourceFiles, destination: targetFiles)

                var updates: [TagUpdate] = []
                if syncTags {
                    await MainActor.run { self?.phase = .comparing("Tags") }
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
                let counts = (sourceFiles.count, targetFiles.count)
                await MainActor.run {
                    guard let self else { return }
                    self.sourceCount = counts.0
                    self.targetCount = counts.1
                    self.diff = result
                    self.tagUpdates = updates
                    self.phase = .compared
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self?.errorMessage = error.localizedDescription
                    self?.phase = .idle
                }
            }
        }
    }

    /// Copy the missing/different files and write the pending tag updates.
    func copyMissing() {
        guard let destination = effectiveTarget else { return }
        let files = filesToCopy
        let updates = tagUpdates
        guard !files.isEmpty || !updates.isEmpty else { return }
        work?.cancel()
        phase = .copying(done: 0, total: files.count, file: "")

        let throttle = Throttle<(Int, Int, String)>(interval: 0.1) { [weak self] value in
            guard let self, case .copying = self.phase else { return }
            self.phase = .copying(done: value.0, total: value.1, file: value.2)
        }

        work = Task.detached { [weak self] in
            let outcome = await FolderSync.copy(files: files, destinationRoot: destination) { done, total, name in
                throttle.send((done, total, name), force: done == total)
            }
            var tagged = 0
            if !outcome.cancelled {
                for update in updates {
                    if Task.isCancelled { break }
                    if (try? FinderTags.write(update.tags, to: update.destinationURL)) != nil { tagged += 1 }
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.phase = .finished(
                    copied: outcome.copied,
                    tagged: tagged,
                    failures: outcome.failures,
                    cancelled: outcome.cancelled
                )
                // A cancelled run left work behind: keep the diff so it can be resumed.
                if !outcome.cancelled {
                    self.diff = nil
                    self.tagUpdates = []
                }
            }
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        // A finished-with-cancel phase is set by the copy task itself; only a cancelled
        // comparison drops straight back to idle.
        if case .comparing = phase { phase = diff == nil ? .idle : .compared }
    }
}
