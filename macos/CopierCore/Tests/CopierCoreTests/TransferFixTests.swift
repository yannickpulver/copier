import Foundation
import Testing

@testable import CopierCore

@Suite("TransferService fixes")
struct TransferServiceFixTests {
    private func makeSource(_ directory: URL, name: String, contents: String) throws -> MediaFile {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return MediaFile(
            name: name,
            url: url,
            relativePath: name,
            size: Int64(contents.utf8.count),
            isMedia: true
        )
    }

    @Test("free space is resolved once per destination folder, not once per file")
    func freeSpaceResolvedPerFolder() throws {
        final class CountingProvider: FreeSpaceProviding, @unchecked Sendable {
            private let lock = NSLock()
            private(set) var identifierCalls = 0
            private(set) var freeCalls = 0

            func volumeIdentifier(for url: URL) -> String {
                lock.lock()
                identifierCalls += 1
                lock.unlock()
                return "one"
            }

            func freeBytes(at url: URL) -> Int64 {
                lock.lock()
                freeCalls += 1
                lock.unlock()
                return 1_000_000
            }
        }

        let provider = CountingProvider()
        let folderA = URL(fileURLWithPath: "/dest/A")
        let folderB = URL(fileURLWithPath: "/dest/B")
        let jobs = (0..<50).map { index in
            CopyJob(
                file: MediaFile(
                    name: "f\(index)",
                    url: URL(fileURLWithPath: "/card/f\(index)"),
                    relativePath: "f\(index)",
                    size: 10,
                    isMedia: true
                ),
                destinationFolder: index.isMultiple(of: 2) ? folderA : folderB
            )
        }

        #expect(TransferService(freeSpace: provider).checkFreeSpace(jobs: jobs) == nil)
        #expect(provider.identifierCalls == 2)
        #expect(provider.freeCalls == 1)
    }

    @Test("an existing destination file is replaced atomically")
    func replacesExistingDestination() async throws {
        let root = try TempDirectory()
        let source = root.url.appendingPathComponent("card")
        let destination = root.url.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let file = try makeSource(source, name: "a.jpg", contents: "new contents")
        let target = destination.appendingPathComponent("a.jpg")
        try "old contents".write(to: target, atomically: true, encoding: .utf8)

        try await TransferService.copyOne(from: file.url, to: target)

        #expect(try String(contentsOf: target, encoding: .utf8) == "new contents")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(remaining == ["a.jpg"])
    }

    @Test("cancelled files are not counted as done and their folder never flips to done")
    func cancelledFilesAreNotCounted() async throws {
        let root = try TempDirectory()
        let source = root.url.appendingPathComponent("card")
        let destination = root.url.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let big = String(repeating: "x", count: 24 * 1024 * 1024)
        var jobs: [CopyJob] = []
        for index in 0..<6 {
            let file = try makeSource(source, name: "big\(index).bin", contents: big)
            jobs.append(CopyJob(file: file, destinationFolder: destination))
        }

        let collector = ProgressCollector()
        let service = TransferService()
        let box = CopyCancelBox()
        let task = Task {
            await service.copy(
                jobs: jobs,
                progress: { progress in
                    collector.append(progress)
                    if progress.bytesDone > 0 { box.cancel() }
                }
            )
        }
        box.set(task)
        let result = await task.value

        #expect(result.cancelled)
        let last = try #require(collector.last)
        #expect(last.filesDone < last.filesTotal)
        #expect(last.folders.allSatisfy { $0.state != .done })
    }

