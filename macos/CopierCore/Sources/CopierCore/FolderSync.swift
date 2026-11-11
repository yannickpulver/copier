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

// MARK: - Through the Synology API

extension FolderSync {
    /// The NAS path of a folder on an SMB mount, e.g. `/Volumes/yannick/Photos` mounted
    /// from `smb://yannick@cube/yannick` → `/yannick/Photos`. `nil` when the folder does
    /// not exist or is not on an SMB mount.
    public static func nasPath(of url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeURLForRemountingKey]),
              let volume = values.volume,
              let remount = values.volumeURLForRemounting
        else { return nil }
        return nasPath(localPath: url.path, volumePath: volume.path, remountURL: remount)
    }

    static func nasPath(localPath: String, volumePath: String, remountURL: URL) -> String? {
        guard remountURL.scheme?.lowercased() == "smb" else { return nil }
        let share = SyncTarget.trimTrailingSlashes(remountURL.path)
        let volume = SyncTarget.trimTrailingSlashes(volumePath)
        let local = SyncTarget.trimTrailingSlashes(localPath)
        guard !share.isEmpty, local == volume || local.hasPrefix(volume + "/") else { return nil }
        return share + local.dropFirst(volume.count)
    }

    /// `true` when `browser` sees the same entries in `nasFolder` as the file system in
    /// `localFolder` — the mount and the API point at the same NAS. The host names
    /// can't tell: the mount may say `cube` while Settings has a Tailscale IP.
    public static func sameEntries(nasFolder: String, localFolder: URL, browser: any FolderBrowser) async -> Bool {
        guard let listing = try? await browser.list(nasFolder),
              let local = try? FileManager.default.contentsOfDirectory(atPath: localFolder.path)
        else { return false }
        let remote = listing.files.map(\.name) + listing.subfolders.map { ($0.path as NSString).lastPathComponent }
        return Set(remote.filter(isWalked).map(mountName)) == Set(local.filter(isWalked))
    }

    /// Walk a NAS folder through `browser` instead of its mount. Unchanged folders come
    /// from `cacheFile`. The files keep their mount URLs under `localRoot`, so tags and
    /// copies still go through the mount.
    public static func walk(
        nasRoot: String,
        localRoot: URL,
        browser: any FolderBrowser,
        cacheFile: URL? = nil,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> [SyncFile] {
        let root = SyncTarget.trimTrailingSlashes(nasRoot)
        let index = try await FolderWalk.index(roots: [root], browser: browser, cacheFile: cacheFile, progress: progress)
        var files: [SyncFile] = []
        for (key, folders) in index.entries where isWalked(key.name) {
            for folder in folders {
                let relativeFolder = folder.path.dropFirst(root.count).drop(while: { $0 == "/" })
                let name = mountName(key.name)
                let relativePath = relativeFolder.isEmpty ? name : "\(mountName(String(relativeFolder)))/\(name)"
                files.append(
                    SyncFile(
                        relativePath: relativePath,
                        url: localRoot.appendingPathComponent(relativePath),
                        name: name,
                        size: key.size
                    )
                )
            }
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    /// A NAS name as the Mac's SMB mount shows it. The SMB client stores characters SMB
    /// does not allow (`:`, `*`, `?` …) as private-use characters (the "SFM" mapping,
    /// U+F001–U+F029), and the API returns them as stored: `Walk w: Steven` on the mount
    /// is `Walk w\u{F022} Steven` on the NAS.
    static func mountName(_ name: String) -> String {
        let mapped: [Character: Character] = [
            "\u{F020}": "\"", "\u{F021}": "*", "\u{F022}": ":", "\u{F023}": "<", "\u{F024}": ">",
            "\u{F025}": "?", "\u{F026}": "\\", "\u{F027}": "|", "\u{F028}": " ", "\u{F029}": ".",
        ]
        guard name.unicodeScalars.contains(where: { (0xF001...0xF029).contains($0.value) }) else { return name }
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if (0xF001...0xF01F).contains(scalar.value), let control = Unicode.Scalar(scalar.value - 0xF000) {
                scalars.append(control)
            } else if let replacement = mapped[Character(scalar)] {
                scalars.append(contentsOf: replacement.unicodeScalars)
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// Entries a NAS walk keeps: no dot-files, NAS system folders or stale partials.
    private static func isWalked(_ name: String) -> Bool {
        !Matcher.isIgnored(directoryName: name) && !name.hasSuffix(TransferService.partialSuffix)
    }
}
