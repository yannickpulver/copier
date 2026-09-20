import CopierCore
import SwiftUI

/// The ⌘, window: Locations, NAS and Naming.
struct SettingsWindow: View {
    @Bindable var model: SettingsModel

    var body: some View {
        TabView {
            LocationsTab(model: model)
                .tabItem { Label("Locations", systemImage: "folder") }
            NASTab(model: model)
                .tabItem { Label("NAS", systemImage: "externaldrive.connected.to.line.below") }
            NamingTab(model: model)
                .tabItem { Label("Naming", systemImage: "textformat") }
        }
        .frame(width: 680, height: 480)
    }
}

// MARK: - Locations

private struct LocationsTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                SectionLabel(text: "Check for existing backups in")
                GroupedBox {
                    if model.checkPaths.isEmpty {
                        emptyRow("No locations yet")
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

            Spacer(minLength: 0)

            Text("Folder names use \(model.dateFormat) - Topic. Change in Naming.")
                .font(Theme.secondary)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
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

    var body: some View {
        Form {
            Section("Synology") {
                TextField("Host", text: $model.synologyHost, prompt: Text("nas.local"))
                TextField("Port", value: $model.synologyPort, format: .number.grouping(.never))
                TextField("User", text: $model.synologyUser)
                SecureField("Password", text: $model.synologyPassword, prompt: Text("Password or op://… reference"))
                Toggle("Use HTTPS", isOn: $model.synologySecure)
                HStack(spacing: 10) {
                    Button("Test connection") { model.testConnection() }
                        .disabled(model.connection == .testing)
                    switch model.connection {
                    case .testing:
                        ProgressView().controlSize(.small)
                    case .ok:
                        Label("Connected", systemImage: "checkmark.circle")
                            .foregroundStyle(Theme.success)
                            .font(Theme.secondary)
                    case let .failed(reason):
                        Text(reason)
                            .font(Theme.secondary)
                            .foregroundStyle(Theme.warning)
                            .lineLimit(2)
                    case .idle:
                        EmptyView()
                    }
                }
            }

            Section("Shared folders to index") {
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
                HStack {
                    TextField("/photo/2026", text: $newFolder)
                        .onSubmit(addFolder)
                    Button("Add", action: addFolder)
                        .disabled(newFolder.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section {
                Text("The password is stored in your keychain. An op://… reference is read with the 1Password CLI when a scan starts.")
                    .font(Theme.secondary)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addFolder() {
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
