import Foundation
import Testing
@testable import CopierCore

@Suite("Folder naming")
struct FolderNamingTests {
    let day = Day(year: 2026, month: 9, day: 18)

    @Test("default format")
    func defaultFormat() {
        #expect(FolderNaming.formatDate(day) == "2026.09.18")
    }

    @Test("date tokens", arguments: [
        ("YYYY.MM.DD", "2026.09.18"),
        ("YYYY-MM-DD", "2026-09-18"),
        ("YY.MM.DD", "26.09.18"),
        ("DD.MM.YYYY", "18.09.2026"),
        ("YYYYMMDD", "20260918"),
        ("MM/DD/YY", "09/18/26"),
    ])
    func tokens(format: String, expected: String) {
        #expect(FolderNaming.formatDate(day, format: format) == expected)
    }

    @Test("folder name appends the title when non-empty")
    func folderName() {
        #expect(FolderNaming.folderName(day: day, title: "Trip") == "2026.09.18 - Trip")
        #expect(FolderNaming.folderName(day: day, title: "") == "2026.09.18")
        #expect(FolderNaming.folderName(day: day, title: "   ") == "2026.09.18")
        #expect(FolderNaming.folderName(day: day, title: " Trip ") == "2026.09.18 - Trip")
        #expect(FolderNaming.folderName(day: nil, title: "Trip") == "unknown - Trip")
    }

    @Test("matching folders start with the formatted date")
    func matchingFolders() {
        let folders = ["2026.09.18 - Trip", "2026.09.18", "2026.09.19 - Other", "Misc"]
        #expect(FolderNaming.folders(folders, matching: day) == ["2026.09.18 - Trip", "2026.09.18"])
        #expect(FolderNaming.preselectedFolder(in: folders, for: day) == "2026.09.18 - Trip")
        #expect(FolderNaming.preselectedFolder(in: ["Misc"], for: day) == nil)
    }

    @Test("existing folders skip system and dot folders")
    func existingFolders() throws {
        let root = try TempDirectory()
        let fm = FileManager.default
        for name in ["2026.09.18 - Trip", "@eaDir", ".hidden", "Misc"] {
            try fm.createDirectory(at: root.url.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try "x".write(to: root.url.appendingPathComponent("file.jpg"), atomically: true, encoding: .utf8)
        #expect(FolderNaming.existingFolders(at: root.url) == ["2026.09.18 - Trip", "Misc"])
    }

    @Test("camera subfolders switch turns on when an existing folder has a camera subfolder")
    func autoCheckCameraSubfolder() throws {
        let root = try TempDirectory()
        let folder = root.url.appendingPathComponent("2026.09.18 - Trip")
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("SONY ILCE-7M4"),
            withIntermediateDirectories: true
        )
        let files = [
            MediaFile(name: "a.jpg", url: URL(fileURLWithPath: "/card/a.jpg"), relativePath: "a.jpg", size: 1, camera: "SONY ILCE-7M4", isMedia: true)
        ]
        #expect(FolderNaming.autoCheckCameraSubfolder(files: files, selectedExistingFolders: [folder]))

        let otherCamera = [
            MediaFile(name: "a.jpg", url: URL(fileURLWithPath: "/card/a.jpg"), relativePath: "a.jpg", size: 1, camera: "Canon EOS R5", isMedia: true)
        ]
        #expect(!FolderNaming.autoCheckCameraSubfolder(files: otherCamera, selectedExistingFolders: [folder]))
        #expect(!FolderNaming.autoCheckCameraSubfolder(files: [], selectedExistingFolders: [folder]))
    }
}

@Suite("Day grouping")
struct DayGroupingTests {
    private func file(_ name: String, capture: String?) -> MediaFile {
        MediaFile(
            name: name,
            url: URL(fileURLWithPath: "/card/\(name)"),
            relativePath: name,
            size: 1,
            modificationDate: nil,
            captureDate: capture.flatMap(DateParsing.parseFlexible),
            camera: nil,
            isMedia: true
        )
    }

    @Test("groups by local capture day, oldest first, undated last")
    func grouping() {
        let files = [
            file("late.jpg", capture: "2026-09-18 22:30:00"),
            file("early.jpg", capture: "2026-09-18 06:00:00"),
            file("other.jpg", capture: "2026-09-17 12:00:00"),
            file("none.jpg", capture: nil),
        ]
        let groups = DayGrouping.group(files)
        #expect(groups.map(\.id) == ["2026-09-17", "2026-09-18", "unknown"])
        #expect(groups[1].files.map(\.name) == ["early.jpg", "late.jpg"])
        #expect(groups[2].day == nil)
    }

    @Test("camera grouping keeps first-seen order and falls back to Unknown")
    func cameraGrouping() {
        var a = file("a.jpg", capture: nil)
        a.camera = "Canon EOS R5"
        let b = file("b.jpg", capture: nil)
        var c = file("c.jpg", capture: nil)
        c.camera = "Canon EOS R5"
        let grouped = DayGrouping.groupByCamera([a, b, c])
        #expect(grouped.map(\.camera) == ["Canon EOS R5", "Unknown"])
        #expect(grouped[0].files.map(\.name) == ["a.jpg", "c.jpg"])
        #expect(grouped[1].files.map(\.name) == ["b.jpg"])
    }
}
