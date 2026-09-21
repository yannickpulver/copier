import AppKit
import CopierCore
import SwiftUI

/// Sidebar sections.
enum Screen: Hashable {
    case backup
    case folderSync
}

/// NavigationSplitView shell: 200 pt sidebar, one detail view per screen.
struct RootView: View {
    @Bindable var backup: BackupModel
    @Bindable var sync: SyncModel
    var router: SettingsRouter
    @State private var screen: Screen = .backup

    var body: some View {
        NavigationSplitView {
            Sidebar(backup: backup, screen: $screen)
                .navigationSplitViewColumnWidth(200)
        } detail: {
            switch screen {
            case .backup:
                BackupScreen(model: backup, router: router)
            case .folderSync:
                FolderSyncView(model: sync)
            }
        }
        .task {
            await backup.refreshCards()
            await backup.checkLocations()
        }
        .task { await Self.watchVolumes(backup) }
        .modifier(DebugSnapshotModifier(model: backup, sync: sync, screen: $screen))
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
    @Binding var screen: Screen

    func body(content: Content) -> some View {
        #if DEBUG
            content.debugSnapshots(model: model, sync: sync, screen: $screen)
        #else
            content
        #endif
    }
}

private struct Sidebar: View {
    @Bindable var backup: BackupModel
    @Binding var screen: Screen

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $screen) {
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
                                screen = .backup
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
            SettingsLink {
                HStack(spacing: 9) {
                    Image(systemName: "gearshape")
                    Text("Settings")
                    Spacer()
                    Text("⌘,")
                }
                .font(Theme.secondary)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
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

/// Picks the view for the current phase and keeps the header consistent.
private struct BackupScreen: View {
    @Bindable var model: BackupModel
    var router: SettingsRouter

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .waiting:
                ScreenHeader("Waiting for card", detail: "No card connected")
                WaitingView(model: model, router: router)
            case .ready:
                ScreenHeader("Card inserted", detail: "Not scanned yet")
                ReadyView(model: model, router: router)
            case let .scanning(event):
                ScreenHeader("Scanning", detail: model.selectedCard?.name ?? "")
                ScanningView(model: model, event: event, router: router)
            case .review:
                ScreenHeader(title: "Review") {
                    HStack(spacing: 10) {
                        Text("\(model.selectedCard?.name ?? "Card") · \(Format.count(model.scan?.allFiles.count ?? 0)) files")
                        // Toggling a check-location pill only takes effect on a new scan.
                        Button("Rescan") { model.startScan() }
                            .buttonStyle(.link)
                            .disabled(!model.canScan)
                            .help("Scan the card again, with the check locations selected above (⌘R).")
                    }
                }
                ReviewView(model: model, router: router)
            case .copying:
                ScreenHeader(
                    "Backing up",
                    detail: "\(model.selectedCard?.name ?? "Card") → \(model.destination.map(Format.destinationLabel) ?? "")"
                )
                CopyingView(model: model)
            case .done:
                ScreenHeader("Done", detail: model.finishedAt?.formatted(date: .abbreviated, time: .shortened) ?? "")
                DoneView(model: model)
            case let .failed(error):
                ScreenHeader("Backup stopped", detail: model.selectedCard?.name ?? "")
                FailedView(model: model, error: error)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
