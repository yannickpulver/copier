import SwiftUI

/// The Synology NAS on its own Settings page: login, folders, and removing it again.
struct SynologySettingsView: View {
    @Bindable var model: SettingsModel
    /// Goes back to Settings, after the NAS was removed.
    let close: () -> Void

    @State private var newFolder = ""
    @State private var showsBrowser = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case host, port, user, password
    }

    var body: some View {
        Form {
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
                Text("Login")
            } footer: {
                Text("The password is stored in your keychain. A 1Password reference like op://Vault/Item/password is read with the 1Password CLI when a scan starts.")
                    .font(Theme.secondary)
                    .foregroundStyle(.secondary)
            }
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
                Text("Folders")
            } footer: {
                Text("Subfolders are checked too. Pick the smallest folders that hold your backups, whole shares are slow.")
                    .font(Theme.secondary)
                    .foregroundStyle(.secondary)
            }

            if model.hasNAS {
                Section {
                    Button("Remove NAS", role: .destructive) {
                        model.removeNAS()
                        close()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Synology NAS")
        .onDisappear { model.commitEdits() }
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
                    Text("Add at least one folder below so the NAS gets checked.")
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
