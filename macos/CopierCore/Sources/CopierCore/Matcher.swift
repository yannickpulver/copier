import Foundation

/// A file-name+size index of one location, mapping each key to the folders that hold it.
public struct LocationIndex: Sendable, Hashable {
    public private(set) var entries: [FileKey: [URL]]

    public init(entries: [FileKey: [URL]] = [:]) {
        self.entries = entries
    }

    public var count: Int { entries.count }

    public mutating func add(_ key: FileKey, folder: URL) {
        entries[key, default: []].append(folder)
    }

    public func folders(for key: FileKey) -> [URL]? { entries[key] }

    /// Merge several indexes into one.
    public static func merged(_ indexes: [LocationIndex]) -> LocationIndex {
        var merged = LocationIndex()
        for index in indexes {
            for (key, folders) in index.entries {
                merged.entries[key, default: []].append(contentsOf: folders)
            }
        }
        return merged
    }
}

/// An index together with the name of the source it came from.
public struct SourceIndex: Sendable {
    public var name: String
    public var index: LocationIndex

    public init(name: String, index: LocationIndex) {
        self.name = name
        self.index = index
    }
}

/// A destination folder that already holds files from this card.
public struct SuggestedFolder: Sendable, Hashable {
    public var folder: URL
    public var count: Int
    public var source: String
    /// Newest modification date among the matched card files (recency signal).
    public var newestModification: Date?

    public init(folder: URL, count: Int, source: String, newestModification: Date?) {
        self.folder = folder
        self.count = count
        self.source = source
        self.newestModification = newestModification
    }
}

/// Result of comparing the card against all check sources.
public struct MatchResult: Sendable {
    /// Files already present in at least one location (name + exact size).
    public var backedUp: [MediaFile]
    /// Files not found anywhere.
    public var missing: [MediaFile]
    /// Up to ten destination folders that already hold files from this card, most matches first.
    public var suggestedFolders: [SuggestedFolder]

    public init(backedUp: [MediaFile], missing: [MediaFile], suggestedFolders: [SuggestedFolder]) {
        self.backedUp = backedUp
        self.missing = missing
        self.suggestedFolders = suggestedFolders
    }
}

/// Duplicate detection: a file counts as backed up when its name and exact byte
/// size are found in any indexed location.
public enum Matcher {
    /// System / recycle-bin folders that are never scanned or suggested.
    /// Synology's `@eaDir` thumbnails in particular shadow original names and slow SMB walks down.
    public static let ignoredFolders: Set<String> = [
        "$recycle.bin", "system volume information", "#recycle", "@eadir", ".trashes", "found.000",
    ]

    /// Number of parallel `stat` calls per folder — sequential stats over SMB are one
    /// network round trip each and dominate scan time.
    public static let statConcurrency = 16

    /// `true` when a directory name must be skipped during indexing.
    public static func isIgnored(directoryName name: String) -> Bool {
        name.hasPrefix(".") || ignoredFolders.contains(name.lowercased())
    }

    /// Index a local (or SMB-mounted) path.
    ///
    /// Newest folders are visited first, and the walk stops early once every key in
    /// `targetKeys` has been found.
    public static func indexLocalPath(
        _ root: URL,
        targetKeys: Set<FileKey>? = nil,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async -> LocationIndex {
        var index = LocationIndex()
        var remaining = targetKeys
        await walk(root, index: &index, remaining: &remaining, progress: progress)
        return index
    }

    @discardableResult
    private static func walk(
        _ directory: URL,
        index: inout LocationIndex,
        remaining: inout Set<FileKey>?,
        progress: (@Sendable (ScanProgress) -> Void)?
    ) async -> Bool {
        if Task.isCancelled { return true }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: []
        )) ?? []

        progress?(ScanProgress(count: index.count, folder: directory.lastPathComponent))

