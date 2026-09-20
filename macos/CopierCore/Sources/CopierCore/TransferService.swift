import Foundation

// MARK: - Progress

/// What a destination folder is doing during a transfer.
public enum FolderState: String, Sendable {
    case pending
    case copying
    case done
    case failed
}

/// Per-folder progress for the "Backing up" screen.
public struct FolderProgress: Sendable, Hashable, Identifiable {
    public var url: URL
    public var filesDone: Int
    public var filesTotal: Int
    public var state: FolderState

    public var id: URL { url }

    public init(url: URL, filesDone: Int, filesTotal: Int, state: FolderState) {
        self.url = url
        self.filesDone = filesDone
        self.filesTotal = filesTotal
        self.state = state
    }
}

/// A snapshot of transfer progress. Percentages are byte-based.
public struct CopyProgress: Sendable {
    public var filesDone: Int
    public var filesTotal: Int
    public var bytesDone: Int64
    public var bytesTotal: Int64
    /// The file most recently started or finished.
    public var currentFile: String
    public var folders: [FolderProgress]

    public init(
        filesDone: Int,
        filesTotal: Int,
        bytesDone: Int64,
        bytesTotal: Int64,
        currentFile: String,
        folders: [FolderProgress]
    ) {
        self.filesDone = filesDone
        self.filesTotal = filesTotal
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.currentFile = currentFile
        self.folders = folders
    }

    /// 0…1, byte-based, falling back to the file count when sizes are unknown.
    public var fraction: Double {
        if bytesTotal > 0 { return Double(bytesDone) / Double(bytesTotal) }
        return filesTotal > 0 ? Double(filesDone) / Double(filesTotal) : 0
    }
}

/// One file that could not be copied.
public struct CopyFailure: Sendable, Hashable {
    public var file: String
    public var reason: String

    public init(file: String, reason: String) {
        self.file = file
        self.reason = reason
    }
}

/// Outcome of a transfer.
public struct TransferResult: Sendable {
    public var failures: [CopyFailure]
    public var cancelled: Bool
    /// Folders that were written to, in plan order.
    public var folders: [URL]

    public init(failures: [CopyFailure], cancelled: Bool, folders: [URL]) {
        self.failures = failures
        self.cancelled = cancelled
        self.folders = folders
    }
}

// MARK: - Free space

/// A destination volume that cannot hold what is headed there.
public struct SpaceShortfall: Sendable, Hashable {
    public var destination: URL
    public var requiredBytes: Int64
    public var freeBytes: Int64

    public init(destination: URL, requiredBytes: Int64, freeBytes: Int64) {
        self.destination = destination
        self.requiredBytes = requiredBytes
        self.freeBytes = freeBytes
    }

    /// Bytes still needed.
    public var shortfallBytes: Int64 { max(0, requiredBytes - freeBytes) }

    public var asError: BackupError {
        .insufficientSpace(destination: destination, requiredBytes: requiredBytes, freeBytes: freeBytes)
    }
}

/// Supplies volume identity and free space. Injectable so tests can simulate a full disk.
public protocol FreeSpaceProviding: Sendable {
    /// Identifier of the volume a (possibly not yet created) path lives on.
    func volumeIdentifier(for url: URL) -> String
    /// Free bytes available on that volume.
    func freeBytes(at url: URL) -> Int64
}

/// `statfs`-backed implementation.
public struct SystemFreeSpaceProvider: FreeSpaceProviding {
    public init() {}

    public func volumeIdentifier(for url: URL) -> String {
        guard let stats = fileSystemStats(for: url) else { return url.path }
        return "\(stats.f_fsid.val.0):\(stats.f_fsid.val.1)"
    }

    public func freeBytes(at url: URL) -> Int64 {
        guard let stats = fileSystemStats(for: url) else { return 0 }
        return Int64(stats.f_bavail) * Int64(stats.f_bsize)
    }

    private func fileSystemStats(for url: URL) -> statfs? {
        var buffer = statfs()
        let path = TransferService.existingAncestor(of: url).path
        guard statfs(path, &buffer) == 0 else { return nil }
        return buffer
    }
}

// MARK: - Transfer

/// The transfer API the app layer depends on. Injectable so a UI test can hold a
/// transfer open, or simulate a full disk, without moving real bytes.
public protocol FileTransferring: Sendable {
    /// Verify every destination volume has room. `nil` when everything fits.
    func checkFreeSpace(jobs: [CopyJob]) -> SpaceShortfall?
    /// Copy every job, reporting progress off the caller's actor.
    func copy(jobs: [CopyJob], progress: (@Sendable (CopyProgress) -> Void)?) async -> TransferResult
}

