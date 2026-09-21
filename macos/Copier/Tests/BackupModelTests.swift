import CopierCore
import Foundation
import Testing

// MARK: - Fixtures

/// No real volume ever qualifies, so only the injected fixture card shows up.
private struct NoDisks: DiskInfoProviding {
    func diskInfo(forMountPath path: String) async -> DiskInfo? { nil }
}

/// A destination volume with a fixed amount of room.
private struct FakeFreeSpace: FreeSpaceProviding {
    var free: Int64
    func volumeIdentifier(for url: URL) -> String { "fake" }
    func freeBytes(at url: URL) -> Int64 { free }
}

/// A transfer that starts and then waits to be released, so a test can observe the
/// copying phase without moving real bytes.
private final class GatedTransfer: FileTransferring, @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var running = false

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func release() {
        lock.lock()
        released = true
        lock.unlock()
    }

    private var isReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return released
    }

    private func setRunning(_ value: Bool) {
        lock.lock()
        running = value
        lock.unlock()
    }

    func checkFreeSpace(jobs: [CopyJob]) -> SpaceShortfall? { nil }

    func copy(jobs: [CopyJob], progress: (@Sendable (CopyProgress) -> Void)?) async -> TransferResult {
        setRunning(true)
        while !isReleased, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }
        setRunning(false)
        var folders: [URL] = []
        for job in jobs where !folders.contains(job.plannedFolder) { folders.append(job.plannedFolder) }
        return TransferResult(failures: [], cancelled: Task.isCancelled, folders: folders)
    }
}

/// An index source that reports everything it was given as already backed up.
private struct EverythingBackedUp: BackupIndexSource {
    let name = "Fake NAS"
    let kind = SourceKind.local
    let isFallbackOnly = false
    let folder: URL

    func index(
        targetKeys: Set<FileKey>,
        progress: (@Sendable (ScanProgress) -> Void)?
    ) async throws -> LocationIndex {
        var index = LocationIndex()
        for key in targetKeys { index.add(key, folder: folder) }
        return index
    }
}

/// Reports only the named files as already backed up.
private struct FilesBackedUp: BackupIndexSource {
    let name = "Fake NAS"
    let kind = SourceKind.local
    let isFallbackOnly = false
    let folder: URL
    let names: Set<String>

    init(folder: URL, names: [String]) {
        self.folder = folder
        self.names = Set(names)
    }

    func index(
        targetKeys: Set<FileKey>,
        progress: (@Sendable (ScanProgress) -> Void)?
    ) async throws -> LocationIndex {
        var index = LocationIndex()
        for key in targetKeys where names.contains(key.name) {
            index.add(key, folder: folder)
        }
        return index
    }
}

/// A throwaway temp tree: a card with dated files plus an empty destination.
private struct Fixture {
    let root: URL
    let card: URL
    let destination: URL

    init(days: [(day: String, files: [(name: String, size: Int)])]) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("copier-tests-\(UUID().uuidString)")
        card = root.appendingPathComponent("card")
        destination = root.appendingPathComponent("destination")
        let dcim = card.appendingPathComponent("DCIM/100TEST")
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = .current

