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

    /// The kind a file name's extension stands for.
    init(fileName: String) {
        let ext = MediaExtensions.extension(of: fileName)
        if MediaExtensions.raw.contains(ext) {
            self = .raw
        } else if MediaExtensions.photo.contains(ext) {
            self = .photo
        } else if MediaExtensions.video.contains(ext) {
            self = .video
        } else {
            self = .other
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
    /// The name of a folder the user made inside a camera folder on the card, as in
    /// `DCIM/100CANON/Isa & Spencer/IMG_0001.CR3`. Camera folders (`100CANON`,
    /// `100_0001`) follow the DCF pattern of three digits and five characters.
    var cardFolderTitle: String? {
        let folders = (relativePath as NSString).pathComponents.dropLast()
        guard let camera = folders.firstIndex(where: { $0.wholeMatch(of: /\d{3}\w{5}/) != nil }),
              camera + 1 < folders.endIndex
        else { return nil }
        return folders[camera + 1]
    }

    var kind: FileKind { FileKind(fileName: name) }
}

/// A run of files taken close together, used to break a long day apart. When the user
/// splits a day, each cluster becomes a block with its own folder.
struct FileCluster: Identifiable, Sendable {
    var files: [ReviewFile]
    var start: Date?
    var end: Date?
    /// The card folder the files came from, when the user already sorted them there.
    var title: String?

    var id: String {
        let time = (start?.timeIntervalSince1970).map { "\($0)" } ?? "undated-\(files.first?.file.name ?? "")"
        return title.map { "\($0)-\(time)" } ?? time
    }

    /// The file whose thumbnail stands for the cluster: the middle photo, or the middle
    /// video when there are no photos.
    var previewFile: MediaFile? {
        let photos = files.map(\.file).filter { $0.kind == .photo || $0.kind == .raw }
        let candidates = photos.isEmpty ? files.map(\.file).filter { $0.kind == .video } : photos
        return candidates.isEmpty ? nil : candidates[candidates.count / 2]
    }
}

/// Splits a day's files into clusters whenever the camera was idle for a while.
enum TimeClustering {
    /// A gap this long starts a new cluster.
    static let defaultGap: TimeInterval = 30 * 60

    /// Cluster `files` (already in capture order). Each card folder the user made is one
    /// cluster of its own; the rest is split on time gaps.
    static func cluster(_ files: [ReviewFile], gap: TimeInterval = defaultGap) -> [FileCluster] {
        var titles: [String] = []
        var byTitle: [String: [ReviewFile]] = [:]
        var loose: [ReviewFile] = []
        for file in files {
            guard let title = file.file.cardFolderTitle else {
                loose.append(file)
                continue
            }
            if byTitle[title] == nil { titles.append(title) }
            byTitle[title, default: []].append(file)
        }
        guard !titles.isEmpty else { return cluster(byTime: files, gap: gap) }

        let named = titles.map { title in
            let dates = byTitle[title, default: []].compactMap { $0.file.captureDate ?? $0.file.modificationDate }
            return FileCluster(files: byTitle[title, default: []], start: dates.first, end: dates.last, title: title)
        }
        // Undated clusters stay last, as in the time-only split.
        return (cluster(byTime: loose, gap: gap) + named)
            .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
    }

    /// Files without any date end up in a single trailing cluster.
    private static func cluster(byTime files: [ReviewFile], gap: TimeInterval) -> [FileCluster] {
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