/// Copies planned jobs to their destination folders.
///
/// Each file is written to `<dest>.copier-partial`, verified by size, given the
/// source's modification date and only then renamed into place, so an interrupted
/// transfer never leaves a truncated file under the real name (which would poison
/// the dedupe index).
public struct TransferService: FileTransferring, Sendable {
    /// Suffix of in-progress copies.
    public static let partialSuffix = ".copier-partial"
    /// Files copied in parallel.
    public static let concurrency = 3
    /// Read/write chunk size.
    public static let chunkSize = 4 * 1024 * 1024

    private let freeSpace: any FreeSpaceProviding

    public init(freeSpace: any FreeSpaceProviding = SystemFreeSpaceProvider()) {
        self.freeSpace = freeSpace
    }

    // MARK: Preflight

    /// Verify every destination volume has room for the bytes headed there.
    /// Jobs are grouped by volume; returns the first shortfall, or `nil` when everything fits.
    ///
    /// Bytes are summed per destination folder first, so the volume is resolved once per
    /// folder instead of once per file — `volumeIdentifier(for:)` stats the file system.
    public func checkFreeSpace(jobs: [CopyJob]) -> SpaceShortfall? {
        var bytesPerFolder: [URL: Int64] = [:]
        var folderOrder: [URL] = []
        for job in jobs {
            if bytesPerFolder[job.destinationFolder] == nil { folderOrder.append(job.destinationFolder) }
            bytesPerFolder[job.destinationFolder, default: 0] += job.file.size
        }

        var required: [String: (bytes: Int64, destination: URL)] = [:]
        for folder in folderOrder {
            let identifier = freeSpace.volumeIdentifier(for: folder)
            var entry = required[identifier] ?? (0, folder)
            entry.bytes += bytesPerFolder[folder] ?? 0
            required[identifier] = entry
        }
        for (_, entry) in required {
            let free = freeSpace.freeBytes(at: entry.destination)
            if entry.bytes > free {
                return SpaceShortfall(destination: entry.destination, requiredBytes: entry.bytes, freeBytes: free)
            }
        }
        return nil
    }

    // MARK: Copying

    /// Copy every job. Folders are created and listed once up front, stale partials
    /// are deleted, and name collisions get a `_1`, `_2`, … suffix.
    ///
    /// Cancellation works through task cancellation: the in-flight partial file is
    /// removed and the result is flagged `cancelled`.
    public func copy(
        jobs: [CopyJob],
        progress: (@Sendable (CopyProgress) -> Void)? = nil
    ) async -> TransferResult {
        var failures: [CopyFailure] = []
        let bytesTotal = jobs.reduce(0) { $0 + $1.file.size }

        // Progress is reported per planned day folder, never per camera subfolder.
        var folderOrder: [URL] = []
        for job in jobs where !folderOrder.contains(job.plannedFolder) {
            folderOrder.append(job.plannedFolder)
        }

        // Prepare the folders that are actually written to: create, list names, drop stale partials.
        var takenNames: [URL: Set<String>] = [:]
        var unavailable: Set<URL> = []
        var unavailablePlanned: Set<URL> = []
        for job in jobs where takenNames[job.destinationFolder] == nil && !unavailable.contains(job.destinationFolder) {
            let folder = job.destinationFolder
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var names = Set<String>()
                let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                for name in entries {
                    if name.hasSuffix(Self.partialSuffix) {
                        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
                    } else {
                        names.insert(name)
                    }
                }
                takenNames[folder] = names
            } catch {
                unavailable.insert(folder)
                unavailablePlanned.insert(job.plannedFolder)
                failures.append(CopyFailure(file: folder.path, reason: error.localizedDescription))
            }
        }

        // Reserve destination names serially so parallel copies never collide.
        struct PreparedJob: Sendable {
            var job: CopyJob
            var destination: URL?
        }

        /// How one job ended. `cancelled` is deliberately not "done".
        enum JobOutcome: Sendable {
            case done
            case failed(CopyFailure)
            case cancelled
        }
        var prepared: [PreparedJob] = []
        prepared.reserveCapacity(jobs.count)
        var folderTotals: [URL: Int] = [:]
        for job in jobs {
            folderTotals[job.plannedFolder, default: 0] += 1
            guard var names = takenNames[job.destinationFolder] else {
                prepared.append(PreparedJob(job: job, destination: nil))
                continue
            }
            let name = Self.reserveName(&names, preferred: job.file.name)
            takenNames[job.destinationFolder] = names
            prepared.append(PreparedJob(job: job, destination: job.destinationFolder.appendingPathComponent(name)))
        }

        let tracker = ProgressTracker(
            filesTotal: jobs.count,
            bytesTotal: bytesTotal,
            folderOrder: folderOrder,
            folderTotals: folderTotals,
            unavailable: unavailablePlanned,
            onProgress: progress
        )
        tracker.emit(currentFile: "")

        var cancelled = false

