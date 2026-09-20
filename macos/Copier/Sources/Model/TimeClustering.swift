import CopierCore
import Foundation

/// What kind of file a row shows — drives the colour-coded badge in the review list.
enum FileKind: String, Sendable, CaseIterable {
    case photo
    case raw
    case video
    case other

    /// Plural label used in the day-header counts.
    func label(count: Int) -> String {
        switch self {
        case .photo: return count == 1 ? "photo" : "photos"
        case .raw: return count == 1 ? "RAW" : "RAW"
        case .video: return count == 1 ? "video" : "videos"
        case .other: return "other"
        }
    }

    var symbolName: String {
        switch self {
        case .photo: return "photo"
        case .raw: return "camera.aperture"
        case .video: return "video"
        case .other: return "doc"
        }
    }
}

extension MediaFile {
    var kind: FileKind {
        let ext = fileExtension
        if MediaExtensions.raw.contains(ext) { return .raw }
        if MediaExtensions.photo.contains(ext) { return .photo }
        if MediaExtensions.video.contains(ext) { return .video }
        return .other
    }
}

/// A run of files taken close together, used to break a long day apart visually.
/// Display only — it never changes where files are copied.
struct FileCluster: Identifiable, Sendable {
    var files: [ReviewFile]
    var start: Date?
    var end: Date?

    var id: String {
        (start?.timeIntervalSince1970).map { "\($0)" } ?? "undated-\(files.first?.file.name ?? "")"
    }
}

/// Splits a day's files into clusters whenever the camera was idle for a while.
enum TimeClustering {
    /// A gap this long starts a new cluster.
    static let defaultGap: TimeInterval = 30 * 60

    /// Cluster `files` (already in capture order). Files without any date end up in a
    /// single trailing cluster.
    static func cluster(_ files: [ReviewFile], gap: TimeInterval = defaultGap) -> [FileCluster] {
        var clusters: [FileCluster] = []
        var current: [ReviewFile] = []
        var currentStart: Date?
        var previous: Date?
        var undated: [ReviewFile] = []

        func flush() {
            guard !current.isEmpty else { return }
            clusters.append(FileCluster(files: current, start: currentStart, end: previous))
            current = []
            currentStart = nil
            previous = nil
        }

        for file in files {
            guard let date = file.file.captureDate ?? file.file.modificationDate else {
                undated.append(file)
                continue
            }
            if let last = previous, date.timeIntervalSince(last) >= gap {
                flush()
            }
            if current.isEmpty { currentStart = date }
            current.append(file)
            previous = date
        }
        flush()

        if !undated.isEmpty {
            clusters.append(FileCluster(files: undated, start: nil, end: nil))
        }
        return clusters
    }

    /// `[(photo, 112), (video, 36)]` in a stable order, zero counts left out.
    static func kindCounts(_ files: [ReviewFile]) -> [(kind: FileKind, count: Int)] {
        var counts: [FileKind: Int] = [:]
        for file in files {
            counts[file.file.kind, default: 0] += 1
        }
        return FileKind.allCases.compactMap { kind in
            guard let count = counts[kind], count > 0 else { return nil }
            return (kind, count)
        }
    }
}
