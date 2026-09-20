import CopierCore
import Foundation
import Observation

/// Outcome of the NAS "Test connection" button.
enum ConnectionState: Equatable, Sendable {
    case idle
    case testing
    case ok
    case failed(String)
}

/// Bindable wrapper around ``SettingsStore`` for the Settings window.
@MainActor
@Observable
final class SettingsModel {
    var checkPaths: [CheckPath] {
        didSet { store.checkPaths = checkPaths }
    }
    var destinations: [String] {
        didSet { store.transferDestinations = destinations }
    }
    var selectedDestination: String {
        didSet { store.selectedDestination = selectedDestination.isEmpty ? nil : selectedDestination }
    }

    var synologyHost: String {
        didSet { store.synologyHost = synologyHost }
    }
    var synologyPort: Int {
        didSet { store.synologyPort = synologyPort }
    }
    var synologyUser: String {
        didSet { store.synologyUser = synologyUser }
    }
    var synologySecure: Bool {
        didSet { store.synologySecure = synologySecure }
    }
    var synologyFolders: [String] {
        didSet { store.synologyFolders = synologyFolders }
    }
    /// Either a literal password (stored in the keychain) or an `op://` reference
    /// (stored in defaults, because a reference is not a secret).
    var synologyPassword: String {
        didSet { storePassword(synologyPassword) }
    }

    var dateFormat: String {
        didSet { store.dateFormat = dateFormat }
    }

    private(set) var connection: ConnectionState = .idle

    let store: SettingsStore
    private let keychain: KeychainStore

    init(store: SettingsStore = SettingsStore(), keychain: KeychainStore = KeychainStore()) {
        self.store = store
        self.keychain = keychain
        checkPaths = store.checkPaths
        destinations = store.transferDestinations
        selectedDestination = store.selectedDestination ?? ""
        synologyHost = store.synologyHost ?? ""
        synologyPort = store.synologyPort
        synologyUser = store.synologyUser ?? ""
        synologySecure = store.synologySecure
        synologyFolders = store.synologyFolders
        synologyPassword = store.synologyPassword ?? keychain.synologyPassword ?? ""
        dateFormat = store.dateFormat
    }

    private func storePassword(_ value: String) {
        if CredentialResolver.isReference(value) {
            store.synologyPassword = value
            keychain.synologyPassword = nil
        } else {
            store.synologyPassword = nil
            keychain.synologyPassword = value.isEmpty ? nil : value
        }
    }

    /// Live preview of the folder name for today's date.
    var dateFormatPreview: String {
        FolderNaming.folderName(day: Day(date: Date()), title: "Topic", format: dateFormat)
    }

    // MARK: Editing

    func addCheckPath(_ url: URL) {
        guard !checkPaths.contains(where: { $0.path == url.path }) else { return }
        checkPaths.append(CheckPath(path: url.path))
    }

    func removeCheckPaths(at offsets: IndexSet) {
        checkPaths = checkPaths.removing(offsets)
    }

    func setFallbackOnly(_ value: Bool, at index: Int) {
        guard checkPaths.indices.contains(index) else { return }
        checkPaths[index].fallbackOnly = value
    }

    func addDestination(_ url: URL) {
        if !destinations.contains(url.path) { destinations.append(url.path) }
        if selectedDestination.isEmpty { selectedDestination = url.path }
    }

    func removeDestinations(at offsets: IndexSet) {
        let removed = offsets.map { destinations[$0] }
        destinations = destinations.removing(offsets)
        if removed.contains(selectedDestination) { selectedDestination = destinations.first ?? "" }
    }

    func addSynologyFolder(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !synologyFolders.contains(trimmed) else { return }
        synologyFolders.append(trimmed)
    }

    func removeSynologyFolders(at offsets: IndexSet) {
        synologyFolders = synologyFolders.removing(offsets)
    }

    // MARK: Connection test

    func testConnection() {
        connection = .testing
        let store = self.store
        let keychain = self.keychain
        Task { [weak self] in
            let outcome = await Task.detached { () -> ConnectionState in
                guard let config = await CredentialResolver.synologyConfig(settings: store, keychain: keychain) else {
                    return .failed("Host, user, password or shared folders are missing.")
                }
                let client = SynologyClient(config: config)
                do {
                    try await client.login()
                    await client.logout()
                    return .ok
                } catch {
                    return .failed(error.localizedDescription)
                }
            }.value
            await MainActor.run { self?.connection = outcome }
        }
    }
}

extension Array {
    /// `remove(atOffsets:)` without depending on SwiftUI.
    func removing(_ offsets: IndexSet) -> [Element] {
        enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
    }
}
