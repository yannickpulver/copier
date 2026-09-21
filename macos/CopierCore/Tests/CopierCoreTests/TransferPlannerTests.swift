import Foundation
import Testing
@testable import CopierCore

@Suite("TransferPlanner")
struct TransferPlannerTests {
    let destination = URL(fileURLWithPath: "/Volumes/SSD/Photos")

    private func file(_ name: String, day: String, camera: String? = nil, size: Int64 = 10) -> MediaFile {
        MediaFile(
            name: name,
            url: URL(fileURLWithPath: "/card/\(name)"),
            relativePath: name,
            size: size,
            captureDate: DateParsing.parseFlexible("\(day) 12:00:00"),
            camera: camera,
            isMedia: true
        )
    }

    let dayOne = Day(year: 2026, month: 9, day: 17)
    let dayTwo = Day(year: 2026, month: 9, day: 18)

    @Test("folder per day, new folders")
    func folderPerDayNew() {
        let files = [file("a.jpg", day: "2026-09-17"), file("b.jpg", day: "2026-09-18")]
        let plan = TransferPlanner.plan(
            files: files,
            structure: .folderPerDay,
            targets: [dayOne: .new(title: "Trip"), dayTwo: .new(title: "")],
            destination: destination
        )
        #expect(plan.folders.map(\.url.lastPathComponent) == ["2026.09.17 - Trip", "2026.09.18"])
        #expect(plan.folders.filter(\.isNew).count == plan.folders.count)
        #expect(plan.jobs.map(\.destinationFolder.path) == [
            "/Volumes/SSD/Photos/2026.09.17 - Trip",
            "/Volumes/SSD/Photos/2026.09.18",
        ])
        #expect(plan.totalBytes == 20)
    }

    @Test("folder per day honours a custom date format")
    func customFormat() {
        let plan = TransferPlanner.plan(
            files: [file("a.jpg", day: "2026-09-17")],
            structure: .folderPerDay,
            targets: [dayOne: .new(title: "Trip")],
            destination: destination,
            dateFormat: "YY-MM-DD"
        )
        #expect(plan.folders[0].url.lastPathComponent == "26-09-17 - Trip")
    }

    @Test("existing folder target is used verbatim")
    func existingTarget() {
        let existing = URL(fileURLWithPath: "/Volumes/SSD/Photos/2026.09.17 - Old trip")
        let plan = TransferPlanner.plan(
            files: [file("a.jpg", day: "2026-09-17")],
            structure: .folderPerDay,
            targets: [dayOne: .existing(existing)],
            destination: destination
        )
        #expect(plan.folders[0].url == existing)
        #expect(plan.folders[0].isNew == false)
        #expect(plan.jobs[0].destinationFolder == existing)
    }

    @Test("one folder takes its date from the first day")
    func oneFolder() {
        let files = [file("b.jpg", day: "2026-09-18"), file("a.jpg", day: "2026-09-17")]
        let plan = TransferPlanner.plan(
            files: files,
            structure: .oneFolder,
            targets: [dayOne: .new(title: "Trip")],
            destination: destination
        )
        #expect(plan.folders.count == 1)
        #expect(plan.folders[0].url.lastPathComponent == "2026.09.17 - Trip")
        #expect(plan.jobs.count == 2)
        #expect(Set(plan.jobs.map(\.destinationFolder)).count == 1)
    }

    @Test("one folder into an existing folder")
    func oneFolderExisting() {
        let existing = URL(fileURLWithPath: "/Volumes/SSD/Photos/Everything")
        let plan = TransferPlanner.plan(
            files: [file("a.jpg", day: "2026-09-17"), file("b.jpg", day: "2026-09-18")],
            structure: .oneFolder,
            targets: [dayOne: .existing(existing)],
            destination: destination
        )
        #expect(plan.jobs.filter { $0.destinationFolder == existing }.count == plan.jobs.count)
    }

    @Test("camera subfolders nest inside the day folder")
    func cameraSubfolders() {
        let files = [
            file("a.jpg", day: "2026-09-17", camera: "Canon EOS R5"),
            file("b.mp4", day: "2026-09-17", camera: "DJI Mavic 3 Pro"),
            file("c.jpg", day: "2026-09-17"),
        ]
        let plan = TransferPlanner.plan(
            files: files,
            structure: .folderPerDay,
            targets: [dayOne: .new(title: "Trip")],
            destination: destination,
            cameraSubfolders: true
        )
        #expect(plan.folders.map(\.url.lastPathComponent) == ["2026.09.17 - Trip"])
        #expect(Set(plan.jobs.map(\.destinationFolder.path)) == [
            "/Volumes/SSD/Photos/2026.09.17 - Trip/Canon EOS R5",
            "/Volumes/SSD/Photos/2026.09.17 - Trip/DJI Mavic 3 Pro",
            "/Volumes/SSD/Photos/2026.09.17 - Trip/Unknown",
        ])
    }

    @Test("no files means no jobs")
    func empty() {
        let plan = TransferPlanner.plan(files: [], structure: .folderPerDay, targets: [:], destination: destination)
        #expect(plan.jobs.isEmpty)
        #expect(plan.folders.isEmpty)
    }
}
