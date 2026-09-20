import CopierCore
import Foundation
import Observation

// MARK: - Review data

/// Why a file is listed, and whether it is ticked by default.
enum FileReason: String, Sendable {
    /// Not found in any check location — ticked by default.
    case new
    /// Already present somewhere — listed, greyed out, unticked.
    case backedUp = "backed up"
    /// Not a media file (sidecars such as `.XML`) — listed, greyed out, unticked.
    case other
}

/// One row of the review file list.
struct ReviewFile: Identifiable, Sendable {
    var file: MediaFile
    var reason: FileReason

    var id: URL { file.url }
}

/// One day group of the review screen.
struct ReviewDay: Identifiable, Sendable {
    var day: Day?
    var files: [ReviewFile]
    /// Files broken into runs taken close together — computed once, never in `body`.
    var clusters: [FileCluster]
    /// `[(photo, 112), (video, 36)]`, for the coloured counts in the header.
    var kindCounts: [(kind: FileKind, count: Int)]

    var id: String { day?.isoString ?? "unknown" }
    /// Files that are ticked when the screen opens.
    var newFiles: [ReviewFile] { files.filter { $0.reason == .new } }

    /// Files already present in a check location.
    let backedUpCount: Int
    /// Non-media files (sidecars and the like).
    let otherCount: Int

    init(day: Day?, files: [ReviewFile]) {
        self.day = day
        self.files = files
        clusters = TimeClustering.cluster(files)
        kindCounts = TimeClustering.kindCounts(files)
        backedUpCount = files.count { $0.reason == .backedUp }
        otherCount = files.count { $0.reason == .other }
    }

    /// The note a fully backed-up day shows instead of a folder field.
    var backedUpNote: String {
        if backedUpCount > 0, otherCount > 0 {
            return "All \(backedUpCount) files backed up · \(otherCount) other"
        }
        if backedUpCount > 0 {
            return "All \(backedUpCount) file\(backedUpCount == 1 ? "" : "s") backed up"
        }
        return "\(otherCount) other file\(otherCount == 1 ? "" : "s")"
    }
}

/// A configured check location and whether it answered.
struct LocationStatus: Identifiable, Sendable, Hashable {
    /// Matches ``BackupIndexSource/name`` so a pill can switch its source off.
    var sourceName: String
    /// Short label for the pill.
    var displayName: String
    /// Full path or host — the pill's tooltip.
    var detail: String
    var isNAS: Bool
    /// Only searched when the NAS API failed.
    var isFallback: Bool
    /// `nil` while the check is still running.
    var reachable: Bool?

    var id: String { sourceName }
}

// MARK: - Dependencies

/// Everything the model reaches the outside world through. Injected so the tests can
/// run against temporary folders, a throwaway defaults suite and a fake free-space provider.
struct BackupDependencies: Sendable {
    var volumes: VolumeLister = VolumeLister()
    var settings: SettingsStore = SettingsStore()
    var transfer: any FileTransferring = TransferService()
    var scan: BackupScan = BackupScan()
    var sources: @Sendable (SettingsStore) async -> [any BackupIndexSource] = BackupDependencies.liveSources
    var freeSpace: any FreeSpaceProviding = SystemFreeSpaceProvider()
    var existingFolders: @Sendable (URL) -> [String] = { FolderNaming.existingFolders(at: $0) }
    var eject: @Sendable (URL) throws -> Void = { try VolumeLister.eject($0) }

    /// The name ``SynologySource`` reports, used to tie its pill to its source.
    static let synologySourceName = "Synology API"

    /// The Synology API source (when configured) plus every configured check path.
    static func liveSources(_ settings: SettingsStore) async -> [any BackupIndexSource] {
        var result: [any BackupIndexSource] = []
        if let config = await CredentialResolver.synologyConfig(settings: settings) {
            result.append(
                SynologySource(client: SynologyClient(config: config), folders: config.folders)
            )
        }
        result.append(contentsOf: settings.checkPaths.map(LocalPathSource.init))
        return result
    }
}

// MARK: - Model

