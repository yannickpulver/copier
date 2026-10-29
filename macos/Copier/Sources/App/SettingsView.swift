import CopierCore
import SwiftUI

/// Places on the Settings page other screens can jump to.
enum SettingsChapter: CaseIterable, Hashable {
    case backup
    case duplicateCheck
    case nas
    case general
}

/// The Settings screen in the main window: one page, grouped by task. Backup says
/// where files go and how folders are named, Duplicate check where existing backups
/// are looked up, General the rest.
struct SettingsView: View {
    @Bindable var model: SettingsModel
    @Bindable var router: AppRouter
    @Bindable var updater: Updater

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                BackupChapter(model: model)
                DuplicateCheckChapter(model: model, router: router)
                GeneralChapter(model: model, updater: updater)
            }
            .formStyle(.grouped)
            .onChange(of: router.settingsChapter, initial: true) { _, chapter in
                guard let chapter else { return }
                // Wait one turn so a page that was just opened has laid out its rows.
                Task {
                    withAnimation { proxy.scrollTo(chapter, anchor: .top) }
                    router.settingsChapter = nil
                }
            }
        }
        .navigationTitle("Settings")
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
            ChapterHeader(title: "Backup", section: "Back up to")
        }
        .id(SettingsChapter.backup)

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

// MARK: - Duplicate check

private struct DuplicateCheckChapter: View {
    @Bindable var model: SettingsModel
    var router: AppRouter
    @State private var newFolder = ""
    @State private var showsBrowser = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case host, port, user, password
    }

    var body: some View {
        Section {
            nasRow
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
                    Toggle(
                        "Only if NAS fails",
                        isOn: Binding(
                            get: { path.fallbackOnly },
                            set: { model.setFallbackOnly($0, at: index) }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .font(Theme.secondary)
                    Button {
                        model.removeCheckPaths(at: IndexSet(integer: index))
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            AddRow(title: "Add folder") {
                if let url = FolderPanel.chooseFolder(title: "Choose a folder to check") {
                    model.addCheckPath(url)
                }
            }
        } header: {
            ChapterHeader(title: "Duplicate check", section: "Look for existing backups in")
        }
        .id(SettingsChapter.duplicateCheck)

        Section {
            TextField("Host", text: $model.synologyHost, prompt: Text("nas.local"))
                .focused($focusedField, equals: .host)
            TextField("Port", value: $model.synologyPort, format: .number.grouping(.never))
                .focused($focusedField, equals: .port)
            TextField("User", text: $model.synologyUser)
                .focused($focusedField, equals: .user)
            HStack(spacing: 8) {
                // A 1Password reference is not a secret, so show it in the clear.
                if model.usesPasswordReference {
                    TextField("Password", text: $model.synologyPassword)
                        .focused($focusedField, equals: .password)
                        .font(.system(size: 12, design: .monospaced))
                    TagChip(text: "1Password reference", accented: true)
                } else {
                    SecureField(
                        "Password",
                        text: $model.synologyPassword,
                        prompt: Text("Password or op://… reference")
                    )
                    .focused($focusedField, equals: .password)
                }
            }
            Toggle("Use HTTPS", isOn: $model.synologySecure)

            HStack(alignment: .center, spacing: 12) {
                Button("Test connection") { model.testConnection() }
                    .disabled(model.connection == .testing || model.connection == .resolving)
                connectionStatus
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            Text("Synology NAS")
        } footer: {
            Text("The password is stored in your keychain. A 1Password reference like op://Vault/Item/password is read with the 1Password CLI when a scan starts.")
                .font(Theme.secondary)
                .foregroundStyle(.secondary)
        }
        .id(SettingsChapter.nas)
        // Committing on every focus change means a test never uses stale text.
        .onSubmit { model.commitEdits() }
        .onChange(of: focusedField) { _, _ in model.commitEdits() }

        Section {
            ForEach(Array(model.synologyFolders.enumerated()), id: \.element) { index, folder in
                HStack {
                    Text(folder).font(.system(size: 12, design: .monospaced))
                    Spacer()
                    Button {
                        model.removeSynologyFolders(at: IndexSet(integer: index))
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                TextField("", text: $newFolder, prompt: Text("Add a folder path, e.g. /photo/2026"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .onSubmit(addFolder)
                Button("Add", action: addFolder)
                    .disabled(!isAddable)
                Button("Browse NAS…") { showsBrowser = true }
                    .disabled(!model.isNASConfigured)
                    .popover(isPresented: $showsBrowser, arrowEdge: .bottom) {
                        NASFolderBrowser(model: model)
                    }
                    .help(
                        model.isNASConfigured
                            ? "Pick a folder from the NAS."
                            : "Fill in host, user and password first."
                    )
            }

        } header: {
            Text("NAS folders to index")
        } footer: {
            Text("Indexed recursively. Pick the narrowest folders that hold your backups, whole shares are slow.")
                .font(Theme.secondary)
                .foregroundStyle(.secondary)
        }
    }

    /// The NAS is a check location too — it just lives behind the API, so it gets a
    /// fixed first row here with a link down to its connection settings.
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
                } else {
                    Text("Not set up. Check your NAS over its API, faster than a mounted share.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if model.isNASConfigured {
                HStack(alignment: .center, spacing: 12) {
                    Label {
                        Text(isConnected ? "Connected" : "Configured")
                            .font(Theme.secondary)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Circle()
                            .fill(isConnected ? Theme.success : Color.secondary.opacity(0.45))
                            .frame(width: 7, height: 7)
                    }
                    .labelStyle(.titleAndIcon)
                    Button("Configure…") { router.openSettings(.nas) }
                        .buttonStyle(.link)
                        .font(Theme.secondary)
                }
            } else {
                Button("Set up NAS…") { router.openSettings(.nas) }
                    .buttonStyle(.link)
                    .font(Theme.secondary)
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

    @ViewBuilder
    private var connectionStatus: some View {
        switch model.connection {
        case .resolving:
            busyStatus("Reading 1Password reference…")
        case .testing:
            busyStatus("Testing…")
        case .ok:
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text("Connected.")
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
                .labelStyle(.titleAndIcon)
                .imageScale(.medium)
                .font(Theme.secondary)
                .foregroundStyle(Theme.success)
                if model.synologyFolders.isEmpty {
                    Text("Add at least one shared folder below so the NAS gets checked.")
                        .font(Theme.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case let .failed(reason):
            Label {
                Text(reason)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .labelStyle(.titleAndIcon)
            .imageScale(.medium)
            .font(Theme.secondary)
            .foregroundStyle(Theme.warning)
        case .idle:
            EmptyView()
        }
    }

    private func busyStatus(_ text: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(Theme.secondary)
                .foregroundStyle(.secondary)
        }
    }

    /// A shared-folder path is absolute, so require the leading slash.
    private var isAddable: Bool {
        newFolder.trimmingCharacters(in: .whitespaces).hasPrefix("/")
    }

    private func addFolder() {
        guard isAddable else { return }
        model.addSynologyFolder(newFolder)
        newFolder = ""
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
    }
}