        await withTaskGroup(of: (Int, JobOutcome).self) { group in
            var next = 0
            let limit = min(Self.concurrency, prepared.count)

            func submit() {
                let index = next
                let item = prepared[index]
                next += 1
                group.addTask {
                    guard let destination = item.destination else {
                        return (
                            index,
                            .failed(CopyFailure(file: item.job.file.name, reason: "destination folder unavailable"))
                        )
                    }
                    tracker.startFile(index: index, name: item.job.file.name, folder: item.job.plannedFolder)
                    do {
                        try await Self.copyOne(
                            from: item.job.file.url,
                            to: destination,
                            onBytes: { delta in
                                tracker.addBytes(delta, index: index, currentFile: item.job.file.name)
                            }
                        )
                        return (index, .done)
                    } catch let error as BackupError {
                        if case .cancelled = error { return (index, .cancelled) }
                        return (index, .failed(CopyFailure(file: item.job.file.name, reason: error.localizedDescription)))
                    } catch {
                        return (index, .failed(CopyFailure(file: item.job.file.name, reason: error.localizedDescription)))
                    }
                }
            }

            while next < limit { submit() }
            while let (index, outcome) = await group.next() {
                if Task.isCancelled { cancelled = true }
                let item = prepared[index]
                switch outcome {
                case .cancelled:
                    // A file that never finished is not progress: leave the counters
                    // (and the folder state) where they were.
                    cancelled = true
                case let .failed(failure):
                    failures.append(failure)
                    tracker.finishFile(
                        index: index,
                        name: item.job.file.name,
                        folder: item.job.plannedFolder,
                        expectedBytes: item.job.file.size,
                        failed: true
                    )
                case .done:
                    tracker.finishFile(
                        index: index,
                        name: item.job.file.name,
                        folder: item.job.plannedFolder,
                        expectedBytes: item.job.file.size,
                        failed: false
                    )
                }
                if next < prepared.count, !Task.isCancelled { submit() }
            }
        }

        if Task.isCancelled { cancelled = true }
        tracker.emitFinal()
        return TransferResult(failures: failures, cancelled: cancelled, folders: folderOrder)
    }

    /// Copy one file through a partial file: cancellable between chunks, size-verified,
    /// modification date preserved, then renamed into place.
    public static func copyOne(
        from source: URL,
        to destination: URL,
        onBytes: (@Sendable (Int64) -> Void)? = nil
    ) async throws {
        let partial = URL(fileURLWithPath: destination.path + partialSuffix)
        let fileManager = FileManager.default

        guard let input = try? FileHandle(forReadingFrom: source) else {
            throw BackupError.copyFailed(file: source.lastPathComponent, reason: "source unreadable")
        }
        defer { try? input.close() }

        fileManager.createFile(atPath: partial.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: partial) else {
            throw BackupError.copyFailed(file: source.lastPathComponent, reason: "cannot write to \(partial.path)")
        }

        func cleanUp() {
            try? output.close()
            try? fileManager.removeItem(at: partial)
        }

        do {
            while true {
                if Task.isCancelled {
                    cleanUp()
                    throw BackupError.cancelled
                }
                let chunk = try input.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { break }
                try output.write(contentsOf: chunk)
                onBytes?(Int64(chunk.count))
            }
            try output.close()

            let sourceAttributes = try fileManager.attributesOfItem(atPath: source.path)
            let partialAttributes = try fileManager.attributesOfItem(atPath: partial.path)
            let sourceSize = (sourceAttributes[.size] as? NSNumber)?.int64Value ?? -1
            let partialSize = (partialAttributes[.size] as? NSNumber)?.int64Value ?? -2
            if sourceSize != partialSize {
                try? fileManager.removeItem(at: partial)
                throw BackupError.verificationFailed(
                    file: source.lastPathComponent,
                    expectedBytes: sourceSize,
                    actualBytes: partialSize
                )
            }

            if let modified = sourceAttributes[.modificationDate] as? Date {
                try? fileManager.setAttributes([.modificationDate: modified], ofItemAtPath: partial.path)
            }
            if fileManager.fileExists(atPath: destination.path) {
                // Atomic swap: never a window where the destination name does not exist.
                _ = try fileManager.replaceItemAt(destination, withItemAt: partial)
            } else {
                try fileManager.moveItem(at: partial, to: destination)
            }
        } catch let error as BackupError {
            try? fileManager.removeItem(at: partial)
            throw error
        } catch {
            cleanUp()
            throw BackupError.copyFailed(file: source.lastPathComponent, reason: error.localizedDescription)
        }
    }

    /// Reserve a free file name in `names`, appending `_1`, `_2`, … on collision.
    public static func reserveName(_ names: inout Set<String>, preferred: String) -> String {
        if !names.contains(preferred) {
            names.insert(preferred)
            return preferred
        }
        let ext = (preferred as NSString).pathExtension
        let base = (preferred as NSString).deletingPathExtension
        var index = 1
        while true {
            let candidate = ext.isEmpty ? "\(base)_\(index)" : "\(base)_\(index).\(ext)"
            if !names.contains(candidate) {
                names.insert(candidate)
                return candidate
            }
            index += 1
        }
    }

    /// The nearest existing ancestor of a path (used to stat a folder that does not exist yet).
    public static func existingAncestor(of url: URL) -> URL {
        var current = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: current.path) {
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return current }
            current = parent
        }
        return current
    }
}

