import Foundation

/// A subfolder together with its modification date (`nil` when it could not be read).
public struct Subfolder: Sendable, Hashable {
    public var path: String
    public var modified: Date?

    public init(path: String, modified: Date?) {
        self.path = path
        self.modified = modified
    }
}

/// Everything directly inside one folder.
public struct FolderListing: Sendable {
    public var files: [FileKey]
    public var subfolders: [Subfolder]

    public init(files: [FileKey], subfolders: [Subfolder]) {
        self.files = files
        self.subfolders = subfolders
    }
}

/// How a walk reads one location: the file system or the Synology API.
public protocol FolderBrowser: Sendable {
    /// The files and subfolders directly in `folder`. Throws when the folder can't be read.
    func list(_ folder: String) async throws -> FolderListing
    /// The subfolders of a folder that has not changed since it was cached, with fresh dates.
    /// `cached` are the subfolder paths from the cache.
    func subfolders(of folder: String, cached: [String]) async throws -> [Subfolder]
}

/// What a walk remembers about one folder.
public struct CachedFolder: Sendable, Codable, Equatable {
    public var modified: Date
    public var files: [FileKey]
    public var subfolders: [String]

    public init(modified: Date, files: [FileKey], subfolders: [String]) {
        self.modified = modified
        self.files = files
        self.subfolders = subfolders
    }
}

/// The cache of one source, stored as JSON. A folder's own modification date changes
/// whenever a file or subfolder directly in it is added, removed or renamed, so an
/// unchanged date means the cached files are still right.
public struct FolderCache: Sendable, Codable, Equatable {
    public var folders: [String: CachedFolder] = [:]

    public init(folders: [String: CachedFolder] = [:]) {
        self.folders = folders
    }

    /// The cache at `url`, or an empty one when it is missing or unreadable.
    public static func load(from url: URL) -> FolderCache {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(FolderCache.self, from: data)
        else { return FolderCache() }
        return cache
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// `~/Library/Application Support/Copier/FolderCache/<name>.json`, with `name`
    /// reduced to characters that are safe in a file name.
    public static func fileURL(name: String) -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let safe = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" })
        return support
            .appendingPathComponent("Copier/FolderCache", isDirectory: true)
            .appendingPathComponent("\(safe).json")
    }
}

/// Indexes a location by walking it newest-first. Folders whose modification date
/// matches the cache are not read again, only their subfolders' dates are refreshed.
public enum FolderWalk {
    /// - Parameters:
    ///   - roots: the folders to walk. They are always read, never taken from the cache.
    ///   - targetKeys: the walk stops early once every key has been found.
    ///   - cacheFile: where the cache is loaded from and saved to; `nil` disables caching.
    public static func index(
        roots: [String],
        browser: any FolderBrowser,
        targetKeys: Set<FileKey>? = nil,
        cacheFile: URL? = nil,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> LocationIndex {
        var cache = cacheFile.map(FolderCache.load) ?? FolderCache()
        var visited = FolderCache()
        var index = LocationIndex()
        var remaining = targetKeys
        var stoppedEarly = false

        var stack = roots.reversed().map { Subfolder(path: $0, modified: nil) }
        while let folder = stack.popLast() {
            if Task.isCancelled { throw BackupError.cancelled }
            progress?(ScanProgress(count: index.count, folder: (folder.path as NSString).lastPathComponent))

            var listing: FolderListing?
            if let modified = folder.modified, let cached = cache.folders[folder.path], cached.modified == modified {
                if let subfolders = try? await browser.subfolders(of: folder.path, cached: cached.subfolders) {
                    listing = FolderListing(files: cached.files, subfolders: subfolders)
                }
            }
            if listing == nil {
                listing = try? await browser.list(folder.path)
            }
            // A folder that can't be read is skipped and never cached, so it is retried next time.
            guard let listing else { continue }

            let files = listing.files.filter { !Matcher.isIgnored(directoryName: $0.name) }
            let subfolders = listing.subfolders.filter {
                !Matcher.isIgnored(directoryName: ($0.path as NSString).lastPathComponent)
            }
            if let modified = folder.modified {
                let entry = CachedFolder(modified: modified, files: files, subfolders: subfolders.map(\.path))
                cache.folders[folder.path] = entry
                visited.folders[folder.path] = entry
            }

            let url = URL(fileURLWithPath: folder.path, isDirectory: true)
            for key in files {
                index.add(key, folder: url)
                remaining?.remove(key)
            }
            if let remaining, remaining.isEmpty {
                stoppedEarly = true
                break
            }

            // Ascending push, popLast takes from the end — newest (date-named) folders first.
            stack.append(contentsOf: subfolders.sorted { $0.path < $1.path })
        }

        if let cacheFile {
            // A full walk saw every folder that still exists; an early stop keeps the rest.
            try? (stoppedEarly ? cache : visited).save(to: cacheFile)
        }
        return index
    }
}
