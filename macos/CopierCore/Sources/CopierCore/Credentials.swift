import Foundation
import Security

/// Resolves settings values that are 1Password secret references (`op://…`).
public enum CredentialResolver {
    /// `true` when the value is a 1Password reference rather than a literal.
    public static func isReference(_ value: String) -> Bool { value.hasPrefix("op://") }

    /// How long `op read` may take. Unlocking 1Password can mean a biometric prompt,
    /// which the user has to physically answer.
    public static let opTimeout: TimeInterval = 60

    /// Resolve a value: `op://…` references are read with the `op` CLI, everything
    /// else is returned unchanged. Returns `nil` when the reference cannot be read.
    ///
    /// Spawns a process — never call this from the main actor.
    public static func resolve(_ value: String?) async -> String? {
        guard let value else { return nil }
        return try? await read(value).get()
    }

    /// Same as ``resolve(_:)`` but says why a reference could not be read.
    ///
    /// - Parameter opPath: the `op` binary to use; looked up when `nil` (tests inject a stub).
    public static func read(
        _ value: String,
        opPath: String? = nil,
        timeout: TimeInterval = opTimeout
    ) async -> Result<String, CredentialProblem> {
        guard isReference(value) else { return .success(value) }
        guard let op = opPath ?? ProcessRunner.locate("op") else { return .failure(.opNotInstalled) }

        guard let result = ProcessRunner.runCapturing(
            executable: op,
            arguments: ["read", "--no-newline", value],
            timeout: timeout,
            environment: opEnvironment
        ) else {
            return .failure(.opFailed("could not start \(op)"))
        }
        if result.timedOut { return .failure(.opTimedOut) }

        guard result.status == 0 else {
            let stderr = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.opFailed(stderr.isEmpty ? "op exited with status \(result.status)" : stderr))
        }
        let text = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? .failure(.opFailed("the reference resolved to an empty value")) : .success(text)
    }

    /// The environment `op` is run with: the app's own, with the Homebrew locations
    /// added to `PATH` and `HOME` guaranteed, so `op` finds its config and can talk to
    /// the desktop app. Everything else (including `OP_BIOMETRIC_UNLOCK_ENABLED`) is
    /// passed through untouched.
    static var opEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let extraDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]
        var path = environment["PATH"] ?? "/usr/bin:/bin"
        for directory in extraDirectories where !path.split(separator: ":").contains(Substring(directory)) {
            path += ":\(directory)"
        }
        environment["PATH"] = path
        if environment["HOME"]?.isEmpty != false { environment["HOME"] = NSHomeDirectory() }
        return environment
    }

    /// Build a usable Synology config from stored settings and the keychain,
    /// resolving any `op://` references. `nil` when host, user, password or
    /// folders are missing.
    public static func synologyConfig(
        settings: SettingsStore,
        keychain: KeychainStore = KeychainStore()
    ) async -> SynologyConfig? {
        try? await makeSynologyConfig(settings: settings, keychain: keychain, requireFolders: true).get()
    }

    /// Same, but says exactly what is missing — and can skip the shared-folder
    /// requirement, because logging in to test the connection needs only credentials.
    /// - Parameter opPath: the `op` binary used for `op://` references; looked up when
    ///   `nil`. Tests inject a stub so they never wait on the real 1Password.
    public static func makeSynologyConfig(
        settings: SettingsStore,
        keychain: KeychainStore = KeychainStore(),
        requireFolders: Bool = true,
        opPath: String? = nil
    ) async -> Result<SynologyConfig, CredentialProblem> {
        guard let rawHost = settings.synologyHost, !rawHost.isEmpty else { return .failure(.missingHost) }
        guard let rawUser = settings.synologyUser, !rawUser.isEmpty else { return .failure(.missingUser) }
        let storedPassword = settings.synologyPassword ?? keychain.synologyPassword
        guard let rawPassword = storedPassword, !rawPassword.isEmpty else { return .failure(.missingPassword) }

        let host: String
        let user: String
        let password: String
        switch await read(rawHost, opPath: opPath) {
        case let .failure(problem): return .failure(problem)
        case let .success(value): host = value
        }
        switch await read(rawUser, opPath: opPath) {
        case let .failure(problem): return .failure(problem)
        case let .success(value): user = value
        }
        switch await read(rawPassword, opPath: opPath) {
        case let .failure(problem): return .failure(problem)
        case let .success(value): password = value
        }

        if requireFolders, settings.synologyFolders.isEmpty {
            return .failure(.missingFolders)
        }

        return .success(
            SynologyConfig(
                host: host,
                port: settings.synologyPort,
                user: user,
                password: password,
                secure: settings.synologySecure,
                folders: settings.synologyFolders
            )
        )
    }
}