/// The state machine behind the SD Backup screen: one phase at a time, one primary action.
@MainActor
@Observable
final class BackupModel {
    /// The screen that is showing.
    enum Phase {
        case waiting
        /// A card is here and was not scanned yet — the user picks the check
        /// locations first, then starts the scan.
        case ready
        case scanning(ScanEvent?)
        case review
        case copying
        case done
        case failed(BackupError)
    }

    // MARK: Phase

    private(set) var phase: Phase = .waiting

    // MARK: Cards

    private(set) var cards: [RemovableVolume] = []
    private(set) var selectedCard: RemovableVolume?

    // MARK: Scan

    private(set) var scan: ScanResult?
    private(set) var days: [ReviewDay] = []
    private(set) var locations: [LocationStatus] = []
    /// Locations the user switched off for the next scan. Deliberately not persisted.
    private(set) var disabledLocationNames: Set<String> = []
    /// Sources that failed during the last scan — shown as a warning banner.
    private(set) var failedSources: [SourceResult] = []

    // MARK: Review state

    var structure: Structure = .folderPerDay {
        didSet { dependencies.settings.structure = structure }
    }
    private(set) var ticked: Set<URL> = []
    /// `days`, but with the days that hold nothing to back up moved to the end.
    /// Rebuilt when the scan lands and whenever ticks change — never in a view body.
    private(set) var orderedDays: [ReviewDay] = []
    private(set) var backedUpOnlyDayIDs: Set<String> = []
    var expandedDayID: String?
    private(set) var targets: [Day?: FolderTarget] = [:]
    private(set) var oneFolderTarget: FolderTarget = .new(title: "")
    private(set) var existingFolderNames: [String] = []
    var cameraSubfolders: Bool = false {
        didSet { dependencies.settings.cameraSubfolders = cameraSubfolders }
    }
    private(set) var destination: URL?
    private(set) var destinationFreeBytes: Int64?
    /// Set when the plan does not fit — blocks the primary action.
    private(set) var shortfall: SpaceShortfall?

    // MARK: Copy state

    private(set) var progress: CopyProgress?
    private(set) var bytesPerSecond: Double = 0
    private(set) var secondsRemaining: TimeInterval?
    private(set) var result: TransferResult?
    private(set) var finishedAt: Date?

    // MARK: Internals

    let dependencies: BackupDependencies
    private let effects: any BackupEffects
    private var filesByURL: [URL: MediaFile] = [:]
    private var work: Task<Void, Never>?
    private var speed = SpeedEstimator()

    init(dependencies: BackupDependencies = BackupDependencies(), effects: any BackupEffects = SilentBackupEffects()) {
        self.dependencies = dependencies
        self.effects = effects
        structure = dependencies.settings.structure
        cameraSubfolders = dependencies.settings.cameraSubfolders
        destination = dependencies.settings.selectedDestination.map { URL(fileURLWithPath: $0) }
            ?? dependencies.settings.transferDestinations.first.map { URL(fileURLWithPath: $0) }
        locations = Self.configuredLocations(dependencies.settings)
    }

    // MARK: - Derived state

    var isBusy: Bool {
        switch phase {
        case .scanning, .copying: return true
        default: return false
        }
    }

    /// `true` when there is a card to scan and nothing is running.
    var canScan: Bool {
        selectedCard != nil && !isBusy
    }

    var isCopying: Bool {
        if case .copying = phase { return true }
        return false
    }

