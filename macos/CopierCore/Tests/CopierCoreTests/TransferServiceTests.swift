import Foundation
import Testing
@testable import CopierCore

@Suite("TransferService")
struct TransferServiceTests {
    private func makeSource(_ directory: URL, name: String, contents: String) throws -> MediaFile {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
            ofItemAtPath: url.path
        )
        return MediaFile(
            name: name,
            url: url,
            relativePath: name,
            size: Int64(contents.utf8.count),
            modificationDate: Date(timeIntervalSince1970: 1_600_000_000),
            isMedia: true
        )
    }

    @Test("happy path: copies, verifies, preserves mtime and reports progress")
    func happyPath() async throws {
        let root = try TempDirectory()
        let source = root.url.appendingPathComponent("card")
        let destination = root.url.appendingPathComponent("dest/2026.09.18 - Trip")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let a = try makeSource(source, name: "a.jpg", contents: "hello")
        let b = try makeSource(source, name: "b.jpg", contents: "world!")

        let collector = ProgressCollector()
        let result = await TransferService().copy(
            jobs: [CopyJob(file: a, destinationFolder: destination), CopyJob(file: b, destinationFolder: destination)],
            progress: { progress in collector.append(progress) }
        )

        #expect(result.failures.isEmpty)
        #expect(result.cancelled == false)
        #expect(result.folders == [destination])
        #expect(try String(contentsOf: destination.appendingPathComponent("a.jpg"), encoding: .utf8) == "hello")
        #expect(try String(contentsOf: destination.appendingPathComponent("b.jpg"), encoding: .utf8) == "world!")

        let copiedDate = try FileManager.default
            .attributesOfItem(atPath: destination.appendingPathComponent("a.jpg").path)[.modificationDate] as? Date
        #expect(copiedDate?.timeIntervalSince1970 == 1_600_000_000)

        let last = collector.last
        #expect(last?.filesDone == 2)
        #expect(last?.filesTotal == 2)
        #expect(last?.bytesDone == 11)
        #expect(last?.bytesTotal == 11)
        #expect(last?.folders.first?.state == .done)
    }

    @Test("name conflicts get _1, _2 suffixes")
    func conflictSuffix() async throws {
        let root = try TempDirectory()
        let source = root.url.appendingPathComponent("card")
        let destination = root.url.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "existing".write(to: destination.appendingPathComponent("a.jpg"), atomically: true, encoding: .utf8)

        let one = try makeSource(source, name: "a.jpg", contents: "one")
        let sub = source.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        var two = try makeSource(sub, name: "a.jpg", contents: "two")
        two.name = "a.jpg"

        let result = await TransferService().copy(jobs: [
            CopyJob(file: one, destinationFolder: destination),
            CopyJob(file: two, destinationFolder: destination),
        ])
        #expect(result.failures.isEmpty)
        #expect(try String(contentsOf: destination.appendingPathComponent("a.jpg"), encoding: .utf8) == "existing")
        #expect(try String(contentsOf: destination.appendingPathComponent("a_1.jpg"), encoding: .utf8) == "one")
        #expect(try String(contentsOf: destination.appendingPathComponent("a_2.jpg"), encoding: .utf8) == "two")
    }

    @Test("stale partial files are deleted before copying")
    func staleParticleCleanup() async throws {
        let root = try TempDirectory()
        let source = root.url.appendingPathComponent("card")
        let destination = root.url.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let stale = destination.appendingPathComponent("old.jpg.copier-partial")
        try "truncated".write(to: stale, atomically: true, encoding: .utf8)

        let a = try makeSource(source, name: "a.jpg", contents: "hello")
        _ = await TransferService().copy(jobs: [CopyJob(file: a, destinationFolder: destination)])

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted()
        #expect(remaining == ["a.jpg"])
    }

    @Test("cancelling before the copy starts leaves no partial file")
    func cancelLeavesNoPartial() async throws {
        let root = try TempDirectory()
        let source = root.url.appendingPathComponent("card")
        let destination = root.url.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let a = try makeSource(source, name: "a.jpg", contents: String(repeating: "x", count: 1024))

        let task = Task {
            try await TransferService.copyOne(from: a.url, to: destination.appendingPathComponent("a.jpg"))
        }
        task.cancel()
        let outcome = await task.result

        if case let .failure(error) = outcome {
            #expect(error as? BackupError == BackupError.cancelled)
        }
        let contents = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(contents.filter { $0.hasSuffix(TransferService.partialSuffix) }.isEmpty)
    }

    @Test("cancelling mid-transfer stops and leaves no partial files")
    func cancelMidTransfer() async throws {
        let root = try TempDirectory()
        let source = root.url.appendingPathComponent("card")
        let destination = root.url.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        // 24 MB: six 4 MB chunks per file, so cancellation lands between chunks.
        let big = String(repeating: "x", count: 24 * 1024 * 1024)
        var jobs: [CopyJob] = []
        for index in 0..<6 {
            let file = try makeSource(source, name: "big\(index).bin", contents: big)
            jobs.append(CopyJob(file: file, destinationFolder: destination))
        }

        // Cancel as soon as the first bytes land, so the test never races the disk.
        let service = TransferService()
        let box = CopyCancelBox()
        let task = Task { await service.copy(jobs: jobs, progress: { if $0.bytesDone > 0 { box.cancel() } }) }
        box.set(task)
        let result = await task.value

        #expect(result.cancelled)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
        #expect(contents.filter { $0.hasSuffix(TransferService.partialSuffix) }.isEmpty)
    }

    @Test("size mismatch is reported as a verification failure")
    func verificationFailure() async throws {
        let root = try TempDirectory()
        let missing = root.url.appendingPathComponent("gone.jpg")
        let file = MediaFile(name: "gone.jpg", url: missing, relativePath: "gone.jpg", size: 10, isMedia: true)
        let destination = root.url.appendingPathComponent("dest")
        let result = await TransferService().copy(jobs: [CopyJob(file: file, destinationFolder: destination)])
        #expect(result.failures.count == 1)
        #expect(result.failures[0].file == "gone.jpg")
    }

    @Test("free-space preflight groups by device and reports the shortfall")
    func freeSpaceShortfall() {
        struct Provider: FreeSpaceProviding {
            var free: [String: Int64]
            func volumeIdentifier(for url: URL) -> String {
                url.path.hasPrefix("/Volumes/SSD") ? "ssd" : "nas"
            }
            func freeBytes(at url: URL) -> Int64 { free[volumeIdentifier(for: url)] ?? 0 }
        }

        let ssdOne = URL(fileURLWithPath: "/Volumes/SSD/A")
        let ssdTwo = URL(fileURLWithPath: "/Volumes/SSD/B")
        func job(_ folder: URL, _ size: Int64) -> CopyJob {
            CopyJob(
                file: MediaFile(name: "f", url: URL(fileURLWithPath: "/card/f"), relativePath: "f", size: size, isMedia: true),
                destinationFolder: folder
            )
        }

        let jobs = [job(ssdOne, 60), job(ssdTwo, 60)]
        let tight = TransferService(freeSpace: Provider(free: ["ssd": 100]))
        let shortfall = tight.checkFreeSpace(jobs: jobs)
        #expect(shortfall?.requiredBytes == 120)
        #expect(shortfall?.freeBytes == 100)
        #expect(shortfall?.shortfallBytes == 20)
        #expect(shortfall?.asError.shortfallBytes == 20)

        let roomy = TransferService(freeSpace: Provider(free: ["ssd": 500]))
        #expect(roomy.checkFreeSpace(jobs: jobs) == nil)
    }

    @Test("reserveName appends an index and keeps the extension")
    func reserveName() {
        var names: Set<String> = ["a.jpg"]
        #expect(TransferService.reserveName(&names, preferred: "a.jpg") == "a_1.jpg")
        #expect(TransferService.reserveName(&names, preferred: "a.jpg") == "a_2.jpg")
        #expect(TransferService.reserveName(&names, preferred: "b") == "b")
        #expect(TransferService.reserveName(&names, preferred: "b") == "b_1")
    }
}

