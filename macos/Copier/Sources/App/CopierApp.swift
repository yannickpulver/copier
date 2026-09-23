import AppKit
import CopierCore
import SwiftUI
import UserNotifications

@main
struct CopierApp: App {
    @State private var backup: BackupModel
    @State private var sync: SyncModel
    @State private var settings: SettingsModel
    @State private var router = SettingsRouter()
    @State private var updater = Updater()

    init() {
        #if DEBUG
            // `COPIER_DEFAULTS_SUITE` keeps a test run out of the real settings.
            let store = SettingsStore(defaults: DebugSupport.defaults)
        #else
            let store = SettingsStore()
        #endif
        let effects = LiveBackupEffects()
        _backup = State(
            initialValue: BackupModel(
                dependencies: BackupDependencies(
                    volumes: VolumeLister(fixtureCard: Self.fixtureCard),
                    settings: store
                ),
                effects: effects
            )
        )
        _sync = State(initialValue: SyncModel(settings: store))
        _settings = State(initialValue: SettingsModel(store: store))
    }

    var body: some Scene {
        Window("Copier", id: "main") {
            RootView(backup: backup, sync: sync, router: router)
                .frame(minWidth: 920, minHeight: 620)
                // Settings changes (locations, NAS) must show up in the pills.
                .onChange(of: settings.locationsRevision) { _, _ in
                    backup.reloadLocations()
                    // A volume that just became a check location or destination is no
                    // longer a card, so the list has to be filtered again.
                    Task {
                        await backup.refreshCards()
                        await backup.checkLocations()
                    }
                }
        }
        .defaultSize(width: 1040, height: 700)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Scan Card") { backup.startScan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!backup.canScan)
                Button("Scan Without Duplicate Check") { backup.startScan(skipCheck: true) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!backup.canScan)
            }
        }

        Settings {
            SettingsWindow(model: settings, router: router, updater: updater)
        }
    }

    /// In debug builds the repo's `dev-fixtures/test-sd` (or `COPIER_FIXTURE_CARD`)
    /// shows up as a card, so the app is usable without hardware.
    private static var fixtureCard: URL? {
        #if DEBUG
            if let path = ProcessInfo.processInfo.environment["COPIER_FIXTURE_CARD"], !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
            // …/macos/Copier.app → repo root is three levels up from the build products dir,
            // so fall back to walking up from the source location recorded at compile time.
            var directory = URL(fileURLWithPath: #filePath)
            for _ in 0..<6 {
                directory = directory.deletingLastPathComponent()
                let candidate = directory.appendingPathComponent("dev-fixtures/test-sd")
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        #endif
        return nil
    }
}

/// Dock tile badge and the completion notification.
@MainActor
final class LiveBackupEffects: BackupEffects {
    private var askedForPermission = false

    func setDockProgress(_ fraction: Double?) {
        guard let fraction else {
            NSApp?.dockTile.badgeLabel = nil
            return
        }
        NSApp?.dockTile.badgeLabel = "\(Int((fraction * 100).rounded()))%"
    }

    func backupFinished(files: Int, failures: Int) {
        requestPermissionIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = failures == 0 ? "Backup finished" : "Backup finished with errors"
        content.body = failures == 0
            ? "\(files) file\(files == 1 ? "" : "s") backed up and verified."
            : "\(files - failures) of \(files) files copied, \(failures) failed."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Asked lazily, the first time a backup finishes.
    private func requestPermissionIfNeeded() {
        guard !askedForPermission else { return }
        askedForPermission = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
