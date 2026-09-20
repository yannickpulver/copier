import CopierCore
import Foundation
import Observation

/// What the NAS folder browser got back.
enum BrowseOutcome: Sendable {
    case folders([String])
    case failed(String)
}

/// Outcome of the NAS "Test connection" button.
enum ConnectionState: Equatable, Sendable {
    case idle
    /// `op` is running — this can take a while, the user may have to answer a
    /// biometric prompt in 1Password.
    case resolving
    case testing
    /// Connected; `shares` are the NAS's shared folders, offered as quick-adds.
    case ok(shares: [String])
    case failed(String)
}

/// Bindable wrapper around ``SettingsStore`` for the Settings window.
@MainActor
@Observable
final class SettingsModel {
    var checkPaths: [CheckPath] {
        didSet {
            store.checkPaths = checkPaths
            locationsRevision += 1
        }
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
        didSet {
            store.synologyFolders = synologyFolders
            locationsRevision += 1
        }
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
    /// Bumped whenever something the check-location pills show has changed.
    private(set) var locationsRevision = 0

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

    /// Logs in and straight out again. Only host, user and password are needed — the
    /// shared folders matter for scanning, not for proving the credentials work.
    func testConnection() {
        // Whatever is in the fields right now is what gets tested.
        commitEdits()
        connection = usesPasswordReference ? .resolving : .testing
        let store = self.store
        let keychain = self.keychain
        Task { [weak self] in
            let configuration = await Task.detached {
                await CredentialResolver.makeSynologyConfig(
                    settings: store,
                    keychain: keychain,
                    requireFolders: false
                )
            }.value

            let config: SynologyConfig
            switch configuration {
            case let .failure(problem):
                await MainActor.run { self?.connection = .failed(problem.message) }
                return
            case let .success(resolved):
                config = resolved
            }

            // The reference resolved; from here on it is a plain network round trip.
            await MainActor.run { self?.connection = .testing }
            let outcome = await Task.detached { () -> ConnectionState in
                let client = SynologyClient(config: config)
                do {
                    try await client.login()
                    let shares = (try? await client.listShares()) ?? []
                    await client.logout()
                    return .ok(shares: shares)
                } catch {
                    return .failed(error.localizedDescription)
                }
            }.value
            await MainActor.run { self?.connection = outcome }
        }
    }

    /// `true` when the stored password is an `op://…` reference rather than a secret.
    var usesPasswordReference: Bool {
        CredentialResolver.isReference(synologyPassword)
    }

    /// Log in and list one folder's subfolders, for the Settings folder browser.
    /// Root level (`nil`) returns the NAS's shares.
    func browseFolders(in path: String?) async -> BrowseOutcome {
        let store = self.store
        let keychain = self.keychain
        return await Task.detached {
            let configuration = await CredentialResolver.makeSynologyConfig(
                settings: store,
                keychain: keychain,
                requireFolders: false
            )
            switch configuration {
            case let .failure(problem):
                return .failed(problem.message)
            case let .success(config):
                let client = SynologyClient(config: config)
                do {
                    try await client.login()
                    defer { Task { await client.logout() } }
                    if let path {
                        return .folders(try await client.listFolders(in: path))
                    }
                    return .folders(try await client.listShares())
                } catch {
                    return .failed(error.localizedDescription)
                }
            }
        }.value
    }

    /// Flushes the text fields into the store. Called on commit, on focus loss and
    /// before a connection test, so a test never runs against stale values.
    func commitEdits() {
        store.synologyHost = synologyHost.trimmingCharacters(in: .whitespacesAndNewlines)
        store.synologyUser = synologyUser.trimmingCharacters(in: .whitespacesAndNewlines)
        store.synologyPort = synologyPort
        store.synologySecure = synologySecure
        storePassword(synologyPassword)
        locationsRevision += 1
    }

    /// `true` once the NAS can be talked to at all.
    var isNASConfigured: Bool {
        !synologyHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !synologyUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !synologyPassword.isEmpty
    }

    /// Shares the last successful test found that are not indexed yet.
    var suggestedShares: [String] {
        guard case let .ok(shares) = connection else { return [] }
        return shares.filter { !synologyFolders.contains($0) }
    }
}

extension Array {
    /// `remove(atOffsets:)` without depending on SwiftUI.
    func removing(_ offsets: IndexSet) -> [Element] {
        enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
    }
}