    @Test("progress and result folders use the planned day folder, not the camera subfolder")
    func cameraSubfoldersReportTheDayFolder() async throws {
        let root = try TempDirectory()
        let source = root.url.appendingPathComponent("card")
        let dayFolder = root.url.appendingPathComponent("dest/2026.09.18 - Trip")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        var sony = try makeSource(source, name: "a.jpg", contents: "a")
        sony.camera = "Sony A7 IV"
        var dji = try makeSource(source, name: "b.jpg", contents: "b")
        dji.camera = "DJI Osmo"

        let jobs = [
            CopyJob(
                file: sony,
                destinationFolder: dayFolder.appendingPathComponent("Sony A7 IV"),
                plannedFolder: dayFolder
            ),
            CopyJob(
                file: dji,
                destinationFolder: dayFolder.appendingPathComponent("DJI Osmo"),
                plannedFolder: dayFolder
            ),
        ]

        let collector = ProgressCollector()
        let result = await TransferService().copy(jobs: jobs, progress: { collector.append($0) })

        #expect(result.failures.isEmpty)
        #expect(result.folders == [dayFolder])
        let last = try #require(collector.last)
        #expect(last.folders.map(\.url) == [dayFolder])
        #expect(last.folders[0].filesTotal == 2)
        #expect(last.folders[0].state == .done)
        // The bytes still land in the camera subfolders.
        #expect(
            FileManager.default.fileExists(
                atPath: dayFolder.appendingPathComponent("Sony A7 IV/a.jpg").path
            )
        )
    }

    @Test("byte accounting survives files that share a name across folders")
    func perJobByteAccounting() async throws {
        let root = try TempDirectory()
        let source = root.url.appendingPathComponent("card")
        let sub = source.appendingPathComponent("sub")
        let destinationA = root.url.appendingPathComponent("dest/A")
        let destinationB = root.url.appendingPathComponent("dest/B")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let one = try makeSource(source, name: "same.jpg", contents: "12345")
        let two = try makeSource(sub, name: "same.jpg", contents: "678")

        let collector = ProgressCollector()
        let result = await TransferService().copy(
            jobs: [
                CopyJob(file: one, destinationFolder: destinationA),
                CopyJob(file: two, destinationFolder: destinationB),
            ],
            progress: { collector.append($0) }
        )

        #expect(result.failures.isEmpty)
        let last = try #require(collector.last)
        #expect(last.bytesDone == 8)
        #expect(last.bytesTotal == 8)
        #expect(last.filesDone == 2)
    }

    @Test("progress callbacks are rate-limited but always report the final state")
    func progressIsRateLimited() async throws {
        let root = try TempDirectory()
        let source = root.url.appendingPathComponent("card")
        let destination = root.url.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        // 40 MB in one file: ten 4 MB chunks that would each have emitted before.
        let file = try makeSource(source, name: "big.bin", contents: String(repeating: "x", count: 40 * 1024 * 1024))
        let collector = ProgressCollector()
        let result = await TransferService().copy(
            jobs: [CopyJob(file: file, destinationFolder: destination)],
            progress: { collector.append($0) }
        )

        #expect(result.failures.isEmpty)
        // start + finish + final, plus at most a handful of throttled byte updates.
        #expect(collector.count <= 8)
        let last = try #require(collector.last)
        #expect(last.filesDone == 1)
        #expect(last.bytesDone == last.bytesTotal)
        #expect(last.folders.first?.state == .done)
    }
}

@Suite("FolderSync.copy cancellation")
struct FolderSyncCopyCancellationTests {
    @Test("a cancelled copy reports what actually landed")
    func cancelledCopyReportsRealNumbers() async throws {
        let root = try TempDirectory()
        let source = root.url.appendingPathComponent("src")
        let destination = root.url.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        var files: [SyncFile] = []
        for index in 0..<5 {
            let url = source.appendingPathComponent("f\(index).jpg")
            try "contents \(index)".write(to: url, atomically: true, encoding: .utf8)
            files.append(
                SyncFile(
                    relativePath: "f\(index).jpg",
                    url: url,
                    name: "f\(index).jpg",
                    size: Int64("contents \(index)".utf8.count)
                )
            )
        }

        let toCopy = files
        let task = Task { await FolderSync.copy(files: toCopy, destinationRoot: destination) }
        task.cancel()
        let result = await task.value

        #expect(result.cancelled)
        #expect(result.copied < toCopy.count)
        #expect(result.failures.isEmpty)
    }

    @Test("a complete copy reports every file as copied")
    func completeCopyReportsAll() async throws {
        let root = try TempDirectory()
        let source = root.url.appendingPathComponent("src")
        let destination = root.url.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let url = source.appendingPathComponent("a.jpg")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        let file = SyncFile(relativePath: "a.jpg", url: url, name: "a.jpg", size: 5)

        let result = await FolderSync.copy(files: [file], destinationRoot: destination)
        #expect(result.copied == 1)
        #expect(result.cancelled == false)
        #expect(result.failures.isEmpty)
    }
}