        var subdirectories: [URL] = []
        var fileURLs: [URL] = []
        for entry in entries {
            let name = entry.lastPathComponent
            if isIgnored(directoryName: name) { continue }
            guard let values = try? entry.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                subdirectories.append(entry)
            } else if values.isRegularFile == true {
                fileURLs.append(entry)
            }
        }

        let sized = await sizes(of: fileURLs)
        for (name, size) in sized {
            let key = FileKey(name: name, size: size)
            index.add(key, folder: directory)
            remaining?.remove(key)
        }

        if let remaining, remaining.isEmpty { return true }

        // Descending so the newest (date-named) folders are scanned first.
        for sub in subdirectories.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            if await walk(sub, index: &index, remaining: &remaining, progress: progress) { return true }
        }
        return false
    }

    /// Stat a batch of files with bounded concurrency.
    private static func sizes(of urls: [URL]) async -> [(String, Int64)] {
        guard !urls.isEmpty else { return [] }
        let limit = min(statConcurrency, urls.count)
        return await withTaskGroup(of: (String, Int64)?.self) { group in
            var next = 0
            func submit() {
                let url = urls[next]
                next += 1
                group.addTask {
                    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                          let size = values.fileSize
                    else { return nil }
                    return (url.lastPathComponent, Int64(size))
                }
            }
            while next < limit { submit() }
            var result: [(String, Int64)] = []
            while let finished = await group.next() {
                if let finished { result.append(finished) }
                if next < urls.count { submit() }
            }
            return result
        }
    }

    /// Split the card files into backed-up and missing, and suggest destination folders.
    public static func checkBackedUp(
        files: [MediaFile],
        sources: [SourceIndex]
    ) -> MatchResult {
        let merged = LocationIndex.merged(sources.map(\.index))

        var folderToSource: [URL: String] = [:]
        for source in sources {
            for (_, folders) in source.index.entries {
                for folder in folders {
                    if folderToSource[folder] == nil { folderToSource[folder] = source.name }
                    let top = dateLevelFolder(folder)
                    if folderToSource[top] == nil { folderToSource[top] = source.name }
                }
            }
        }

        var backedUp: [MediaFile] = []
        var missing: [MediaFile] = []
        var info: [URL: (count: Int, source: String, newest: Date?)] = [:]

        for file in files {
            guard let folders = merged.folders(for: FileKey(file)) else {
                missing.append(file)
                continue
            }
            backedUp.append(file)
            for folder in folders {
                let top = dateLevelFolder(folder)
                if var existing = info[top] {
                    existing.count += 1
                    existing.newest = newer(existing.newest, file.modificationDate)
                    info[top] = existing
                } else {
                    info[top] = (
                        1,
                        folderToSource[folder] ?? folderToSource[top] ?? "Unknown",
                        file.modificationDate
                    )
                }
            }
        }

        var suggested: [SuggestedFolder] = []
        suggested.reserveCapacity(info.count)
        for (folder, value) in info {
            suggested.append(
                SuggestedFolder(
                    folder: folder,
                    count: value.count,
                    source: value.source,
                    newestModification: value.newest
                )
            )
        }
        suggested.sort { (lhs: SuggestedFolder, rhs: SuggestedFolder) -> Bool in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.folder.path < rhs.folder.path
        }

        return MatchResult(backedUp: backedUp, missing: missing, suggestedFolders: Array(suggested.prefix(10)))
    }

    private static func newer(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (l?, r?): return max(l, r)
        case let (l?, nil): return l
        case let (nil, r?): return r
        default: return nil
        }
    }

    /// Walk up to the nearest ancestor whose name starts with `YYYY.MM.DD` or `YYYY-MM-DD`.
    public static func dateLevelFolder(_ folder: URL) -> URL {
        let components = folder.standardizedFileURL.pathComponents
        for index in stride(from: components.count - 1, through: 0, by: -1) {
            if startsWithDate(components[index]) {
                var result = URL(fileURLWithPath: "/")
                for component in components[1...index] {
                    result.appendPathComponent(component)
                }
                return result
            }
        }
        return folder
    }

    private static func startsWithDate(_ name: String) -> Bool {
        let chars = Array(name)
        guard chars.count >= 10 else { return false }
        func digits(_ range: Range<Int>) -> Bool { range.allSatisfy { chars[$0].isNumber } }
        let separators: Set<Character> = [".", "-"]
        return digits(0..<4) && separators.contains(chars[4]) && digits(5..<7)
            && separators.contains(chars[7]) && digits(8..<10)
    }

    /// Folder names directly under `root`, ignoring dot-folders and system folders.
    public static func listExistingFolders(at root: URL) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .filter { !isIgnored(directoryName: $0) }
            .sorted()
    }

}
