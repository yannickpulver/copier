#if DEBUG

    import AppKit
    import CopierCore
    import SwiftUI

    /// Debug-build helpers driven entirely by environment variables, so a test run can
    /// drive the real app without touching real settings:
    ///
    /// - `COPIER_DEFAULTS_SUITE=<name>` — keep settings in their own defaults suite.
    /// - `COPIER_SNAPSHOT_DIR=<dir>` — write a PNG of the window on every phase change.
    /// - `COPIER_SNAPSHOT_OPEN=settings|sync` — also open that screen and snapshot it.
    /// - `COPIER_FIXTURE_CARD=<dir>` — expose a folder as a card (read in `CopierApp`).
    enum DebugSupport {
        private static var environment: [String: String] { ProcessInfo.processInfo.environment }

        /// A separate defaults suite when one was requested, otherwise the standard one.
        static var defaults: UserDefaults {
            guard let name = environment["COPIER_DEFAULTS_SUITE"], !name.isEmpty,
                  let suite = UserDefaults(suiteName: name)
            else { return .standard }
            return suite
        }

        /// Where snapshots go, when snapshotting is on.
        static var snapshotDirectory: URL? {
            guard let path = environment["COPIER_SNAPSHOT_DIR"], !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        }

        /// `settings`, `sync`, or `nil`.
        static var snapshotOpen: String? {
            let value = environment["COPIER_SNAPSHOT_OPEN"] ?? ""
            return value.isEmpty ? nil : value.lowercased()
        }

        /// Scanning is a manual step now, so a snapshot run has to ask for it to get
        /// past `ready.png`: set `COPIER_SNAPSHOT_SCAN=1`.
        static var startsScan: Bool {
            let value = environment["COPIER_SNAPSHOT_SCAN"] ?? ""
            return value == "1" || value.lowercased() == "true"
        }

        static var isSnapshotting: Bool { snapshotDirectory != nil }

        /// Write `<dir>/<name>.png` after `delay` seconds, so layout and animations settle.
        static func snapshot(_ name: String, delay: Double = 1.0) {
            guard let directory = snapshotDirectory else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                capture(name, into: directory)
            }
        }

        @MainActor
        private static func capture(_ name: String, into directory: URL) {
            guard let window = targetWindow(for: name), let content = window.contentView else { return }
            let bounds = content.bounds
            guard bounds.width > 1, bounds.height > 1,
                  let representation = content.bitmapImageRepForCachingDisplay(in: bounds)
            else { return }
            content.cacheDisplay(in: bounds, to: representation)
            guard let data = representation.representation(using: .png, properties: [:]) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent("\(name).png"))
        }

        /// The settings snapshot wants the settings window, everything else the main one.
        @MainActor
        private static func targetWindow(for name: String) -> NSWindow? {
            let windows = NSApp?.windows.filter { $0.isVisible && $0.contentView != nil } ?? []
            if name == "settings" {
                return windows.first { $0.title.localizedCaseInsensitiveContains("settings") } ?? windows.last
            }
            return windows.first { $0.title == "Copier" } ?? windows.first
        }

        /// `COPIER_PROBE_NAS=1` runs the same login the Settings test button does and
        /// prints the outcome to stderr, so the app's own network path can be checked
        /// from a shell.
        static func probeNAS() async {
            guard environment["COPIER_PROBE_NAS"] == "1" else { return }
            let configuration = await CredentialResolver.makeSynologyConfig(
                settings: SettingsStore(defaults: defaults),
                requireFolders: false
            )
            switch configuration {
            case let .failure(problem):
                FileHandle.standardError.write(Data("NAS probe: \(problem.message)\n".utf8))
            case let .success(config):
                let client = SynologyClient(config: config)
                do {
                    try await client.login()
                    let shares = (try? await client.listShares()) ?? []
                    await client.logout()
                    FileHandle.standardError.write(Data("NAS probe: connected, shares \(shares)\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data("NAS probe: \(error.localizedDescription)\n".utf8))
                }
            }
        }

        /// Opens the Settings window through the standard menu action.
        @MainActor
        static func openSettings() {
            NSApp?.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    extension View {
        /// Snapshots each phase change plus a `launch.png`, and optionally opens one
        /// extra screen — all of it inert unless `COPIER_SNAPSHOT_DIR` is set.
        func debugSnapshots(model: BackupModel, screen: Binding<Screen>) -> some View {
            onChange(of: model.phaseName) { _, phase in
                DebugSupport.snapshot(phase)
            }
            .task {
                await DebugSupport.probeNAS()
                guard DebugSupport.isSnapshotting else { return }
                DebugSupport.snapshot("launch", delay: 2)
                if DebugSupport.startsScan {
                    // Let the card show up first, then take the step the user would take.
                    try? await Task.sleep(for: .seconds(3))
                    if model.canScan { model.startScan() }
                }
                switch DebugSupport.snapshotOpen {
                case "settings":
                    try? await Task.sleep(for: .seconds(3))
                    DebugSupport.openSettings()
                    DebugSupport.snapshot("settings")
                case "sync":
                    try? await Task.sleep(for: .seconds(3))
                    screen.wrappedValue = .folderSync
                    DebugSupport.snapshot("sync")
                default:
                    break
                }
            }
        }
    }

#endif
