import Foundation

// MARK: - Media file

/// One file found on a card (or in a folder), enriched with metadata as scanning progresses.
public struct MediaFile: Sendable, Hashable, Identifiable, Codable {
    /// File name used for matching and for the copy destination.
    /// May be prefixed with its parent folder by ``Scanner/disambiguateDuplicateNames(_:)``.
    public var name: String
    /// Absolute location of the file on the card.
    public var url: URL
    /// Path relative to the scanned root, e.g. `DCIM/100CANON/IMG_0001.JPG`.
    public var relativePath: String
    /// Size in bytes.
    public var size: Int64
    /// File modification date, used as capture-date fallback.
    public var modificationDate: Date?
    /// Capture date from EXIF / video metadata, or the modification date as fallback.
    public var captureDate: Date?
    /// Camera model name, cleaned via ``MetadataExtractor/cleanCameraName(_:)``.
    public var camera: String?
    /// `true` for photos, RAW, video and sidecars; everything else is "other".
    public var isMedia: Bool

    public var id: URL { url }

    public init(
        name: String,
        url: URL,
        relativePath: String,
        size: Int64,
        modificationDate: Date? = nil,
        captureDate: Date? = nil,
        camera: String? = nil,
        isMedia: Bool
    ) {
        self.name = name
        self.url = url
        self.relativePath = relativePath
        self.size = size
        self.modificationDate = modificationDate
        self.captureDate = captureDate
        self.camera = camera
        self.isMedia = isMedia
    }

    /// Lower-cased file extension including the dot, or `""`.
    public var fileExtension: String { MediaExtensions.extension(of: name) }
}

// MARK: - Matching key

/// A file identity for duplicate detection: file name plus exact byte size.
public struct FileKey: Sendable, Hashable, Codable {
    public let name: String
    public let size: Int64

    public init(name: String, size: Int64) {
        self.name = name
        self.size = size
    }

    public init(_ file: MediaFile) {
        self.init(name: file.name, size: file.size)
    }
}

// MARK: - Errors

/// Everything the core layer can fail with in a way the UI must explain.
public enum BackupError: Error, Sendable, Equatable {
    /// The Synology NAS could not be reached or rejected the login.
    case nasUnreachable(host: String, reason: String)
    /// A destination volume does not have room. `shortfall` is `required - free`.
    case insufficientSpace(destination: URL, requiredBytes: Int64, freeBytes: Int64)
    /// Copying a file failed.
    case copyFailed(file: String, reason: String)
    /// The copy completed but the destination size did not match the source.
    case verificationFailed(file: String, expectedBytes: Int64, actualBytes: Int64)
    /// A check location could not be read, so it was not searched for existing copies.
    case sourceUnavailable(name: String, reason: String)
    /// The source card disappeared mid-operation.
    case cardRemoved(volume: URL)
    /// The operation was cancelled by the user.
    case cancelled

    /// Missing bytes for ``insufficientSpace``, otherwise `nil`.
    public var shortfallBytes: Int64? {
        if case let .insufficientSpace(_, required, free) = self { return max(0, required - free) }
        return nil
    }
}

extension BackupError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .nasUnreachable(host, reason):
            return "NAS \(host) unreachable: \(reason)"
        case let .insufficientSpace(destination, required, free):
            return "Not enough free space at \(destination.path) — need \(required) bytes, \(free) available."
        case let .copyFailed(file, reason):
            return "\(file): \(reason)"
        case let .verificationFailed(file, expected, actual):
            return "\(file): size mismatch after copy (\(actual) of \(expected) bytes)"
        case let .sourceUnavailable(name, reason):
            return "\(name) was not checked: \(reason)."
        case let .cardRemoved(volume):
            return "Card \(volume.lastPathComponent) was removed."
        case .cancelled:
            return "Cancelled."
        }
    }
}

// MARK: - Folder model

/// How the selected files are laid out at the destination.
public enum Structure: String, Sendable, Codable, CaseIterable {
    /// One folder per capture day.
    case folderPerDay
    /// Everything into a single folder, dated after the first day.
    case oneFolder
}

/// Where the files of one day go: a folder to create, or a folder that already exists.
public enum FolderTarget: Sendable, Hashable {
    /// Create `<date> - <title>` (or just `<date>` when the title is empty).
    case new(title: String)
    /// Add the files to this existing folder.
    case existing(URL)
}

// MARK: - Check sources

/// A local path that is searched for already-backed-up files.
public struct CheckPath: Sendable, Hashable, Codable {
    public var path: String
    /// Only scanned when the Synology API failed.
    public var fallbackOnly: Bool

    public init(path: String, fallbackOnly: Bool = false) {
        self.path = path
        self.fallbackOnly = fallbackOnly
    }

    /// Last path component, used as the display name of the source.
    public var label: String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? path
    }
}

/// Synology FileStation connection settings.
public struct SynologyConfig: Sendable, Hashable {
    public var host: String
    public var port: Int
    public var user: String
    public var password: String
    public var secure: Bool
    public var folders: [String]

    public init(
        host: String,
        port: Int = 5001,
        user: String,
        password: String,
        secure: Bool = true,
        folders: [String]
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.secure = secure
        self.folders = folders
    }
}
