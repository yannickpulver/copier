import Foundation

/// Where an index came from.
public enum SourceKind: Sendable, Equatable {
    /// The Synology FileStation API.
    case api
    /// A mounted path (NAS share, SSD, …).
    case local
}

/// One place that is searched for already-backed-up files.
public protocol BackupIndexSource: Sendable {
    var name: String { get }
    var kind: SourceKind { get }
    /// `true` for paths that are only scanned when the API failed.
    var isFallbackOnly: Bool { get }
    func index(
        targetKeys: Set<FileKey>,
        progress: (@Sendable (ScanProgress) -> Void)?
    ) async throws -> LocationIndex
}

/// A local path source.
public struct LocalPathSource: BackupIndexSource {
    public let path: CheckPath

    public init(_ path: CheckPath) { self.path = path }

    public var name: String { path.label }
    public var kind: SourceKind { .local }
    public var isFallbackOnly: Bool { path.fallbackOnly }

    /// - Throws: ``BackupError/sourceUnavailable(name:reason:)`` when the path is not a
    ///   readable directory. An unreachable NAS share or an unplugged SSD must fail
    ///   loudly — an empty index would silently mark the whole card as new.
    public func index(
        targetKeys: Set<FileKey>,
        progress: (@Sendable (ScanProgress) -> Void)?
    ) async throws -> LocationIndex {
        let root = URL(fileURLWithPath: path.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw BackupError.sourceUnavailable(name: path.label, reason: "\(path.path) is not available")
        }
        guard isDirectory.boolValue else {
            throw BackupError.sourceUnavailable(name: path.label, reason: "\(path.path) is not a folder")
        }
        guard FileManager.default.isReadableFile(atPath: root.path) else {
            throw BackupError.sourceUnavailable(name: path.label, reason: "\(path.path) is not readable")
        }
        return await Matcher.indexLocalPath(root, targetKeys: targetKeys, progress: progress)
    }
}

/// The Synology API source.
public struct SynologySource: BackupIndexSource {
    public let name: String
    private let client: SynologyClient
    private let folders: [String]

    public init(name: String = "Synology API", client: SynologyClient, folders: [String]) {
        self.name = name
        self.client = client
        self.folders = folders
    }

    public var kind: SourceKind { .api }
    public var isFallbackOnly: Bool { false }

    public func index(
        targetKeys: Set<FileKey>,
        progress: (@Sendable (ScanProgress) -> Void)?
    ) async throws -> LocationIndex {
        try await client.login()
        return try await client.index(folders: folders, targetKeys: targetKeys, progress: progress)
    }
}

/// What one source produced.
public struct SourceResult: Sendable {
    public var name: String
    public var kind: SourceKind
    public var index: LocationIndex
    public var succeeded: Bool
    public var errorDescription: String?

    public init(name: String, kind: SourceKind, index: LocationIndex, succeeded: Bool, errorDescription: String? = nil) {
        self.name = name
        self.kind = kind
        self.index = index
        self.succeeded = succeeded
        self.errorDescription = errorDescription
    }
}

/// Which phase a scan is in, for the scanning screen.
public enum ScanPhase: Sendable, Equatable {
    case card
    case sources
    case metadata
}

/// A scan progress event.
public struct ScanEvent: Sendable {
    public var phase: ScanPhase
    public var count: Int
    public var total: Int?
    public var detail: String

    public init(phase: ScanPhase, count: Int, total: Int? = nil, detail: String) {
        self.phase = phase
        self.count = count
        self.total = total
        self.detail = detail
    }
}

/// Everything the review screen needs after a scan.
public struct ScanResult: Sendable {
    public var allFiles: [MediaFile]
    public var backedUp: [MediaFile]
    public var missing: [MediaFile]
    public var suggestedFolders: [SuggestedFolder]
    public var sources: [SourceResult]

    public init(
        allFiles: [MediaFile],
        backedUp: [MediaFile],
        missing: [MediaFile],
        suggestedFolders: [SuggestedFolder],
        sources: [SourceResult]
    ) {
        self.allFiles = allFiles
        self.backedUp = backedUp
        self.missing = missing
        self.suggestedFolders = suggestedFolders
        self.sources = sources
    }

    /// Non-media files found on the card ("other").
    public var otherFiles: [MediaFile] { allFiles.filter { !$0.isMedia } }
}

/// Runs a full card scan: walk the card, index the check sources, match, enrich.
public struct BackupScan: Sendable {
    public init() {}

    /// Scan a card.
    ///
    /// - Parameters:
    ///   - card: the mounted volume (or fixture folder).
    ///   - sources: the places to check for existing copies. API sources run first;
    ///     `isFallbackOnly` sources are skipped when an API source succeeded.
    ///   - skipCheck: fast scan — treat every media file as new and only read metadata.
    public func run(
        card: URL,
        sources: [any BackupIndexSource],
        skipCheck: Bool = false,
        progress: (@Sendable (ScanEvent) -> Void)? = nil
    ) async throws -> ScanResult {
        var files = try await Scanner.scan(volume: card) { step in
            progress?(ScanEvent(phase: .card, count: step.count, detail: step.folder))
        }
        Scanner.disambiguateDuplicateNames(&files)
        if Task.isCancelled { throw BackupError.cancelled }

        if skipCheck {
            var media = files.filter(\.isMedia)
            try await MetadataExtractor.enrich(&media) { done, total in
                progress?(ScanEvent(phase: .metadata, count: done, total: total, detail: "\(done)/\(total)"))
            }
            return ScanResult(
                allFiles: files,
                backedUp: [],
                missing: media,
                suggestedFolders: [],
                sources: []
            )
        }

        let targetKeys = Set(files.map(FileKey.init))
        var results: [SourceResult] = []

        // API sources first — the fallback rule depends on whether they worked.
        for source in sources where source.kind == .api {
            results.append(await run(source: source, targetKeys: targetKeys, progress: progress))
        }
        let apiSucceeded = results.contains { $0.kind == .api && $0.succeeded }

        for source in sources where source.kind != .api {
            if source.isFallbackOnly, apiSucceeded { continue }
            results.append(await run(source: source, targetKeys: targetKeys, progress: progress))
        }
        if Task.isCancelled { throw BackupError.cancelled }

        let match = Matcher.checkBackedUp(
            files: files,
            sources: results.map { SourceIndex(name: $0.name, index: $0.index) }
        )

        var missing = match.missing.filter(\.isMedia)
        try await MetadataExtractor.enrich(&missing) { done, total in
            progress?(ScanEvent(phase: .metadata, count: done, total: total, detail: "\(done)/\(total)"))
        }

        return ScanResult(
            allFiles: files,
            backedUp: match.backedUp,
            missing: missing,
            suggestedFolders: match.suggestedFolders,
            sources: results
        )
    }

    private func run(
        source: any BackupIndexSource,
        targetKeys: Set<FileKey>,
        progress: (@Sendable (ScanEvent) -> Void)?
    ) async -> SourceResult {
        let name = source.name
        do {
            let index = try await source.index(targetKeys: targetKeys) { step in
                progress?(ScanEvent(phase: .sources, count: step.count, detail: "\(name): \(step.folder)"))
            }
            return SourceResult(name: name, kind: source.kind, index: index, succeeded: true)
        } catch {
            return SourceResult(
                name: name,
                kind: source.kind,
                index: LocationIndex(),
                succeeded: false,
                errorDescription: error.localizedDescription
            )
        }
    }
}
