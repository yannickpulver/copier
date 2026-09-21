import Foundation

/// A calendar day in the local time zone, used as the grouping key for files and folders.
public struct Day: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The local calendar day of `date`.
    public init(date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: components.year ?? 0, month: components.month ?? 1, day: components.day ?? 1)
    }

    /// `YYYY-MM-DD`.
    public var isoString: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var description: String { isoString }

    /// Midnight local time on this day, if representable.
    public func startOfDay(calendar: Calendar = .current) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    public static func < (lhs: Day, rhs: Day) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// All files that share one capture day.
public struct DayGroup: Sendable, Identifiable {
    /// `nil` when the files have no capture date at all.
    public let day: Day?
    public var files: [MediaFile]

    public var id: String { day?.isoString ?? "unknown" }

    public init(day: Day?, files: [MediaFile]) {
        self.day = day
        self.files = files
    }

    /// Total bytes in this group.
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

/// Grouping of files by local capture day. Session detection (gap splitting) from
/// the Electron app is deliberately not ported — the new design drops it.
public enum DayGrouping {
    /// Group files by their local capture day, oldest day first, undated files last.
    /// Files inside a group keep capture order.
    public static func group(_ files: [MediaFile], calendar: Calendar = .current) -> [DayGroup] {
        var byDay: [Day: [MediaFile]] = [:]
        var undated: [MediaFile] = []

        for file in files {
            guard let date = file.captureDate ?? file.modificationDate else {
                undated.append(file)
                continue
            }
            byDay[Day(date: date, calendar: calendar), default: []].append(file)
        }

        var groups: [DayGroup] = byDay.keys.sorted().map { day in
            let sorted = byDay[day, default: []].sorted { lhs, rhs in
                let left = lhs.captureDate ?? lhs.modificationDate ?? .distantPast
                let right = rhs.captureDate ?? rhs.modificationDate ?? .distantPast
                if left != right { return left < right }
                return lhs.name < rhs.name
            }
            return DayGroup(day: day, files: sorted)
        }
        if !undated.isEmpty {
            groups.append(DayGroup(day: nil, files: undated))
        }
        return groups
    }

    /// The days present in `files`, oldest first.
    public static func days(in files: [MediaFile], calendar: Calendar = .current) -> [Day] {
        group(files, calendar: calendar).compactMap(\.day)
    }

    /// Per-camera split of a group, used for camera subfolders. Files without a
    /// camera land under "Unknown".
    public static func groupByCamera(_ files: [MediaFile]) -> [(camera: String, files: [MediaFile])] {
        var order: [String] = []
        var byCamera: [String: [MediaFile]] = [:]
        for file in files {
            let camera = file.camera ?? "Unknown"
            if byCamera[camera] == nil { order.append(camera) }
            byCamera[camera, default: []].append(file)
        }
        return order.map { ($0, byCamera[$0] ?? []) }
    }
}