@Suite("SpeedEstimator")
struct SpeedEstimatorTests {
    @Test("first sample sets the baseline, the second sets the rate")
    func rate() {
        var estimator = SpeedEstimator()
        estimator.update(bytesDone: 0, at: 0)
        #expect(estimator.bytesPerSecond == 0)
        estimator.update(bytesDone: 1_000_000, at: 1)
        #expect(estimator.bytesPerSecond == 1_000_000)
    }

    @Test("samples closer than the minimum interval are ignored")
    func minimumInterval() {
        var estimator = SpeedEstimator()
        estimator.update(bytesDone: 0, at: 0)
        estimator.update(bytesDone: 5_000_000, at: 0.1)
        #expect(estimator.bytesPerSecond == 0)
    }

    @Test("rate is smoothed 0.7 / 0.3")
    func smoothing() {
        var estimator = SpeedEstimator()
        estimator.update(bytesDone: 0, at: 0)
        estimator.update(bytesDone: 1_000, at: 1)
        estimator.update(bytesDone: 3_000, at: 2)
        #expect(abs(estimator.bytesPerSecond - (1_000 * 0.7 + 2_000 * 0.3)) < 0.001)
    }

    @Test("eta and formatting")
    func eta() {
        var estimator = SpeedEstimator()
        estimator.update(bytesDone: 0, at: 0)
        estimator.update(bytesDone: 1_000, at: 1)
        #expect(estimator.timeRemaining(bytesDone: 1_000, bytesTotal: 3_000) == 2)
        #expect(SpeedEstimator.formatTimeRemaining(45) == "45s")
        #expect(SpeedEstimator.formatTimeRemaining(125) == "2m 5s")
        #expect(SpeedEstimator.formatTimeRemaining(3_720) == "1h 2m")
        #expect(SpeedEstimator().timeRemaining(bytesDone: 0, bytesTotal: 10) == nil)
    }
}

/// Thread-safe collector for progress callbacks.
final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CopyProgress] = []

    func append(_ value: CopyProgress) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var last: CopyProgress? {
        lock.lock()
        defer { lock.unlock() }
        return values.last
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.count
    }
}

/// Cancels a running copy from its own progress callback, whichever side gets there first.
final class CopyCancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<TransferResult, Never>?
    private var requested = false

    func set(_ task: Task<TransferResult, Never>) {
        lock.lock()
        self.task = task
        let alreadyRequested = requested
        lock.unlock()
        if alreadyRequested { task.cancel() }
    }

    func cancel() {
        lock.lock()
        requested = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}