/// Shared mutable counters for a running transfer. Lock-based so byte deltas are
/// reported in order, from whichever task produced them.
///
/// Byte progress is rate-limited to ``minimumInterval`` — rebuilding the folder array
/// for every 4 MB chunk of every parallel copy is pure overhead. File starts, file
/// completions and the final snapshot always go out. The callback itself runs outside
/// the lock so a slow consumer cannot stall the copies.
private final class ProgressTracker: @unchecked Sendable {
    /// Smallest gap between two byte-progress callbacks.
    static let minimumInterval: TimeInterval = 0.1

    private let lock = NSLock()
    private let filesTotal: Int
    private let bytesTotal: Int64
    private let folderOrder: [URL]
    private var folderTotals: [URL: Int]
    private var folderDone: [URL: Int] = [:]
    private var folderState: [URL: FolderState] = [:]
    private var filesDone = 0
    private var bytesDone: Int64 = 0
    /// Keyed by job index — file names repeat across folders and even within one.
    private var bytesCountedPerJob: [Int: Int64] = [:]
    private var lastEmit: TimeInterval = 0
    private var lastFile = ""
    private let onProgress: (@Sendable (CopyProgress) -> Void)?

    init(
        filesTotal: Int,
        bytesTotal: Int64,
        folderOrder: [URL],
        folderTotals: [URL: Int],
        unavailable: Set<URL>,
        onProgress: (@Sendable (CopyProgress) -> Void)?
    ) {
        self.filesTotal = filesTotal
        self.bytesTotal = bytesTotal
        self.folderOrder = folderOrder
        self.folderTotals = folderTotals
        self.onProgress = onProgress
        for folder in folderOrder {
            folderState[folder] = unavailable.contains(folder) ? .failed : .pending
        }
    }

    func startFile(index: Int, name: String, folder: URL) {
        let snapshot: CopyProgress? = withLock {
            if folderState[folder] == .pending { folderState[folder] = .copying }
            return snapshotLocked(currentFile: name, force: true)
        }
        deliver(snapshot)
    }

    func addBytes(_ delta: Int64, index: Int, currentFile: String) {
        let snapshot: CopyProgress? = withLock {
            bytesDone += delta
            bytesCountedPerJob[index, default: 0] += delta
            return snapshotLocked(currentFile: currentFile, force: false)
        }
        deliver(snapshot)
    }

    func finishFile(index: Int, name: String, folder: URL, expectedBytes: Int64, failed: Bool) {
        let snapshot: CopyProgress? = withLock {
            filesDone += 1
            if failed {
                // Keep the byte counter aligned with the totals even when a file aborted early.
                let counted = bytesCountedPerJob[index] ?? 0
                bytesDone += max(0, expectedBytes - counted)
                folderState[folder] = .failed
            }
            folderDone[folder, default: 0] += 1
            if folderState[folder] != .failed, folderDone[folder] == folderTotals[folder] {
                folderState[folder] = .done
            }
            return snapshotLocked(currentFile: name, force: true)
        }
        deliver(snapshot)
    }

    func emit(currentFile: String) {
        let snapshot: CopyProgress? = withLock { snapshotLocked(currentFile: currentFile, force: true) }
        deliver(snapshot)
    }

    /// The last word on the transfer — always delivered.
    func emitFinal() {
        let snapshot: CopyProgress? = withLock { snapshotLocked(currentFile: lastFile, force: true) }
        deliver(snapshot)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func deliver(_ snapshot: CopyProgress?) {
        guard let snapshot, let onProgress else { return }
        onProgress(snapshot)
    }

    private func snapshotLocked(currentFile: String, force: Bool) -> CopyProgress? {
        guard onProgress != nil else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastEmit >= Self.minimumInterval else { return nil }
        lastEmit = now
        lastFile = currentFile
        let folders = folderOrder.map { url in
            FolderProgress(
                url: url,
                filesDone: folderDone[url] ?? 0,
                filesTotal: folderTotals[url] ?? 0,
                state: folderState[url] ?? .pending
            )
        }
        return CopyProgress(
            filesDone: filesDone,
            filesTotal: filesTotal,
            bytesDone: bytesDone,
            bytesTotal: bytesTotal,
            currentFile: currentFile,
            folders: folders
        )
    }
}