    /// Stable name of the current phase — used for `onChange` and debug snapshots.
    var phaseName: String {
        switch phase {
        case .waiting: return "waiting"
        case .ready: return "ready"
        case .scanning: return "scanning"
        case .review: return "review"
        case .copying: return "copying"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    /// Every file the user ticked.
    var tickedFiles: [MediaFile] {
        ticked.compactMap { filesByURL[$0] }
    }

    var tickedCount: Int { ticked.count }

    var tickedBytes: Int64 {
        ticked.reduce(0) { $0 + (filesByURL[$1]?.size ?? 0) }
    }

    /// `true` when the card holds nothing new.
    var allBackedUp: Bool {
        guard let scan else { return false }
        return scan.missing.isEmpty && !scan.allFiles.isEmpty
    }

    /// `11 new · 206 backed up · 4 other`.
    var reviewSubtitle: String {
        guard let scan else { return "" }
        var parts = ["\(scan.missing.count) new"]
        if !scan.backedUp.isEmpty { parts.append("\(scan.backedUp.count) backed up") }
        let other = scan.otherFiles.count
        if other > 0 { parts.append("\(other) other") }
        return parts.joined(separator: " · ")
    }

    func isTicked(_ file: ReviewFile) -> Bool { ticked.contains(file.id) }

    func isTicked(day: ReviewDay) -> Bool {
        day.files.contains { ticked.contains($0.id) }
    }

    /// `true` for a day that holds nothing new and has nothing ticked — it sits in the
    /// "Already backed up" block, collapsed and greyed.
    func isBackedUpOnly(_ day: ReviewDay) -> Bool {
        backedUpOnlyDayIDs.contains(day.id)
    }

    /// Days with something to copy first (oldest to newest), fully backed-up days after.
    private func rebuildDayOrder() {
        var active: [ReviewDay] = []
        var settled: [ReviewDay] = []
        var settledIDs: Set<String> = []
        for day in days {
            if day.newFiles.isEmpty, !isTicked(day: day) {
                settled.append(day)
                settledIDs.insert(day.id)
            } else {
                active.append(day)
            }
        }
        orderedDays = active + settled
        backedUpOnlyDayIDs = settledIDs
    }

    /// The target used for a day — one folder collapses every day onto one target.
    func target(for day: ReviewDay) -> FolderTarget {
        if structure == .oneFolder { return oneFolderTarget }
        return targets[day.day] ?? .new(title: "")
    }

    /// Day the one-folder name takes its date from: the first ticked day.
    var oneFolderDay: Day? {
        days.first(where: { isTicked(day: $0) })?.day ?? days.first?.day
    }

    /// The plan the primary action would run.
    var plan: TransferPlan {
        guard let destination else { return TransferPlan(folders: [], jobs: []) }
        return TransferPlanner.plan(
            files: tickedFiles,
            structure: structure,
            targets: effectiveTargets,
            destination: destination,
            cameraSubfolders: cameraSubfolders,
            dateFormat: dependencies.settings.dateFormat
        )
    }

    private var effectiveTargets: [Day?: FolderTarget] {
        structure == .oneFolder ? [oneFolderDay: oneFolderTarget] : targets
    }

    /// Folder name a target renders to, for display in the field and the picker.
    func folderName(for day: Day?, target: FolderTarget) -> String {
        switch target {
        case let .new(title):
            return FolderNaming.folderName(day: day, title: title, format: dependencies.settings.dateFormat)
        case let .existing(url):
            return url.lastPathComponent
        }
    }

    /// The fixed `2026.09.18 -` prefix of a new folder.
    func datePrefix(for day: Day?) -> String {
        guard let day else { return "unknown -" }
        return FolderNaming.formatDate(day, format: dependencies.settings.dateFormat) + " -"
    }

    // MARK: - Cards

    /// Re-read the mounted volumes. Nothing is scanned — a card just becomes available.
    func refreshCards() async {
        let listed = await dependencies.volumes.list()
        let excluded = Self.configuredPaths(dependencies.settings)
        let volumes = await Task.detached {
            listed.filter { Self.isCard($0, excluding: excluded) }
        }.value
        cards = volumes

        if let selected = selectedCard, !volumes.contains(where: { $0.url == selected.url }) {
            // Either unmounted, or it just became a configured location.
            cardDisappeared(selected)
            return
        }
        if selectedCard == nil, let first = volumes.first {
            select(first)
        }
    }

    /// Make a card the active one. Scanning is a deliberate step, so this only opens
    /// the ready screen. Refused during a copy — switching cards would cancel it.
    func select(_ card: RemovableVolume) {
        guard !isCopying else { return }
        guard selectedCard?.url != card.url else { return }
        work?.cancel()
        selectedCard = card
        resetScanState()
        phase = .ready
    }

    /// The active card vanished.
    private func cardDisappeared(_ card: RemovableVolume) {
        work?.cancel()
        work = nil
        selectedCard = nil
        effects.setDockProgress(nil)
        switch phase {
        case .copying, .scanning:
            phase = .failed(.cardRemoved(volume: card.url))
        case .done:
            phase = .waiting
            resetScanState()
        default:
            phase = .waiting
            resetScanState()
        }
        if let next = cards.first(where: { $0.url != card.url }) {
            if case .failed = phase { return }
            select(next)
        }
    }

    /// Paths the user configured as check locations or destinations — a volume holding
    /// one of them is a backup target, never a card to copy from.
    nonisolated static func configuredPaths(_ settings: SettingsStore) -> [String] {
        settings.checkPaths.map(\.path) + settings.transferDestinations
    }

    /// `true` when a mounted volume may be offered as a card.
    ///
    /// Excluded: volumes that contain (or are) a configured check location or
    /// destination, and network shares — an SMB mount of the NAS is not a card.
    nonisolated static func isCard(_ volume: RemovableVolume, excluding configured: [String]) -> Bool {
        let volumeComponents = URL(fileURLWithPath: volume.url.path).standardizedFileURL.pathComponents
        for path in configured {
            let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
            guard components.count >= volumeComponents.count else { continue }
            if Array(components.prefix(volumeComponents.count)) == volumeComponents { return false }
        }
        if let isLocal = try? volume.url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal,
           isLocal == false {
            return false
        }
        return true
    }

    /// Entry point for the unmount notification.
    func handleUnmount(_ url: URL?) async {
        if let url { volumeUnmounted(url) }
        await refreshCards()
    }

    /// Called from the unmount notification.
    func volumeUnmounted(_ url: URL) {
        guard let selected = selectedCard, selected.url == url else {
            cards.removeAll { $0.url == url }
            return
        }
        cards.removeAll { $0.url == url }
        cardDisappeared(selected)
    }

    private func resetScanState() {
        scan = nil
        days = []
        orderedDays = []
        backedUpOnlyDayIDs = []
        ticked = []
        targets = [:]
        oneFolderTarget = .new(title: "")
        existingFolderNames = []
        failedSources = []
        shortfall = nil
        progress = nil
        result = nil
        finishedAt = nil
        expandedDayID = nil
    }

    // MARK: - Scanning

    /// Scan the selected card. `skipCheck` is the fast scan that skips duplicate detection.
    func startScan(skipCheck: Bool = false) {
        guard let card = selectedCard else { return }
        work?.cancel()
        phase = .scanning(nil)
        shortfall = nil

        let dependencies = self.dependencies
        let destination = self.destination
        let throttle = Throttle<ScanEvent>(interval: 0.1) { [weak self] event in
            guard let self, case .scanning = self.phase else { return }
            self.phase = .scanning(event)
        }

        let disabled = disabledLocationNames
        work = Task.detached { [weak self] in
            let sources = await dependencies.sources(dependencies.settings)
                .filter { !disabled.contains($0.name) }
            do {
                let result = try await dependencies.scan.run(
                    card: card.url,
                    sources: sources,
                    skipCheck: skipCheck,
                    progress: { event in
                        // Always show the last metadata tick, otherwise the counter can
                        // stop short of the total before the review screen appears.
                        let isFinal = event.phase == .metadata && event.total != nil && event.count == event.total
                        throttle.send(event, force: isFinal)
                    }
                )
                let folders = destination.map { dependencies.existingFolders($0) } ?? []
                let free = destination.map { dependencies.freeSpace.freeBytes(at: $0) }
                if Task.isCancelled { return }
                await MainActor.run {
                    self?.scanFinished(result, existingFolders: folders, freeBytes: free)
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self?.phase = .failed((error as? BackupError) ?? .cancelled)
                }
            }
        }
    }

    private func scanFinished(_ result: ScanResult, existingFolders: [String], freeBytes: Int64?) {
        scan = result
        failedSources = result.sources.filter { !$0.succeeded }
        // A scan is the most accurate reachability check there is — fold it back into
        // the pills so Review shows what actually answered.
        for source in result.sources {
            guard let index = locations.firstIndex(where: { $0.sourceName == source.name }) else { continue }
            locations[index].reachable = source.succeeded
        }
        existingFolderNames = existingFolders
        destinationFreeBytes = freeBytes

        // Enrichment (capture date, camera) only happened for the missing files —
        // fold it back into the full list so every row shows what is known.
        var enriched: [URL: MediaFile] = [:]
        for file in result.missing { enriched[file.url] = file }
        let backedUpURLs = Set(result.backedUp.map(\.url))

        var allFiles: [MediaFile] = []
        allFiles.reserveCapacity(result.allFiles.count)
        for file in result.allFiles {
            allFiles.append(enriched[file.url] ?? file)
        }
        filesByURL = Dictionary(uniqueKeysWithValues: allFiles.map { ($0.url, $0) })

        days = DayGrouping.group(allFiles).map { group in
            ReviewDay(
                day: group.day,
                files: group.files.map { file in
                    let reason: FileReason
                    if !file.isMedia {
                        reason = .other
                    } else if backedUpURLs.contains(file.url) {
                        reason = .backedUp
                    } else {
                        reason = .new
                    }
                    return ReviewFile(file: file, reason: reason)
                }
            )
        }

        ticked = Set(days.flatMap(\.newFiles).map(\.id))
        rebuildDayOrder()
        expandedDayID = days.first(where: { !$0.newFiles.isEmpty })?.id ?? days.first?.id
        rebuildTargets()
        autoEnableCameraSubfolders()
        phase = .review
    }

    /// Preselect an existing folder per day when one with the same date exists.
    private func rebuildTargets() {
        guard let destination else {
            targets = [:]
            return
        }
        let format = dependencies.settings.dateFormat
        var next: [Day?: FolderTarget] = [:]
        for group in days {
            guard let day = group.day else {
                next[nil] = .new(title: "")
                continue
            }
            if let match = FolderNaming.preselectedFolder(in: existingFolderNames, for: day, format: format) {
                next[day] = .existing(destination.appending(path: match, directoryHint: .notDirectory))
            } else {
                next[day] = .new(title: "")
            }
        }
        targets = next
        oneFolderTarget = next[oneFolderDay] ?? .new(title: "")
    }

    private func autoEnableCameraSubfolders() {
        let selected = targets.values.compactMap { target -> URL? in
            if case let .existing(url) = target { return url }
            return nil
        }
        guard !selected.isEmpty else { return }
        let files = tickedFiles
        Task { [weak self] in
            let auto = await Task.detached {
                FolderNaming.autoCheckCameraSubfolder(files: files, selectedExistingFolders: selected)
            }.value
            if auto { await MainActor.run { self?.cameraSubfolders = true } }
        }
    }

    // MARK: - Ticking

    func setTicked(_ file: ReviewFile, _ isOn: Bool) {
        if isOn {
            ticked.insert(file.id)
        } else {
            ticked.remove(file.id)
        }
        rebuildDayOrder()
        shortfall = nil
    }

    /// Ticking a day on includes the files Copier would pick by default; ticking it
    /// off drops everything from that day.
    func setTicked(day: ReviewDay, _ isOn: Bool) {
        if isOn {
            let candidates = day.newFiles.isEmpty ? day.files : day.newFiles
            for file in candidates { ticked.insert(file.id) }
        } else {
            for file in day.files { ticked.remove(file.id) }
        }
        rebuildDayOrder()
        shortfall = nil
    }

    // MARK: - Folder targets

    func setTitle(_ title: String, for day: ReviewDay) {
        if structure == .oneFolder {
            oneFolderTarget = .new(title: title)
        } else {
            targets[day.day] = .new(title: title)
        }
        shortfall = nil
    }

    func setExistingFolder(_ url: URL?, for day: ReviewDay) {
        let target: FolderTarget = url.map { .existing($0) } ?? .new(title: "")
        if structure == .oneFolder {
            oneFolderTarget = target
        } else {
            targets[day.day] = target
        }
        shortfall = nil
    }

    /// Existing folders at the destination, same-day matches first.
    func folderChoices(for day: ReviewDay) -> [String] {
        guard let target = day.day else { return existingFolderNames }
        let format = dependencies.settings.dateFormat
        let sameDay = FolderNaming.folders(existingFolderNames, matching: target, format: format)
        let rest = existingFolderNames.filter { !sameDay.contains($0) }.sorted(by: >)
        return sameDay + rest
    }

    func isSameDay(_ name: String, as day: ReviewDay) -> Bool {
        guard let target = day.day else { return false }
        return name.hasPrefix(FolderNaming.formatDate(target, format: dependencies.settings.dateFormat))
    }

    // MARK: - Destination

    func setDestination(_ url: URL) {
        destination = url
        dependencies.settings.selectedDestination = url.path
        var known = dependencies.settings.transferDestinations
        if !known.contains(url.path) {
            known.insert(url.path, at: 0)
            dependencies.settings.transferDestinations = known
        }
        shortfall = nil
        refreshDestinationInfo()
    }

    /// Re-read the destination's folder list and free space off the main actor.
    func refreshDestinationInfo() {
        guard let destination else { return }
        let dependencies = self.dependencies
        Task { [weak self] in
            let folders = await Task.detached { dependencies.existingFolders(destination) }.value
            let free = await Task.detached { dependencies.freeSpace.freeBytes(at: destination) }.value
            await MainActor.run {
                guard let self else { return }
                self.existingFolderNames = folders
                self.destinationFreeBytes = free
                if case .review = self.phase { self.rebuildTargets() }
            }
        }
    }

    // MARK: - Copying

    /// Primary action of the review screen.
    ///
    /// The free-space preflight stats the destination volume, so it runs off the main
    /// actor; the phase only switches once it came back clean.
    func startBackup() {
        guard destination != nil else { return }
        let plan = self.plan
        guard !plan.jobs.isEmpty else { return }

        shortfall = nil
        let transfer = dependencies.transfer
        let jobs = plan.jobs
        work = Task { [weak self] in
            let problem = await Task.detached { transfer.checkFreeSpace(jobs: jobs) }.value
            await MainActor.run {
                guard let self, case .review = self.phase else { return }
                if let problem {
                    self.shortfall = problem
                    return
                }
                self.beginCopy(jobs: jobs, bytesTotal: plan.totalBytes)
            }
        }
    }

    private func beginCopy(jobs: [CopyJob], bytesTotal: Int64) {
        speed = SpeedEstimator()
        bytesPerSecond = 0
        secondsRemaining = nil
        progress = CopyProgress(
            filesDone: 0,
            filesTotal: jobs.count,
            bytesDone: 0,
            bytesTotal: bytesTotal,
            currentFile: "",
            folders: []
        )
        phase = .copying

        let transfer = dependencies.transfer
        let throttle = Throttle<CopyProgress>(interval: 0.1) { [weak self] snapshot in
            self?.copyProgressed(snapshot)
        }

        work = Task { [weak self] in
            let outcome = await transfer.copy(
                jobs: jobs,
                progress: { snapshot in
                    // The snapshot that completes the run must not be throttled away.
                    throttle.send(snapshot, force: snapshot.filesDone == snapshot.filesTotal)
                }
            )
            await MainActor.run { self?.copyFinished(outcome) }
        }
    }

    private func copyProgressed(_ snapshot: CopyProgress) {
        guard case .copying = phase else { return }
        progress = snapshot
        speed.update(bytesDone: snapshot.bytesDone, at: ProcessInfo.processInfo.systemUptime)
        bytesPerSecond = speed.bytesPerSecond
        secondsRemaining = speed.timeRemaining(bytesDone: snapshot.bytesDone, bytesTotal: snapshot.bytesTotal)
        effects.setDockProgress(snapshot.fraction)
    }

    private func copyFinished(_ outcome: TransferResult) {
        guard case .copying = phase else { return }
        work = nil
        result = outcome
        finishedAt = Date()
        effects.setDockProgress(nil)
        if outcome.cancelled {
            phase = .review
            return
        }
        phase = .done
        effects.backupFinished(files: progress?.filesTotal ?? 0, failures: outcome.failures.count)
    }

    /// Cancel a running scan or copy.
    func cancel() {
        work?.cancel()
        work = nil
        effects.setDockProgress(nil)
        switch phase {
        case .scanning:
            if scan != nil {
                phase = .review
            } else {
                phase = selectedCard == nil ? .waiting : .ready
            }
        case .copying:
            break // the transfer reports back and returns to review
        default:
            break
        }
    }

    // MARK: - Done

    /// Primary action of the done screen.
    func ejectCard() {
        guard let card = selectedCard, !card.isFixture else {
            finish()
            return
        }
        let eject = dependencies.eject
        let url = card.url
        Task { [weak self] in
            try? await Task.detached { try eject(url) }.value
            await MainActor.run { self?.finish() }
        }
    }

    /// Leave the done screen without ejecting.
    func finish() {
        resetScanState()
        selectedCard = nil
        phase = .waiting
        Task { await refreshCards() }
    }

    /// Start over after a failure: back to the ready screen for the same card, so the
    /// check locations can be changed before trying again.
    func retry() {
        if selectedCard != nil {
            resetScanState()
            phase = .ready
        } else {
            phase = .waiting
            Task { await refreshCards() }
        }
    }

    // MARK: - Locations

    /// The configured check locations, in the order the scan searches them.
    static func configuredLocations(_ settings: SettingsStore) -> [LocationStatus] {
        var result: [LocationStatus] = []
        if let host = settings.synologyHost, !host.isEmpty, !settings.synologyFolders.isEmpty {
            result.append(
                LocationStatus(
                    sourceName: BackupDependencies.synologySourceName,
                    displayName: host,
                    detail: "Synology API · " + settings.synologyFolders.joined(separator: ", "),
                    isNAS: true,
                    isFallback: false,
                    reachable: nil
                )
            )
        }
        for path in settings.checkPaths {
            result.append(
                LocationStatus(
                    sourceName: path.label,
                    displayName: path.label,
                    detail: path.path,
                    isNAS: false,
                    isFallback: path.fallbackOnly,
                    reachable: nil
                )
            )
        }
        return result
    }

    /// Switch a location off (or back on) for the next scan. In memory only — this is
    /// a "skip it this time", not a settings change.
    func toggleLocation(_ location: LocationStatus) {
        if disabledLocationNames.contains(location.sourceName) {
            disabledLocationNames.remove(location.sourceName)
        } else {
            disabledLocationNames.insert(location.sourceName)
        }
    }

    func isDisabled(_ location: LocationStatus) -> Bool {
        disabledLocationNames.contains(location.sourceName)
    }

    /// Re-read the configured locations after a settings change.
    func reloadLocations() {
        let configured = Self.configuredLocations(dependencies.settings)
        // Keep what we already know about locations that did not change.
        let known = Dictionary(uniqueKeysWithValues: locations.map { ($0.id, $0.reachable) })
        locations = configured.map { location in
            var updated = location
            updated.reachable = known[location.id] ?? nil
            return updated
        }
    }

    /// Probe every configured location: local paths must exist, the NAS must accept a login.
    func checkLocations() async {
        reloadLocations()
        let settings = dependencies.settings
        var updated = locations
        for (index, location) in locations.enumerated() {
            updated[index].reachable = nil
            locations = updated
            if location.isNAS {
                let reachable = await Task.detached { () -> Bool in
                    // Reaching the NAS is about credentials — shared folders are a
                    // scanning concern, so a missing folder list must not read as offline.
                    let configuration = await CredentialResolver.makeSynologyConfig(
                        settings: settings,
                        requireFolders: false
                    )
                    guard let config = try? configuration.get() else { return false }
                    let client = SynologyClient(config: config)
                    do {
                        try await client.login()
                        await client.logout()
                        return true
                    } catch {
                        return false
                    }
                }.value
                updated[index].reachable = reachable
            } else {
                let path = location.detail
                let exists = await Task.detached { FileManager.default.fileExists(atPath: path) }.value
                updated[index].reachable = exists
            }
            locations = updated
        }
    }
}
