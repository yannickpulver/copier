import Foundation
import ImageIO

/// Capture date and camera model of one file.
public struct FileMetadata: Sendable, Hashable {
    public var captureDate: Date?
    public var camera: String?

    public init(captureDate: Date? = nil, camera: String? = nil) {
        self.captureDate = captureDate
        self.camera = camera
    }

    public var isEmpty: Bool { captureDate == nil && camera == nil }
}

/// Reads capture date and camera model.
///
/// Stills and RAW (including RAF and CR3) go through ImageIO; ISOBMFF video goes
/// through ``ISOBMFFParser``. The file's modification date is the fallback capture date.
public enum MetadataExtractor {
    /// How many files are read in parallel during ``enrich(_:progress:)``.
    public static let concurrency = 8

    /// Extract metadata for one file. Never throws — an unreadable file yields the mtime.
    public static func extract(from url: URL) -> FileMetadata {
        let ext = MediaExtensions.extension(of: url.lastPathComponent)
        var result = FileMetadata()

        if MediaExtensions.isobmffVideo.contains(ext) {
            let tags = ISOBMFFParser.parse(url: url)
            var model = tags.model
            if model == nil, let encoder = tags.encoder, ISOBMFFParser.isDJIEncoder(encoder) {
                model = encoder
            }
            let date = tags.dateString.flatMap(DateParsing.parseFlexible)
            if model != nil || date != nil {
                result = FileMetadata(captureDate: date, camera: cleanCameraName(model))
            }
        } else if MediaExtensions.stillMetadata.contains(ext) {
            result = imageIOMetadata(url: url) ?? FileMetadata()
        }

        if result.captureDate == nil {
            result.captureDate = modificationDate(of: url)
        }
        return result
    }

    /// Read TIFF `Model` and EXIF `DateTimeOriginal` via ImageIO. Returns `nil` when
    /// ImageIO cannot open the file or finds neither value.
    public static func imageIOMetadata(url: URL) -> FileMetadata? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options as CFDictionary) as? [CFString: Any]
        else { return nil }

        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]

        let model = tiff?[kCGImagePropertyTIFFModel] as? String
        let dateString = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
            ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)

        let date = dateString.flatMap(DateParsing.parseExif)
        let camera = cleanCameraName(model)
        if date == nil, camera == nil { return nil }
        return FileMetadata(captureDate: date, camera: camera)
    }

    /// Fill in capture date and camera for every file that has none yet, with
    /// bounded concurrency, then resolve ambiguous DJI names across the batch.
    public static func enrich(
        _ files: inout [MediaFile],
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws {
        let total = files.count
        let pending: [(Int, URL)] = files.enumerated()
            .filter { $0.element.captureDate == nil }
            .map { ($0.offset, $0.element.url) }

        guard !pending.isEmpty else {
            resolveAmbiguousCameras(&files)
            return
        }

        var results: [(Int, FileMetadata)] = []
        results.reserveCapacity(pending.count)

        try await withThrowingTaskGroup(of: (Int, FileMetadata).self) { group in
            var next = 0
            let limit = min(concurrency, pending.count)
            func submit() {
                let (index, url) = pending[next]
                next += 1
                group.addTask { (index, extract(from: url)) }
            }
            while next < limit { submit() }
            var done = 0
            while let finished = try await group.next() {
                if Task.isCancelled { throw BackupError.cancelled }
                results.append(finished)
                done += 1
                progress?(done, total)
                if next < pending.count { submit() }
            }
        }

        for (index, metadata) in results {
            files[index].captureDate = metadata.captureDate
            files[index].camera = metadata.camera
        }
        resolveAmbiguousCameras(&files)
    }

    /// DJI multi-lens drones report a different model code per lens. When an
    /// unambiguous drone-specific code appears alongside a shared wide-angle code
    /// (`L2D-20c` is shared by Mavic 3 / 3 Classic / 3 Pro), upgrade the ambiguous
    /// files to the specific drone seen in the batch.
    public static func resolveAmbiguousCameras(_ files: inout [MediaFile]) {
        let names = Set(files.compactMap(\.camera))
        var upgrades: [String: String] = [:]
        if names.contains("DJI Mavic 3 Pro") { upgrades["DJI Mavic 3"] = "DJI Mavic 3 Pro" }
        guard !upgrades.isEmpty else { return }
        for index in files.indices {
            if let camera = files[index].camera, let upgraded = upgrades[camera] {
                files[index].camera = upgraded
            }
        }
    }

    /// Normalize a raw model string: first comma-separated component, DJI model-code
    /// lookup, then spacing normalization for compact DJI video names.
    public static func cleanCameraName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let first = raw.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty else { return nil }
        if let mapped = DJIModels.map[first] { return mapped }

        // DJI videos report compact names ("DJI Mavic3Pro", "DJI Air3S"). Normalize the
        // spacing so they merge with the EXIF-derived photo folder.
        guard let match = first.range(of: "^DJI\\s+", options: [.regularExpression, .caseInsensitive]) else {
            return first
        }
        var rest = String(first[match.upperBound...])
        rest = replace(rest, pattern: "([a-z])([0-9])", template: "$1 $2", caseInsensitive: true)
        rest = replace(rest, pattern: "([0-9])([A-Z][a-z])", template: "$1 $2", caseInsensitive: false)
        rest = replace(rest, pattern: "\\s+", template: " ", caseInsensitive: false)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "DJI \(rest)"
    }

    private static func replace(_ value: String, pattern: String, template: String, caseInsensitive: Bool) -> String {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return value }
        return regex.stringByReplacingMatches(
            in: value,
            options: [],
            range: NSRange(value.startIndex..., in: value),
            withTemplate: template
        )
    }

    static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

/// Date string parsing for the formats cameras write.
public enum DateParsing {
    /// EXIF `DateTimeOriginal`: `2026:09:18 14:03:11`, interpreted in the local time zone.
    public static func parseExif(_ value: String) -> Date? {
        let normalized = value.replacingOccurrences(
            of: "^(\\d{4}):(\\d{2}):(\\d{2})",
            with: "$1-$2-$3",
            options: .regularExpression
        )
        return parseFlexible(normalized)
    }

    /// Accepts ISO 8601 (with or without zone/fractional seconds) and the
    /// `yyyy-MM-dd HH:mm:ss` shapes video containers use.
    public static func parseFlexible(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }

        for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }
}
