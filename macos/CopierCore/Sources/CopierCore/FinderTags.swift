import Foundation

/// A tag write that Folder Sync will apply to one destination file.
public struct TagUpdate: Sendable, Hashable, Identifiable {
    /// The file to write the tags to.
    public var destinationURL: URL
    /// Source relative path, for display.
    public var relativePath: String
    /// The full merged tag list to write.
    public var tags: [String]
    /// Tag names being added, for display.
    public var addedNames: [String]

    public var id: URL { destinationURL }

    public init(destinationURL: URL, relativePath: String, tags: [String], addedNames: [String]) {
        self.destinationURL = destinationURL
        self.relativePath = relativePath
        self.tags = tags
        self.addedNames = addedNames
    }
}

/// Finder tags, stored in the `com.apple.metadata:_kMDItemUserTags` extended attribute.
///
/// Read and written with `getxattr`/`setxattr` directly — no `xattr` subprocess.
public enum FinderTags {
    public static let attributeName = "com.apple.metadata:_kMDItemUserTags"

    // MARK: Encoding

    /// Decode a `_kMDItemUserTags` value: binary plist (written by Finder) or XML plist.
    public static func decode(_ data: Data) -> [String] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let array = plist as? [Any]
        else { return [] }
        return array.compactMap { $0 as? String }
    }

    /// Encode a tag list as an XML plist (macOS reads XML and binary alike).
    public static func encode(_ tags: [String]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: tags, format: .xml, options: 0)
    }

    /// Tag identity is the name before the `\n<color>` suffix ("Red\n6" -> "Red").
    public static func name(of tag: String) -> String {
        tag.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)[0].description
    }

    /// Union merge: target tags first, then source tags whose name is new.
    /// `nil` when there is nothing to add.
    public static func merge(source: [String], target: [String]) -> [String]? {
        let existing = Set(target.map(name(of:)))
        let toAdd = source.filter { !existing.contains(name(of: $0)) }
        return toAdd.isEmpty ? nil : target + toAdd
    }

    // MARK: File access

    /// Tags of one file, or `[]` when it has none.
    public static func read(at url: URL) -> [String] {
        guard let data = readAttribute(at: url) else { return [] }
        return decode(data)
    }

    /// Write the full tag list to a file.
    public static func write(_ tags: [String], to url: URL) throws {
        let data = try encode(tags)
        let result = data.withUnsafeBytes { buffer -> Int32 in
            setxattr(url.path, attributeName, buffer.baseAddress, buffer.count, 0, 0)
        }
        if result != 0 {
            throw BackupError.copyFailed(file: url.lastPathComponent, reason: "setxattr failed (errno \(errno))")
        }
    }

    /// Tags of the given files, keyed by file URL, leaving out the untagged ones.
    ///
    /// Preferred over ``readRecursive(_:)`` when the caller already walked the tree.
    public static func read(urls: [URL]) -> [URL: [String]] {
        var result: [URL: [String]] = [:]
        for url in urls {
            let tags = read(at: url)
            if !tags.isEmpty { result[url] = tags }
        }
        return result
    }

    /// Tags for every file under `root` that has any, keyed by file URL.
    public static func readRecursive(_ root: URL) async throws -> [URL: [String]] {
        var result: [URL: [String]] = [:]
        let files = try await FolderSync.walk(root)
        for file in files {
            let tags = read(at: file.url)
            if !tags.isEmpty { result[file.url] = tags }
        }
        return result
    }

    private static func readAttribute(at url: URL) -> Data? {
        let size = getxattr(url.path, attributeName, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = buffer.withUnsafeMutableBytes { pointer in
            getxattr(url.path, attributeName, pointer.baseAddress, size, 0, 0)
        }
        guard read > 0 else { return nil }
        return Data(buffer[0..<read])
    }
}

/// Which destination files need their tags updated.
public enum TagPlanner {
    /// Updates for files that already exist on both sides.
    public static func updates(
        for pairs: [MatchedPair],
        sourceTags: [URL: [String]],
        destinationTags: [URL: [String]]
    ) -> [TagUpdate] {
        pairs.compactMap { pair in
            update(
                destinationURL: pair.destination.url,
                relativePath: pair.source.relativePath,
                source: sourceTags[pair.source.url],
                target: destinationTags[pair.destination.url] ?? []
            )
        }
    }

    /// Updates for files about to be copied: the copy starts untagged, so merge the
    /// source tags with whatever the destination path already had at scan time.
    public static func copyUpdates(
        for files: [SyncFile],
        sourceTags: [URL: [String]],
        destinationTags: [URL: [String]],
        destinationRoot: URL
    ) -> [TagUpdate] {
        files.compactMap { file in
            let destination = destinationRoot.appendingPathComponent(file.relativePath)
            return update(
                destinationURL: destination,
                relativePath: file.relativePath,
                source: sourceTags[file.url],
                target: destinationTags[destination] ?? []
            )
        }
    }

    private static func update(
        destinationURL: URL,
        relativePath: String,
        source: [String]?,
        target: [String]
    ) -> TagUpdate? {
        guard let source, !source.isEmpty else { return nil }
        guard let merged = FinderTags.merge(source: source, target: target) else { return nil }
        let targetNames = Set(target.map(FinderTags.name(of:)))
        return TagUpdate(
            destinationURL: destinationURL,
            relativePath: relativePath,
            tags: merged,
            addedNames: source.map(FinderTags.name(of:)).filter { !targetNames.contains($0) }
        )
    }
}