        for group in days {
            for (offset, file) in group.files.enumerated() {
                let url = dcim.appendingPathComponent(file.name)
                let data = Data(repeating: UInt8(offset % 251), count: file.size)
                try data.write(to: url)
                if let date = formatter.date(from: "\(group.day) 10:0\(offset % 10)") {
                    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
                }
            }
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func makeModel(
    _ fixture: Fixture,
    sources: [any BackupIndexSource] = [],
    freeBytes: Int64 = 1 << 40,
    transfer: (any FileTransferring)? = nil
) -> BackupModel {
    let suite = UserDefaults(suiteName: "copier-tests-\(UUID().uuidString)")!
    let settings = SettingsStore(defaults: suite)
    settings.selectedDestination = fixture.destination.path
    let model = BackupModel(
        dependencies: BackupDependencies(
            volumes: VolumeLister(diskInfo: NoDisks(), fixtureCard: fixture.card),
            settings: settings,
            transfer: transfer ?? TransferService(freeSpace: FakeFreeSpace(free: freeBytes)),
            sources: { _ in sources },
            freeSpace: FakeFreeSpace(free: freeBytes),
            eject: { _ in }
        )
    )
    return model
}

/// Wait until the model leaves the scanning phase (or the copy finishes).
@MainActor
private func wait(for model: BackupModel, until condition: @MainActor (BackupModel) -> Bool) async throws {
    for _ in 0..<600 {
        if condition(model) { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Timed out waiting for the model")
}

@MainActor
private func isReview(_ model: BackupModel) -> Bool {
    if case .review = model.phase { return true }
    return false
}

@MainActor
private func isReady(_ model: BackupModel) -> Bool {
    if case .ready = model.phase { return true }
    return false
}

@MainActor
private func isDone(_ model: BackupModel) -> Bool {
    if case .done = model.phase { return true }
    return false
}

// MARK: - Tests

@MainActor
@Suite("BackupModel")
struct BackupModelTests {
    private static let twoDays: [(day: String, files: [(name: String, size: Int)])] = [
        ("2026-09-18", [("IMG_0001.JPG", 1000), ("IMG_0002.JPG", 2000), ("NOTES.TXT", 10)]),
        ("2026-09-19", [("IMG_0003.JPG", 3000), ("IMG_0004.JPG", 4000)]),
    ]

    @Test("A card that appears is scanned and lands on review")
    func scanReachesReview() async throws {
        let fixture = try Fixture(days: Self.twoDays)
        defer { fixture.remove() }
        let model = makeModel(fixture)

        #expect(isReview(model) == false)
        await model.refreshCards()
        #expect(model.cards.count == 1)
        // A card that appears is offered, not scanned.
        #expect(isReady(model))
        #expect(model.scan == nil)
        #expect(model.days.isEmpty)

        model.startScan()
        try await wait(for: model, until: isReview)

        #expect(model.days.count == 2)
        // Four media files are new, the .TXT is listed as "other" and stays unticked.
        #expect(model.tickedCount == 4)
        #expect(model.tickedBytes == 10000)
        #expect(model.days.flatMap(\.files).contains { $0.reason == .other })
    }

    @Test("Ticking files and days changes the count and the total")
    func tickingChangesTotals() async throws {
        let fixture = try Fixture(days: Self.twoDays)
        defer { fixture.remove() }
        let model = makeModel(fixture)
        await model.refreshCards()
        model.startScan()
        try await wait(for: model, until: isReview)

        let firstDay = model.days[0]
        model.setTicked(day: firstDay, false)
        #expect(model.tickedCount == 2)
        #expect(model.tickedBytes == 7000)
        #expect(model.isTicked(day: firstDay) == false)

        // The "other" file can be included by hand.
        let other = try #require(model.days.flatMap(\.files).first { $0.reason == .other })
        model.setTicked(other, true)
        #expect(model.tickedCount == 3)
        #expect(model.tickedBytes == 7010)

        model.setTicked(day: firstDay, true)
        #expect(model.tickedCount == 5)
    }

    @Test("Folder targets drive the plan")
    func folderTargetsDrivePlan() async throws {
        let fixture = try Fixture(days: Self.twoDays)
        defer { fixture.remove() }
        let model = makeModel(fixture)
        await model.refreshCards()
        model.startScan()
        try await wait(for: model, until: isReview)

        model.setTitle("Wedding", for: model.days[0])
        let existing = fixture.destination.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        model.setExistingFolder(existing, for: model.days[1])

        let plan = model.plan
        #expect(plan.folders.count == 2)
        #expect(plan.folders[0].url.lastPathComponent == "2026.09.18 - Wedding")
        #expect(plan.folders[0].isNew)
        #expect(plan.folders[1].url == existing)
        #expect(plan.folders[1].isNew == false)
        #expect(plan.fileCount == 4)
        #expect(plan.totalBytes == 10000)
    }

    @Test("One folder puts everything into the first day's folder")
    func oneFolderStructure() async throws {
        let fixture = try Fixture(days: Self.twoDays)
        defer { fixture.remove() }
        let model = makeModel(fixture)
        await model.refreshCards()
        model.startScan()
        try await wait(for: model, until: isReview)

        model.structure = .oneFolder
        model.setTitle("Trip", for: model.days[0])

        let plan = model.plan
        #expect(plan.folders.count == 1)
        #expect(plan.folders[0].url.lastPathComponent == "2026.09.18 - Trip")
        #expect(plan.fileCount == 4)

        // Days are still listed so files can be ticked off.
        #expect(model.days.count == 2)
        model.setTicked(day: model.days[1], false)
        #expect(model.plan.fileCount == 2)
    }

    @Test("Camera subfolders split the jobs per camera folder")
    func cameraSubfolders() async throws {
        let fixture = try Fixture(days: Self.twoDays)
        defer { fixture.remove() }
        let model = makeModel(fixture)
        await model.refreshCards()
        model.startScan()
        try await wait(for: model, until: isReview)

        model.cameraSubfolders = true
        let plan = model.plan
        #expect(plan.jobs.allSatisfy { $0.destinationFolder.lastPathComponent == "Unknown" })
    }

    @Test("A destination without room blocks the backup")
    func insufficientSpaceBlocks() async throws {
        let fixture = try Fixture(days: Self.twoDays)
        defer { fixture.remove() }
        let model = makeModel(fixture, freeBytes: 500)
        await model.refreshCards()
        model.startScan()
        try await wait(for: model, until: isReview)

        model.startBackup()
        try await wait(for: model, until: { $0.shortfall != nil })
        let shortfall = try #require(model.shortfall)
        #expect(shortfall.requiredBytes == 10000)
        #expect(shortfall.shortfallBytes == 9500)
        #expect(isReview(model))
    }

    @Test("A card that is fully backed up shows the empty state but stays reviewable")
    func allBackedUp() async throws {
        let fixture = try Fixture(days: Self.twoDays)
        defer { fixture.remove() }
        let model = makeModel(fixture, sources: [EverythingBackedUp(folder: fixture.destination)])
        await model.refreshCards()
        model.startScan()
        try await wait(for: model, until: isReview)

        #expect(model.allBackedUp)
        #expect(model.tickedCount == 0)
        #expect(model.days.flatMap(\.files).allSatisfy { $0.reason != .new })
        #expect(model.reviewSubtitle.contains("backed up"))
    }

    @Test("A backup copies the ticked files and finishes")
    func backupCopiesFiles() async throws {
        let fixture = try Fixture(days: Self.twoDays)
        defer { fixture.remove() }
        let model = makeModel(fixture)
        await model.refreshCards()
        model.startScan()
        try await wait(for: model, until: isReview)

        model.setTitle("Wedding", for: model.days[0])
        model.startBackup()
        try await wait(for: model, until: isDone)

        let result = try #require(model.result)
        #expect(result.failures.isEmpty)
        #expect(result.folders.count == 2)
        let copied = fixture.destination.appendingPathComponent("2026.09.18 - Wedding/IMG_0001.JPG")
        #expect(FileManager.default.fileExists(atPath: copied.path))
    }

    @Test("Pulling the card during a backup fails the run")
    func cardRemovedDuringCopy() async throws {
        let fixture = try Fixture(days: Self.twoDays)
        defer { fixture.remove() }
        let transfer = GatedTransfer()
        let model = makeModel(fixture, transfer: transfer)
        await model.refreshCards()
        model.startScan()
        try await wait(for: model, until: isReview)

        model.startBackup()
        try await wait(for: model, until: { $0.isCopying })
        model.volumeUnmounted(fixture.card)

        if case let .failed(error) = model.phase {
            #expect(error == .cardRemoved(volume: fixture.card))
        } else {
            Issue.record("Expected the failed phase, got \(model.phase)")
        }
    }

    @Test("A folder with the same date is preselected as an existing target")
    func preselectsSameDayFolder() async throws {
        let fixture = try Fixture(days: Self.twoDays)
        defer { fixture.remove() }
        let existing = fixture.destination.appendingPathComponent("2026.09.18 - Already there")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)

        let model = makeModel(fixture)
        await model.refreshCards()
        model.startScan()
        try await wait(for: model, until: isReview)

        #expect(model.target(for: model.days[0]) == .existing(existing))
        #expect(model.target(for: model.days[1]) == .new(title: ""))
        #expect(model.folderChoices(for: model.days[0]).first == "2026.09.18 - Already there")
    }

    @Test("a check path that is not mounted is reported instead of silently skipped")
    func unreachableCheckPathIsReported() async throws {
        let fixture = try Fixture(days: Self.twoDays)
        defer { fixture.remove() }
        let missing = CheckPath(path: fixture.root.appendingPathComponent("not-mounted").path)
        let model = makeModel(fixture, sources: [LocalPathSource(missing)])
        await model.refreshCards()
        model.startScan()
        try await wait(for: model, until: isReview)

        #expect(model.failedSources.count == 1)
        #expect(model.failedSources[0].succeeded == false)
        // Everything still counts as new, but the banner explains why.
        #expect(model.tickedCount == 4)
    }

    @Test("cards cannot be switched while a backup is running")
    func cardSelectionRefusedDuringCopy() async throws {
        let fixture = try Fixture(days: Self.twoDays)
        defer { fixture.remove() }
        let transfer = GatedTransfer()
        let model = makeModel(fixture, transfer: transfer)
        await model.refreshCards()
        model.startScan()
        try await wait(for: model, until: isReview)

        let card = try #require(model.selectedCard)
        model.startBackup()
        try await wait(for: model, until: { $0.isCopying })

        let other = RemovableVolume(name: "Other", url: fixture.root.appendingPathComponent("other"))
        model.select(other)
        #expect(model.selectedCard?.url == card.url)
        #expect(model.isCopying)

        transfer.release()
        try await wait(for: model, until: isDone)
        #expect(model.result?.failures.isEmpty == true)
    }

    @Test("camera subfolders still report the day folder on the done screen")
    func doneScreenShowsDayFolder() async throws {
        let fixture = try Fixture(days: Self.twoDays)
        defer { fixture.remove() }
        let model = makeModel(fixture)
        await model.refreshCards()
        model.startScan()
        try await wait(for: model, until: isReview)

        model.cameraSubfolders = true
        model.setTitle("Wedding", for: model.days[0])
        model.setTitle("Brunch", for: model.days[1])
        model.startBackup()
        try await wait(for: model, until: isDone)

        let folders = try #require(model.result?.folders)
        #expect(folders.map(\.lastPathComponent) == ["2026.09.18 - Wedding", "2026.09.19 - Brunch"])
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.destination.appendingPathComponent("2026.09.18 - Wedding/Unknown/IMG_0001.JPG").path
            )
        )
    }

    @Test("inserting a card never starts a scan on its own")
    func insertingACardDoesNotScan() async throws {
        let fixture = try Fixture(days: Self.twoDays)
        defer { fixture.remove() }
        let model = makeModel(fixture)
        await model.refreshCards()

        #expect(isReady(model))
        #expect(model.canScan)
        // Give an accidental auto-scan time to show up.
        try await Task.sleep(for: .milliseconds(120))
        #expect(isReady(model))
        #expect(model.scan == nil)
    }

    @Test("a deselected location is skipped by the next scan")
    func disabledLocationIsSkipped() async throws {
        let fixture = try Fixture(days: Self.twoDays)
        defer { fixture.remove() }
        let library = fixture.root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = EverythingBackedUp(folder: library)

        let model = makeModel(fixture, sources: [source])
        await model.refreshCards()
        model.startScan()
        try await wait(for: model, until: isReview)
        #expect(model.tickedCount == 0) // everything was found in the source

        let location = LocationStatus(
            sourceName: source.name,
            displayName: source.name,
            detail: library.path,
            isNAS: false,
            isFallback: false,
            reachable: true
        )
        model.toggleLocation(location)
        #expect(model.isDisabled(location))

        model.startScan()
        try await wait(for: model, until: { model in
            if case .review = model.phase { return model.tickedCount > 0 }
            return false
        })
        #expect(model.scan?.sources.isEmpty == true)
        #expect(model.tickedCount == 4) // nothing was checked, so everything is new
    }

    @Test("after a failure the card goes back to ready, not straight into a scan")
    func retryReturnsToReady() async throws {
        let fixture = try Fixture(days: Self.twoDays)
        defer { fixture.remove() }
        let transfer = GatedTransfer()
        let model = makeModel(fixture, transfer: transfer)
        await model.refreshCards()
        model.startScan()
        try await wait(for: model, until: isReview)

        model.startBackup()
        try await wait(for: model, until: { $0.isCopying })
        model.volumeUnmounted(fixture.card)
        await model.refreshCards()
        model.retry()

        #expect(isReady(model))
        #expect(model.scan == nil)
    }

    @Test("days with nothing new are sorted into a second block, collapsed and unticked")
    func backedUpDaysSortLast() async throws {
        let fixture = try Fixture(days: Self.twoDays)
        defer { fixture.remove() }
        // The 18th is already on the "NAS", the 19th is not.
        let library = fixture.root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = FilesBackedUp(folder: library, names: ["IMG_0001.JPG", "IMG_0002.JPG"])

        let model = makeModel(fixture, sources: [source])
        await model.refreshCards()
        model.startScan()
        try await wait(for: model, until: isReview)

        #expect(model.days.map(\.id) == ["2026-09-18", "2026-09-19"])
        // Active day first, settled day after it.
        #expect(model.orderedDays.map(\.id) == ["2026-09-19", "2026-09-18"])
        #expect(model.isBackedUpOnly(model.days[0]))
        #expect(model.isBackedUpOnly(model.days[1]) == false)
        #expect(model.expandedDayID == "2026-09-19")

        let settled = try #require(model.orderedDays.last)
        #expect(settled.backedUpNote == "All 2 files backed up · 1 other")

        // Ticking a file in a settled day moves it back into the first block.
        let file = try #require(settled.files.first { $0.reason == .backedUp })
        model.setTicked(file, true)
        #expect(model.orderedDays.map(\.id) == ["2026-09-18", "2026-09-19"])
        #expect(model.isBackedUpOnly(settled) == false)
    }

    @Test("a volume that holds a check location or destination is not a card")
    func configuredVolumesAreNotCards() async throws {
        let volume = RemovableVolume(name: "YANU-SSD-1", url: URL(fileURLWithPath: "/Volumes/YANU-SSD-1"))
        let other = RemovableVolume(name: "SONY_A7IV", url: URL(fileURLWithPath: "/Volumes/SONY_A7IV"))

        // Exact match, a folder inside it, and a trailing slash all disqualify it.
        #expect(BackupModel.isCard(volume, excluding: ["/Volumes/YANU-SSD-1"]) == false)
        #expect(BackupModel.isCard(volume, excluding: ["/Volumes/YANU-SSD-1/Photos/2026"]) == false)
        #expect(BackupModel.isCard(volume, excluding: ["/Volumes/YANU-SSD-1/"]) == false)
        // A different volume, and a similarly named one, stay cards.
        #expect(BackupModel.isCard(other, excluding: ["/Volumes/YANU-SSD-1/Photos"]))
        #expect(BackupModel.isCard(volume, excluding: ["/Volumes/YANU-SSD-10/Photos"]))
        #expect(BackupModel.isCard(other, excluding: []))
    }

    @Test("adding the card's volume as a check path removes it from the card list")
    func configuredCardDisappears() async throws {
        let fixture = try Fixture(days: Self.twoDays)
        defer { fixture.remove() }
        let model = makeModel(fixture)
        await model.refreshCards()
        #expect(model.cards.count == 1)
        #expect(isReady(model))

        // The user makes the card's own folder a destination.
        model.dependencies.settings.transferDestinations = [fixture.card.appendingPathComponent("DCIM").path]
        await model.refreshCards()

        #expect(model.cards.isEmpty)
        #expect(model.selectedCard == nil)
        if case .waiting = model.phase {} else { Issue.record("expected waiting, got \(model.phase)") }
    }
}
