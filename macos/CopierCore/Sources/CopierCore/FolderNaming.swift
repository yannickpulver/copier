import Foundation

/// Destination folder names: `<date> - <title>`, with the date rendered from a
/// token format (`YYYY`, `YY`, `MM`, `DD`).
public enum FolderNaming {
    /// The format used when the user has not picked one.
    public static let defaultDateFormat = "YYYY.MM.DD"

    /// Render a day with the token format. Unknown characters pass through.
    public static func formatDate(_ day: Day, format: String = defaultDateFormat) -> String {
        let year = String(format: "%04d", day.year)
        let month = String(format: "%02d", day.month)
        let dayOfMonth = String(format: "%02d", day.day)
        // YYYY before YY, so "YYYY" is never consumed by the two-digit token.
        return format
            .replacingOccurrences(of: "YYYY", with: year)
            .replacingOccurrences(of: "YY", with: String(year.suffix(2)))
            .replacingOccurrences(of: "MM", with: month)
            .replacingOccurrences(of: "DD", with: dayOfMonth)
    }

    /// Name for a folder: `2026.09.18 - Trip`, or just `2026.09.18` when the title is empty.
    /// A `nil` day (files without any date) renders as `unknown`.
    public static func folderName(day: Day?, title: String, format: String = defaultDateFormat) -> String {
        let datePart = day.map { formatDate($0, format: format) } ?? "unknown"
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? datePart : "\(datePart) - \(trimmed)"
    }

    /// Folder names that already exist at `destination`, sorted, system folders excluded.
    public static func existingFolders(at destination: URL) -> [String] {
        Matcher.listExistingFolders(at: destination)
    }

    /// The existing folders whose name starts with `day`'s formatted date — the
    /// candidates the review screen preselects.
    public static func folders(_ folders: [String], matching day: Day, format: String = defaultDateFormat) -> [String] {
        let prefix = formatDate(day, format: format)
        return folders.filter { $0.hasPrefix(prefix) }
    }

    /// The folder to preselect for a day: the first existing folder with that date prefix.
    public static func preselectedFolder(
        in folders: [String],
        for day: Day,
        format: String = defaultDateFormat
    ) -> String? {
        self.folders(folders, matching: day, format: format).first
    }

    /// Turn on "camera subfolders" automatically when any already-selected existing
    /// folder contains a subfolder named after a camera in this batch.
    /// Ported from `autoCheckCameraSubfolder` in `renderer.ts`.
    public static func autoCheckCameraSubfolder(
        files: [MediaFile],
        selectedExistingFolders: [URL]
    ) -> Bool {
        let cameras = Set(files.compactMap(\.camera))
        guard !cameras.isEmpty else { return false }
        for folder in selectedExistingFolders {
            let subfolders = Matcher.listExistingFolders(at: folder)
            if subfolders.contains(where: { cameras.contains($0) }) { return true }
        }
        return false
    }
}
