import AppKit
import CopierCore
import SwiftUI

/// Sidebar sections.
enum Screen: Hashable {
    case backup
    case folderSync
    case settings
}

/// Which screen the main window shows. Lets any screen, and the ⌘, menu item, open
/// Settings, optionally scrolled to a chapter.
@MainActor
@Observable
final class AppRouter {
    var screen: Screen = .backup
    /// The chapter Settings should scroll to; cleared once it has.
    var settingsChapter: SettingsChapter?

    func openSettings(_ chapter: SettingsChapter? = nil) {
        settingsChapter = chapter
        screen = .settings
    }
}

/// NavigationSplitView shell: 200 pt sidebar, one detail view per screen.
struct RootView: View {
    @Bindable var backup: BackupModel
    @Bindable var sync: SyncModel
    var settings: SettingsModel
    @Bindable var router: AppRouter
    var updater: Updater

    var body: some View {
        NavigationSplitView {
            Sidebar(backup: backup, router: router)
                .navigationSplitViewColumnWidth(200)
        } detail: {
            switch router.screen {
            case .backup:
                BackupScreen(model: backup, router: router)
            case .folderSync:
                FolderSyncView(model: sync)
            case .settings:
                SettingsView(model: settings, router: router, updater: updater)
            }
        }
        .task {
            await backup.refreshCards()
            await backup.checkLocations()
        }
        .task { await Self.watchVolumes(backup) }
        .modifier(DebugSnapshotModifier(model: backup, sync: sync, router: router))
    }

    /// Mount / unmount / rename notifications drive the card list.
    private static func watchVolumes(_ model: BackupModel) async {
        let center = NSWorkspace.shared.notificationCenter
        await withTaskGroup(of: Void.self) { group in
            for name in [NSWorkspace.didMountNotification, NSWorkspace.didRenameVolumeNotification] {
                group.addTask {
                    for await _ in center.notifications(named: name) {
                        await model.refreshCards()
                    }
                }
            }
            group.addTask {
                for await note in center.notifications(named: NSWorkspace.didUnmountNotification) {
                    let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                    await model.handleUnmount(url)
                }
            }
        }
    }
}

/// Debug builds write window snapshots; release builds do nothing at all.
private struct DebugSnapshotModifier: ViewModifier {
    let model: BackupModel
    let sync: SyncModel
    let router: AppRouter

    func body(content: Content) -> some View {
        #if DEBUG
            content.debugSnapshots(model: model, sync: sync, router: router)
        #else
            content
        #endif
    }
}

private struct Sidebar: View {
    @Bindable var backup: BackupModel
    @Bindable var router: AppRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $router.screen) {
                Label("SD Backup", systemImage: "sdcard")
                    .tag(Screen.backup)
                Label("Folder Sync", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    .tag(Screen.folderSync)

                Section("Cards") {
                    if backup.cards.isEmpty {
                        Label("No card", systemImage: "sdcard")
                            .foregroundStyle(.secondary)
                            .font(Theme.secondary)
                    } else {
                        ForEach(backup.cards) { card in
                            Button {
                                router.screen = .backup
                                backup.select(card)
                            } label: {
                                CardRow(card: card, isSelected: backup.selectedCard?.url == card.url)
                            }
                            .buttonStyle(.plain)
                            // Switching cards mid-copy would cancel the transfer.
                            .disabled(backup.isCopying && backup.selectedCard?.url != card.url)
                            .help(backup.isCopying ? "Finish or cancel the backup before switching cards." : "")
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            Button {
                router.openSettings()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "gearshape")
                    Text("Settings")
                    Spacer()
                    Text("⌘,")
                }
                .font(Theme.secondary)
                .foregroundStyle(isOnSettings ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background {
                    // The same rounded grey as the card rows, since this row is no list row.
                    if isOnSettings {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.08))
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
    }

    private var isOnSettings: Bool { router.screen == .settings }
}

/// Card rows are plain buttons, so they draw the native-looking selected background
/// themselves — the same rounded grey the sidebar rows above use.
private struct CardRow: View {
    let card: RemovableVolume
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "sdcard")
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 1) {
                Text(card.name)
                    .font(Theme.secondary)
                    .fontWeight(isSelected ? .medium : .regular)
                    .lineLimit(1)
                if card.totalBytes > 0 {
                    Text(Format.bytes(card.totalBytes))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.08))
            }
        }
        .contentShape(.rect)
    }
}

/// Picks the view for the current phase; its title and detail go into the window's title bar.
private struct BackupScreen: View {
    @Bindable var model: BackupModel
    var router: AppRouter

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .waiting:
                WaitingView(model: model, router: router)
            case .ready:
                ReadyView(model: model, router: router)
            case let .scanning(event):
                ScanningView(model: model, event: event, router: router)
            case .review:
                ReviewView(model: model)
            case .copying:
                CopyingView(model: model)
            case .done:
                DoneView(model: model)
            case let .failed(error):
                FailedView(model: model, error: error)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar {
            if case .review = model.phase {
                ToolbarItem(placement: .primaryAction) {
                    Button("Rescan") { model.startScan() }
                        .disabled(!model.canScan)
                        .help("Scan the card again (⌘R).")
                }
            }
        }
    }

    private var title: String {
        switch model.phase {
        case .waiting: return "Waiting for card"
        case .ready: return "Card inserted"
        case .scanning: return "Scanning"
        case .review: return "Review"
        case .copying: return "Backing up"
        case .done: return "Done"
        case .failed: return "Backup stopped"
        }
    }

    private var subtitle: String {
        let card = model.selectedCard?.name ?? "Card"
        switch model.phase {
        case .waiting: return "No card connected"
        case .ready: return "Not scanned yet"
        case .scanning, .failed: return card
        case .review: return "\(card) · \(model.reviewSubtitle)"
        case .copying: return "\(card) → \(model.destination.map(Format.destinationLabel) ?? "")"
        case .done: return model.finishedAt?.formatted(date: .abbreviated, time: .shortened) ?? ""
        }
    }
}