/// Why a Synology config could not be built, in words a settings screen can show.
public enum CredentialProblem: Error, Sendable, Equatable {
    case missingHost
    case missingUser
    case missingPassword
    case missingFolders
    /// The `op` CLI is not installed.
    case opNotInstalled
    /// `op read` failed; the payload is its trimmed stderr.
    case opFailed(String)
    /// `op read` did not answer in time — usually an unanswered unlock prompt.
    case opTimedOut

    public var message: String {
        switch self {
        case .missingHost: return "Host is missing."
        case .missingUser: return "User is missing."
        case .missingPassword: return "Password is missing."
        case .missingFolders: return "No shared folders are configured."
        case .opNotInstalled:
            return "1Password: the op command line tool was not found. Install it with brew install 1password-cli."
        case let .opFailed(reason):
            return "1Password: \(reason)"
        case .opTimedOut:
            return "1Password: op read timed out after \(Int(CredentialResolver.opTimeout))s — unlock 1Password and try again."
        }
    }
}

extension CredentialProblem: LocalizedError {
    public var errorDescription: String? { message }
}

/// Where keychain items actually live. Injectable so tests never touch the real one.
public protocol KeychainBackend: Sendable {
    func value(service: String, account: String) -> String?
    func set(_ value: String?, service: String, account: String) throws
}

/// Process-wide cache of keychain reads.
///
/// macOS asks the user for permission per reading process *and* per item read that is
/// not already authorised, so several independent reads of the same password during one
/// launch stack up several dialogs. Each account is therefore read at most once per
/// process, and writes update the cache in place.
final class KeychainCache: @unchecked Sendable {
    static let shared = KeychainCache()

    private let lock = NSLock()
    /// `nil` inner value means "read, and there was nothing there".
    private var entries: [String: String?] = [:]

    private func key(service: String, account: String) -> String { "\(service)\u{0}\(account)" }

    func value(service: String, account: String, load: () -> String?) -> String? {
        let key = key(service: service, account: account)
        lock.lock()
        if let cached = entries[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Loaded outside the lock: the keychain can block on a user prompt.
        let loaded = load()

        lock.lock()
        // A write that happened while we were blocked wins.
        if let cached = entries[key] {
            lock.unlock()
            return cached
        }
        entries[key] = loaded
        lock.unlock()
        return loaded
    }

    func store(_ value: String?, service: String, account: String) {
        let key = key(service: service, account: account)
        lock.lock()
        entries[key] = value
        lock.unlock()
    }

    /// Only used by tests.
    func removeAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}

/// Generic-password keychain storage for the Synology password.
public struct KeychainStore: Sendable {
    /// Keychain service name.
    public static let defaultService = "ch.yannickpulver.copier"
    /// Account used for the Synology password.
    public static let synologyAccount = "synology-password"

    public let service: String
    private let backend: any KeychainBackend

    public init(service: String = defaultService, backend: any KeychainBackend = SecItemKeychainBackend()) {
        self.service = service
        self.backend = backend
    }

    /// The stored Synology password, if any.
    public var synologyPassword: String? {
        get { value(for: Self.synologyAccount) }
        nonmutating set { try? set(newValue, for: Self.synologyAccount) }
    }

    /// Read a generic password. Each account is read from the keychain once per process.
    public func value(for account: String) -> String? {
        KeychainCache.shared.value(service: service, account: account) {
            backend.value(service: service, account: account)
        }
    }

    /// Store (or, with `nil`, delete) a generic password.
    public func set(_ value: String?, for account: String) throws {
        try backend.set(value, service: service, account: account)
        KeychainCache.shared.store(value, service: service, account: account)
    }
}

/// The real keychain, via `SecItem`.
public struct SecItemKeychainBackend: KeychainBackend {
    public init() {}

    public func value(service: String, account: String) -> String? {
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

    public func set(_ value: String?, service: String, account: String) throws {
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
