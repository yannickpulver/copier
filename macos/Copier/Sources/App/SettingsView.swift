import CopierCore
import SwiftUI

/// Places on the Settings page other screens can jump to.
enum SettingsChapter: CaseIterable, Hashable {
    case backup
    case duplicateCheck
    case nas
    case general
}

/// Pages Settings pushes on top of itself.
enum SettingsPage: Hashable {
    case synology
}

/// The Settings screen in the main window: one page, grouped by task. SD Backup says
/// where files go, how folders are named and where existing backups are looked up,
/// General the rest. The Synology NAS has its own page.
struct SettingsView: View {
    @Bindable var model: SettingsModel
    @Bindable var router: AppRouter
    @Bindable var updater: Updater

    @State private var path: [SettingsPage] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                Form {
                    DuplicateCheckChapter(model: model, router: router)
                    BackupChapter(model: model)
                    GeneralChapter(model: model, updater: updater)
                }
                .formStyle(.grouped)
                .onChange(of: router.settingsChapter, initial: true) { _, chapter in
                    guard let chapter else { return }
                    // Wait one turn so a page that was just opened has laid out its rows.
                    Task {
                        if chapter == .nas {
                            path = [.synology]
                        } else {
                            path = []
                            withAnimation { proxy.scrollTo(chapter, anchor: .top) }
                        }
                        router.settingsChapter = nil
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsPage.self) { _ in
                SynologySettingsView(model: model) { path = [] }
            }
        }
    }
}

/// The big title that opens a chapter, above the header of its first section.
private struct ChapterHeader: View {
    let title: String
    let section: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            Text(section)
        }
        .padding(.top, 10)
    }
}

/// The last row of a list: `+ Add …` in the accent colour.
private struct AddRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                Text(title)
                Spacer(minLength: 0)
            }
            .font(Theme.body)
            .foregroundStyle(Color.accentColor)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Backup

private struct BackupChapter: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Section {
            ForEach(Array(model.destinations.enumerated()), id: \.element) { index, path in
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive").foregroundStyle(.secondary)
                    Text(path)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if model.selectedDestination == path {
                        TagChip(text: "Default", accented: true)
                    } else {
                        Button("Make default") { model.selectedDestination = path }
                            .buttonStyle(.link)
                            .font(Theme.secondary)
                    }
                    Button {
                        model.removeDestinations(at: IndexSet(integer: index))
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            AddRow(title: "Add destination") {
                if let url = FolderPanel.chooseFolder(title: "Choose a backup destination") {
                    model.addDestination(url)
                }
            }
        } header: {
            Text("Copy to")
        } footer: {
            Text("You can also add one right before copying, in the destination menu at the bottom of the review.")
                .font(Theme.secondary)
                .foregroundStyle(.secondary)
        }
        .id(SettingsChapter.backup)
    }
}

// MARK: - Check locations (still part of SD Backup)

private struct DuplicateCheckChapter: View {
    @Bindable var model: SettingsModel
    var router: AppRouter

    var body: some View {
        Section {
            if model.hasNAS {
                NavigationLink(value: SettingsPage.synology) { nasRow }
            }
            ForEach(Array(model.checkPaths.enumerated()), id: \.element.path) { index, path in
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(path.label).font(Theme.body)
                        Text(path.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    // Without a NAS there is nothing to fall back from.
                    if model.isNASConfigured {
                        Toggle(
                            "Only if NAS fails",
                            isOn: Binding(
                                get: { path.fallbackOnly },
                                set: { model.setFallbackOnly($0, at: index) }
                            )
                        )
                        .toggleStyle(.checkbox)
                        .font(Theme.secondary)
                    }
                    Button {
                        model.removeCheckPaths(at: IndexSet(integer: index))
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 20) {
                AddRow(title: "Add folder") {
                    if let url = FolderPanel.chooseFolder(title: "Choose a folder to check") {
                        model.addCheckPath(url)
                    }
                }
                .fixedSize()
                if !model.hasNAS {
                    AddRow(title: "Add Synology NAS") { router.openSettings(.nas) }
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
        } header: {
            ChapterHeader(title: "SD Backup", section: "Check locations")
        } footer: {
            Text("Files found here are skipped. Any NAS works as a folder (its mounted share). A Synology NAS can also be checked over its API, which is faster.")
                .font(Theme.secondary)
                .foregroundStyle(.secondary)
        }
        .id(SettingsChapter.duplicateCheck)
    }

    /// The NAS as a list entry that opens its page: host and folders once set up.
    private var nasRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Synology NAS").font(Theme.body)
                if model.isNASConfigured {
                    Text(nasDetail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(nasTooltip)
                }
            }
            Spacer(minLength: 8)
            if isConnected {
                Label {
                    Text("Connected")
                        .font(Theme.secondary)
                        .foregroundStyle(.secondary)
                } icon: {
                    Circle()
                        .fill(Theme.success)
                        .frame(width: 7, height: 7)
                }
                .labelStyle(.titleAndIcon)
            } else if !model.isNASConfigured {
                Text("Login missing")
                    .font(Theme.secondary)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isConnected: Bool {
        if case .ok = model.connection { return true }
        return false
    }

    /// Host plus either the single folder or a count — a joined list truncates in the
    /// middle and becomes unreadable ("/yannick/Pho…026").
    private var nasDetail: String {
        let folders = model.synologyFolders
        switch folders.count {
        case 0: return model.synologyHost
        case 1: return "\(model.synologyHost) · \(folders[0])"
        default: return "\(model.synologyHost) · \(folders.count) folders"
        }
    }

    private var nasTooltip: String {
        model.synologyFolders.isEmpty
            ? model.synologyHost
            : model.synologyHost + "\n" + model.synologyFolders.joined(separator: "\n")
    }
}

// MARK: - General

private struct GeneralChapter: View {
    @Bindable var model: SettingsModel
    @Bindable var updater: Updater

    var body: some View {
        Section {
            Picker("Theme", selection: $model.appearance) {
                Text("System").tag(Appearance.system)
                Text("Light").tag(Appearance.light)
                Text("Dark").tag(Appearance.dark)
            }
            .pickerStyle(.segmented)
            Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
        } header: {
            ChapterHeader(title: "General", section: "App")
        }
        .id(SettingsChapter.general)

        Section {
            LabeledContent("Date format") {
                TextField("Date format", text: $model.dateFormat, prompt: Text(FolderNaming.defaultDateFormat))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 13, design: .monospaced))
            }
            Picker("Between date and title", selection: $model.folderSeparator) {
                Text("Dash").tag(" - ")
                Text("Space").tag(" ")
                Text("Underscore").tag("_")
            }
            .pickerStyle(.segmented)
            LabeledContent("Example") {
                Text(model.dateFormatPreview)
                    .font(.system(size: 13, design: .monospaced))
            }
        } header: {
            Text("Folder names")
        } footer: {
            HStack(spacing: 10) {
                Text("YYYY year · YY short year · MM month · DD day")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                ForEach(["YYYY.MM.DD", "YY.MM.DD", "YYYY-MM-DD"], id: \.self) { preset in
                    Button(preset) { model.dateFormat = preset }
                        .buttonStyle(.link)
                }
            }
            .font(Theme.secondary)
        }
    }
}
