import CopierCore
import SwiftUI

/// The tabs of the Settings window.
enum SettingsTab: Hashable {
    case locations
    case nas
    case naming
}

/// Lets any screen open Settings on a particular tab.
@MainActor
@Observable
final class SettingsRouter {
    var tab: SettingsTab = .locations
}

/// The ⌘, window: Locations, NAS and Naming.
struct SettingsWindow: View {
    @Bindable var model: SettingsModel
    @Bindable var router: SettingsRouter

    var body: some View {
        TabView(selection: $router.tab) {
            LocationsTab(model: model, router: router)
                .tabItem { Label("Locations", systemImage: "folder") }
                .tag(SettingsTab.locations)
            NASTab(model: model)
                .tabItem { Label("NAS", systemImage: "externaldrive.connected.to.line.below") }
                .tag(SettingsTab.nas)
            NamingTab(model: model)
                .tabItem { Label("Naming", systemImage: "textformat") }
                .tag(SettingsTab.naming)
        }
        .frame(minWidth: 680, minHeight: 560)
    }
}

// MARK: - Locations

private struct LocationsTab: View {
    @Bindable var model: SettingsModel
    var router: SettingsRouter

    var body: some View {
        // Many destinations and check paths overflow the window, so the tab scrolls.
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                SectionLabel(text: "Check for existing backups in")
                GroupedBox {
                    nasRow
                    Divider()
                    if model.checkPaths.isEmpty {
                        emptyRow("No folders yet")
                    }
                    ForEach(Array(model.checkPaths.enumerated()), id: \.element.path) { index, path in
                        if index > 0 { Divider() }
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
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    }
                    Divider()
                    addButton("Add location") {
                        if let url = FolderPanel.chooseFolder(title: "Choose a folder to check") {
                            model.addCheckPath(url)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                SectionLabel(text: "Back up to")
                GroupedBox {
                    if model.destinations.isEmpty {
                        emptyRow("No destinations yet")
                    }
                    ForEach(Array(model.destinations.enumerated()), id: \.element) { index, path in
                        if index > 0 { Divider() }
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
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    }
                    Divider()
                    addButton("Add destination") {
                        if let url = FolderPanel.chooseFolder(title: "Choose a backup destination") {
                            model.addDestination(url)
                        }
                    }
                }
            }

            Text("Folder names use \(model.dateFormat) - Topic. Change in Naming.")
                .font(Theme.secondary)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The NAS is a check location too — it just lives behind the API, so it gets a
    /// fixed first row here instead of being invisible until the NAS tab is opened.
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
                    Button("Configure…") { router.tab = .nas }
                        .buttonStyle(.link)
                        .font(Theme.secondary)
                }
            } else {
                Button("Set up NAS…") { router.tab = .nas }
                    .buttonStyle(.link)
                    .font(Theme.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
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

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(Theme.secondary)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
    }

    private func addButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                Text(title)
                Spacer(minLength: 0)
            }
            .font(Theme.body)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - NAS

private struct NASTab: View {
    @Bindable var model: SettingsModel
    @State private var newFolder = ""
    @State private var showsBrowser = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case host, port, user, password
    }

    var body: some View {
        Form {
            Section("Synology") {
                TextField("Host", text: $model.synologyHost, prompt: Text("nas.local"))
                    .focused($focusedField, equals: .host)
                TextField("Port", value: $model.synologyPort, format: .number.grouping(.never))
                    .focused($focusedField, equals: .port)
                TextField("User", text: $model.synologyUser)
                    .focused($focusedField, equals: .user)
                VStack(alignment: .leading, spacing: 4) {
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
                    Text("Use a 1Password reference instead of the password: op://Vault/Item/password")
                        .font(Theme.secondary)
                        .foregroundStyle(.secondary)
                }
                Toggle("Use HTTPS", isOn: $model.synologySecure)

                HStack(alignment: .center, spacing: 12) {
                    Button("Test connection") { model.testConnection() }
                        .disabled(model.connection == .testing || model.connection == .resolving)
                    connectionStatus
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // Committing on every focus change means a test never uses stale text.
            .onSubmit { model.commitEdits() }
            .onChange(of: focusedField) { _, _ in model.commitEdits() }

            Section("Shared folders to index") {
                if model.synologyFolders.isEmpty {
                    Text("No shared folders yet — the NAS is not searched for existing backups.")
                        .font(Theme.secondary)
                        .foregroundStyle(.secondary)
                }
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

                Text("Copier indexes these folders recursively to find files that are already backed up. Pick the narrowest folders that hold your backups, whole shares are slow.")
                    .font(Theme.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Text("The password is stored in your keychain. An op://… reference is read with the 1Password CLI when a scan starts.")
                    .font(Theme.secondary)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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

// MARK: - Naming

private struct NamingTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Folder date format") {
                TextField("Format", text: $model.dateFormat, prompt: Text(FolderNaming.defaultDateFormat))
                    .font(.system(size: 13, design: .monospaced))
                LabeledContent("Preview") {
                    Text(model.dateFormatPreview)
                        .font(.system(size: 13, design: .monospaced))
                }
                HStack(spacing: 8) {
                    ForEach(["YYYY.MM.DD", "YY.MM.DD", "YYYY-MM-DD", "YYYYMMDD"], id: \.self) { preset in
                        Button(preset) { model.dateFormat = preset }
                            .buttonStyle(.link)
                            .font(Theme.secondary)
                    }
                }
            }

            Section("Tokens") {
                LabeledContent("YYYY", value: "Four-digit year")
                LabeledContent("YY", value: "Two-digit year")
                LabeledContent("MM", value: "Month")
                LabeledContent("DD", value: "Day")
            }
        }
        .formStyle(.grouped)
    }
}
