import Foundation

/// Progress of a directory walk: how many files so far and which folder is being read.
public struct ScanProgress: Sendable, Hashable {
    public var count: Int
    public var folder: String

    public init(count: Int, folder: String) {
        self.count = count
        self.folder = folder
    }
}

/// Recursive walk of a card.
public enum Scanner {
    /// Folders macOS creates on volumes that never hold media.
    public static let hiddenDirectories: Set<String> = [".Trashes", ".Spotlight-V100", ".fseventsd", "__MACOSX"]

    /// Walk `volume` recursively and return every readable file.
    ///
    /// Blocking file IO — call from a background task (this function is `nonisolated async`,
    /// so it never runs on the main actor).
    /// - Throws: ``BackupError/cancelled`` when the surrounding task is cancelled.
    public static func scan(
        volume: URL,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> [MediaFile] {
        var files: [MediaFile] = []
        try walk(root: volume, directory: volume, into: &files, progress: progress)
        return files
    }

    private static func walk(
        root: URL,
        directory: URL,
        into files: inout [MediaFile],
        progress: (@Sendable (ScanProgress) -> Void)?
    ) throws {
        if Task.isCancelled { throw BackupError.cancelled }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: []
        )) ?? []

        progress?(ScanProgress(count: files.count, folder: directory.lastPathComponent))

        var subdirectories: [URL] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entry.lastPathComponent
            if name.hasPrefix(".") { continue }
            guard let values = try? entry.resourceValues(forKeys: Set(keys)) else { continue }

            if values.isDirectory == true {
                if !hiddenDirectories.contains(name) { subdirectories.append(entry) }
            } else if values.isRegularFile == true {
                files.append(
                    MediaFile(
                        name: name,
                        url: entry,
                        relativePath: relativePath(of: entry, from: root),
                        size: Int64(values.fileSize ?? 0),
                        modificationDate: values.contentModificationDate,
                        isMedia: MediaExtensions.isMedia(name)
                    )
                )
            }
        }

        for sub in subdirectories {
            if Task.isCancelled { throw BackupError.cancelled }
            try walk(root: root, directory: sub, into: &files, progress: progress)
        }
    }

    /// Path of `url` relative to `root`, using `/` separators.
    public static func relativePath(of url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return url.lastPathComponent }
        var rest = String(filePath.dropFirst(rootPath.count))
        while rest.hasPrefix("/") { rest.removeFirst() }
        return rest
    }

    /// Some cameras (DJI drones) reuse a file name across subfolders. Matching and
    /// transfer key off the file name only, so prefix colliding names with their
    /// parent folder to keep them unique and stable across rescans. `url` is untouched.
    public static func disambiguateDuplicateNames(_ files: inout [MediaFile]) {
        var indexesByName: [String: [Int]] = [:]
        for (index, file) in files.enumerated() {
            indexesByName[file.name, default: []].append(index)
        }
        for (_, indexes) in indexesByName where indexes.count > 1 {
            for index in indexes {
                let parent = (files[index].relativePath as NSString).deletingLastPathComponent
                let parentName = (parent as NSString).lastPathComponent
                if !parentName.isEmpty, parentName != "." {
                    files[index].name = "\(parentName)_\(files[index].name)"
                }
            }
        }
    }
}
