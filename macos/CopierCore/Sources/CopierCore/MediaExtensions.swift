import Foundation

/// The file extensions Copier treats as media. Everything else is "other".
public enum MediaExtensions {
    /// Photos.
    public static let photo: Set<String> = [".jpg", ".jpeg", ".heic", ".heif", ".png", ".tiff", ".tif"]
    /// Camera RAW formats.
    public static let raw: Set<String> = [".cr2", ".cr3", ".arw", ".nef", ".dng", ".raf", ".orf", ".rw2"]
    /// Video formats.
    public static let video: Set<String> = [".mp4", ".mov", ".avi", ".mts", ".m4v", ".mxf", ".crm"]
    /// Sidecar files that travel with the media they belong to.
    public static let sidecar: Set<String> = [".xmp", ".aae"]

    /// Every extension considered media (photos, RAW, video and sidecars).
    public static let all: Set<String> = photo.union(raw).union(video).union(sidecar)

    /// Video containers that use the ISOBMFF box layout and carry camera metadata.
    public static let isobmffVideo: Set<String> = [".mp4", ".mov", ".m4v", ".crm"]

    /// Formats ImageIO can read EXIF/TIFF metadata from.
    public static let stillMetadata: Set<String> = photo.union(raw)

    /// `true` when the file name has a media extension.
    public static func isMedia(_ fileName: String) -> Bool {
        all.contains(`extension`(of: fileName))
    }

    /// `true` when the file is a sidecar (`.xmp`, `.aae`).
    public static func isSidecar(_ fileName: String) -> Bool {
        sidecar.contains(`extension`(of: fileName))
    }

    /// Lower-cased extension including the leading dot, or `""` when there is none.
    public static func `extension`(of fileName: String) -> String {
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else { return "" }
        return String(fileName[dot...]).lowercased()
    }
}
