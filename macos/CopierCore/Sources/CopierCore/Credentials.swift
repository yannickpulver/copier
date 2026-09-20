import Foundation
import Security

/// Resolves settings values that are 1Password secret references (`op://…`).
public enum CredentialResolver {
    /// `true` when the value is a 1Password reference rather than a literal.
    public static func isReference(_ value: String) -> Bool { value.hasPrefix("op://") }

    /// Resolve a value: `op://…` references are read with the `op` CLI, everything
    /// else is returned unchanged. Returns `nil` when the reference cannot be read.
    ///
    /// Spawns a process — never call this from the main actor.
    public static func resolve(_ value: String?) async -> String? {
        guard let value, isReference(value) else { return value }
        guard let op = ProcessRunner.locate("op") else { return nil }
        guard let data = ProcessRunner.run(executable: op, arguments: ["read", value], timeout: 10) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Build a usable Synology config from stored settings and the keychain,
    /// resolving any `op://` references. `nil` when host, user, password or
    /// folders are missing.
    public static func synologyConfig(
        settings: SettingsStore,
        keychain: KeychainStore = KeychainStore()
    ) async -> SynologyConfig? {
        let storedPassword = settings.synologyPassword ?? keychain.synologyPassword
        guard let host = await resolve(settings.synologyHost),
              let user = await resolve(settings.synologyUser),
              let password = await resolve(storedPassword),
              !host.isEmpty, !user.isEmpty, !password.isEmpty,
              !settings.synologyFolders.isEmpty
        else { return nil }

        return SynologyConfig(
            host: host,
            port: settings.synologyPort,
            user: user,
            password: password,
            secure: settings.synologySecure,
            folders: settings.synologyFolders
        )
    }
}

/// Generic-password keychain storage for the Synology password.
public struct KeychainStore: Sendable {
    /// Keychain service name.
    public static let defaultService = "ch.yannickpulver.copier"
    /// Account used for the Synology password.
    public static let synologyAccount = "synology-password"

    public let service: String

    public init(service: String = defaultService) {
        self.service = service
    }

    /// The stored Synology password, if any.
    public var synologyPassword: String? {
        get { value(for: Self.synologyAccount) }
        nonmutating set { try? set(newValue, for: Self.synologyAccount) }
    }

    /// Read a generic password.
    public func value(for account: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &item) { pointer in
            SecItemCopyMatching(query as CFDictionary, pointer)
        }
        query.removeAll()
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Store (or, with `nil`, delete) a generic password.
    public func set(_ value: String?, for account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BackupError.copyFailed(file: account, reason: "keychain write failed (\(status))")
        }
    }
}
