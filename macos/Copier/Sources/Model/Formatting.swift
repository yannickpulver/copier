import CopierCore
import Foundation

/// Number, size and date rendering shared by every screen.
enum Format {
    /// `48.0 MB`, `1.12 GB`, `1.2 TB` — decimal units, as the design shows them.
    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file, allowedUnits: .all, spellsOutZero: false))
    }

    /// `1,204 files`.
    static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// `18 Sep 2026`.
    static func day(_ day: Day?) -> String {
        guard let day, let date = day.startOfDay() else { return "No date" }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// `09:12`.
    static func time(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    /// `09:12–17:40`, or an empty string when the group has no dates.
    static func timeRange(_ files: [MediaFile]) -> String {
        let dates = files.compactMap { $0.captureDate ?? $0.modificationDate }
        guard let first = dates.min(), let last = dates.max() else { return "" }
        return "\(time(first))–\(time(last))"
    }

    /// `42.3 MB/s`.
    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "—" }
        return "\(bytes(Int64(bytesPerSecond)))/s"
    }

    /// `about 5 min left`, using the core estimator's wording for the duration.
    static func timeLeft(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return "about \(SpeedEstimator.formatTimeRemaining(seconds)) left"
    }

    /// `112 photos · 36 videos`, leaving out whichever part is zero.
    static func mediaCounts(_ files: [MediaFile]) -> String {
        var photos = 0
        var videos = 0
        var other = 0
        for file in files {
            let ext = file.fileExtension
            if MediaExtensions.video.contains(ext) {
                videos += 1
            } else if MediaExtensions.photo.contains(ext) || MediaExtensions.raw.contains(ext) {
                photos += 1
            } else {
                other += 1
            }
        }
        var parts: [String] = []
        if photos > 0 { parts.append("\(photos) photo\(photos == 1 ? "" : "s")") }
        if videos > 0 { parts.append("\(videos) video\(videos == 1 ? "" : "s")") }
        if other > 0 { parts.append("\(other) other") }
        return parts.isEmpty ? "no files" : parts.joined(separator: " · ")
    }

    /// Short label for a destination: `NAS · /photo/2026` style becomes the last two
    /// path components, which is what the bottom bar has room for.
    static func destinationLabel(_ url: URL) -> String {
        let components = url.standardizedFileURL.pathComponents.filter { $0 != "/" }
        return components.suffix(2).joined(separator: " · ")
    }
}
