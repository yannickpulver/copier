import Observation
import Sparkle

/// Sparkle's updater, observable so the menu item and the Settings toggle stay in sync.
///
/// The feed (`SUFeedURL`) and public key (`SUPublicEDKey`) live in the Info.plist.
/// Debug builds never start the updater, so a local build doesn't offer to replace itself
/// with the latest release.
@MainActor
@Observable
final class Updater {
    private(set) var canCheckForUpdates = false

    var automaticallyChecksForUpdates: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        #if DEBUG
            let startsUpdater = false
        #else
            let startsUpdater = true
        #endif
        controller = SPUStandardUpdaterController(
            startingUpdater: startsUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = canCheck }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
