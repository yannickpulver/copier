import Foundation

/// A file seen by Folder Sync.
public struct SyncFile: Sendable, Hashable, Identifiable {
    /// Path relative to the walked root, `/`-separated.
    public var relativePath: String
    public var url: URL
    public var name: String
    public var size: Int64
    public var modificationDate: Date?
    /// Display only: where the differing / matched candidate lives in the destination.
    /// Never a copy target — ``FolderSync/copy(files:destinationRoot:progress:)`` always
    /// copies to ``relativePath``.
    public var destinationRelativePath: String?

    public var id: URL { url }

    public init(
        relativePath: String,
        url: URL,
        name: String,
        size: Int64,
        modificationDate: Date? = nil,
        destinationRelativePath: String? = nil
    ) {
        self.relativePath = relativePath
        self.url = url
        self.name = name
        self.size = size
        self.modificationDate = modificationDate
        self.destinationRelativePath = destinationRelativePath
    }
}

/// A source file matched to a destination file.
public struct MatchedPair: Sendable, Hashable {
    public var source: SyncFile
    public var destination: SyncFile

    public init(source: SyncFile, destination: SyncFile) {
        self.source = source
        self.destination = destination
    }
}

/// The result of comparing two folders.
public struct SyncDiff: Sendable {
    /// No file with that name anywhere in the destination.
    public var missing: [SyncFile]
    /// Same name exists, but no candidate has the same size.
    public var different: [SyncFile]
    /// Name + size match anywhere in the destination.
    public var present: [MatchedPair]

    public init(missing: [SyncFile], different: [SyncFile], present: [MatchedPair]) {
        self.missing = missing
        self.different = different
        self.present = present
    }
}

/// Folder-to-folder sync: walk both sides, diff by name and size, copy what is missing.
public enum FolderSync {
    /// Recursively collect files under `root`, skipping dot-files and stale partials.
    public static func walk(
        _ root: URL,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> [SyncFile] {
        var results: [SyncFile] = []
        try walkDirectory(root: root, directory: root, into: &results, progress: progress)
        progress?(ScanProgress(count: results.count, folder: "Done"))
        return results
    }

    private static func walkDirectory(
        root: URL,
        directory: URL,
        into results: inout [SyncFile],
        progress: (@Sendable (ScanProgress) -> Void)?
    ) throws {
        if Task.isCancelled { throw BackupError.cancelled }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: []
        )) ?? []

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entry.lastPathComponent
            if name.hasPrefix(".") || name.hasSuffix(TransferService.partialSuffix) { continue }
            guard let values = try? entry.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                try walkDirectory(root: root, directory: entry, into: &results, progress: progress)
            } else if values.isRegularFile == true {
                results.append(
                    SyncFile(
                        relativePath: Scanner.relativePath(of: entry, from: root),
                        url: entry,
                        name: name,
                        size: Int64(values.fileSize ?? 0),
                        modificationDate: values.contentModificationDate
                    )
                )
                if results.count % 100 == 0 {
                    progress?(ScanProgress(count: results.count, folder: Scanner.relativePath(of: directory, from: root)))
                }
            }
        }
    }

    /// Compare source files against destination files by file name at any depth.
    /// Present = same name and same size anywhere in the destination; modification
    /// dates are ignored. An exact relative-path match wins among equal candidates.
    public static func diff(source: [SyncFile], destination: [SyncFile]) -> SyncDiff {
        var byName: [String: [SyncFile]] = [:]
        for file in destination {
            byName[file.name, default: []].append(file)
        }

        var missing: [SyncFile] = []
        var different: [SyncFile] = []
        var present: [MatchedPair] = []

        for file in source {
            let candidates = byName[file.name] ?? []
            if candidates.isEmpty {
                missing.append(file)
                continue
            }
            let sameSize = candidates.filter { $0.size == file.size }
            if sameSize.isEmpty {
                let match = candidates.first(where: { $0.relativePath == file.relativePath }) ?? candidates[0]
                if match.relativePath != file.relativePath {
                    var annotated = file
                    annotated.destinationRelativePath = match.relativePath
                    different.append(annotated)
                } else {
                    different.append(file)
                }
                continue
            }
            let match = sameSize.first(where: { $0.relativePath == file.relativePath }) ?? sameSize[0]
            present.append(MatchedPair(source: file, destination: match))
        }

        return SyncDiff(missing: missing, different: different, present: present)
    }

    /// Copy files to `destinationRoot`, preserving the source's relative path.
    /// `destinationRelativePath` is display-only and never used as a target.
    ///
    /// A cancelled run reports what actually landed — the files it never reached are
    /// neither copied nor failed.
    @discardableResult
    public static func copy(
        files: [SyncFile],
        destinationRoot: URL,
        progress: (@Sendable (Int, Int, String) -> Void)? = nil,
        onBytes: (@Sendable (Int64) -> Void)? = nil
    ) async -> SyncCopyResult {
        var failures: [CopyFailure] = []
        var copied = 0
        var cancelled = false

        for (index, file) in files.enumerated() {
            if Task.isCancelled {
                cancelled = true
                break
            }
            let destination = destinationRoot.appendingPathComponent(file.relativePath)
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try await TransferService.copyOne(from: file.url, to: destination, onBytes: onBytes)
                copied += 1
            } catch let error as BackupError {
                if case .cancelled = error {
                    cancelled = true
                    break
                }
                failures.append(CopyFailure(file: file.relativePath, reason: error.localizedDescription))
            } catch {
                failures.append(CopyFailure(file: file.relativePath, reason: error.localizedDescription))
            }
            progress?(index + 1, files.count, file.name)
        }

        if Task.isCancelled { cancelled = true }
        return SyncCopyResult(copied: copied, failures: failures, cancelled: cancelled)
    }
}

/// What a Folder Sync copy actually did.
public struct SyncCopyResult: Sendable {
    /// Files written and verified.
    public var copied: Int
    public var failures: [CopyFailure]
    /// `true` when the run stopped early, so the remaining files were never attempted.
    public var cancelled: Bool

    public init(copied: Int, failures: [CopyFailure], cancelled: Bool) {
        self.copied = copied
        self.failures = failures
        self.cancelled = cancelled
    }
}
