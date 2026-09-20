import Foundation

/// `UserDefaults`-backed settings.
///
/// The Synology password is *not* stored here: it lives in ``KeychainStore``, or,
/// when the user entered an `op://…` reference, it is kept as-is in
/// ``synologyPassword`` (a reference is not a secret).
public final class SettingsStore: @unchecked Sendable {
    /// Defaults keys, all prefixed so they can share a suite with the app's own state.
    public enum Key {
        public static let checkPaths = "copier.checkPaths"
        public static let transferDestinations = "copier.transferDests"
        public static let selectedDestination = "copier.transferDest"
        public static let synologyHost = "copier.synologyHost"
        public static let synologyPort = "copier.synologyPort"
        public static let synologyUser = "copier.synologyUser"
        public static let synologyPassword = "copier.synologyPass"
        public static let synologySecure = "copier.synologySecure"
        public static let synologyFolders = "copier.synologyFolders"
        public static let dateFormat = "copier.dateFormat"
        public static let syncSource = "copier.syncSource"
        public static let syncTarget = "copier.syncTarget"
        public static let syncAppendSourceName = "copier.syncAppendSourceName"
        public static let cameraSubfolders = "copier.cameraSubfolders"
        public static let structure = "copier.structure"
    }

    private let defaults: UserDefaults

    /// - Parameter defaults: injectable so tests can use their own suite.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Locations

    /// Paths searched for existing backups.
    public var checkPaths: [CheckPath] {
        get {
            guard let data = defaults.data(forKey: Key.checkPaths),
                  let decoded = try? JSONDecoder().decode([CheckPath].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.checkPaths)
        }
    }

    /// Destination roots the user picked, most recent first.
    public var transferDestinations: [String] {
        get { defaults.stringArray(forKey: Key.transferDestinations) ?? [] }
        set { defaults.set(newValue, forKey: Key.transferDestinations) }
    }

    /// The currently selected destination root.
    public var selectedDestination: String? {
        get { defaults.string(forKey: Key.selectedDestination) }
        set { defaults.set(newValue, forKey: Key.selectedDestination) }
    }

    // MARK: Synology

    public var synologyHost: String? {
        get { defaults.string(forKey: Key.synologyHost) }
        set { defaults.set(newValue, forKey: Key.synologyHost) }
    }

    /// Defaults to 5001.
    public var synologyPort: Int {
        get { defaults.object(forKey: Key.synologyPort) as? Int ?? 5001 }
        set { defaults.set(newValue, forKey: Key.synologyPort) }
    }

    public var synologyUser: String? {
        get { defaults.string(forKey: Key.synologyUser) }
        set { defaults.set(newValue, forKey: Key.synologyUser) }
    }

    /// Only ever an `op://…` reference — real passwords belong in ``KeychainStore``.
    public var synologyPassword: String? {
        get { defaults.string(forKey: Key.synologyPassword) }
        set { defaults.set(newValue, forKey: Key.synologyPassword) }
    }

    /// Defaults to `true` (HTTPS on 5001).
    public var synologySecure: Bool {
        get { defaults.object(forKey: Key.synologySecure) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.synologySecure) }
    }

    /// Shared-folder paths to index, e.g. `/photo/2026`.
    public var synologyFolders: [String] {
        get { defaults.stringArray(forKey: Key.synologyFolders) ?? [] }
        set { defaults.set(newValue, forKey: Key.synologyFolders) }
    }

    // MARK: Naming

    /// Token format for folder dates, defaults to `YYYY.MM.DD`.
    public var dateFormat: String {
        get {
            let value = defaults.string(forKey: Key.dateFormat) ?? ""
            return value.isEmpty ? FolderNaming.defaultDateFormat : value
        }
        set { defaults.set(newValue, forKey: Key.dateFormat) }
    }

    /// Whether files go into a `<camera>` subfolder.
    public var cameraSubfolders: Bool {
        get { defaults.bool(forKey: Key.cameraSubfolders) }
        set { defaults.set(newValue, forKey: Key.cameraSubfolders) }
    }

    /// Folder-per-day or one folder; defaults to folder-per-day.
    public var structure: Structure {
        get { Structure(rawValue: defaults.string(forKey: Key.structure) ?? "") ?? .folderPerDay }
        set { defaults.set(newValue.rawValue, forKey: Key.structure) }
    }

    // MARK: Folder Sync

    public var syncSource: String? {
        get { defaults.string(forKey: Key.syncSource) }
        set { defaults.set(newValue, forKey: Key.syncSource) }
    }

    public var syncTarget: String? {
        get { defaults.string(forKey: Key.syncTarget) }
        set { defaults.set(newValue, forKey: Key.syncTarget) }
    }

    /// Whether the source folder name is appended to the sync target.
    public var syncAppendSourceName: Bool {
        get { defaults.bool(forKey: Key.syncAppendSourceName) }
        set { defaults.set(newValue, forKey: Key.syncAppendSourceName) }
    }

    /// Remove every Copier key from the suite (used by tests).
    public func reset() {
        let keys = [
            Key.checkPaths, Key.transferDestinations, Key.selectedDestination,
            Key.synologyHost, Key.synologyPort, Key.synologyUser, Key.synologyPassword,
            Key.synologySecure, Key.synologyFolders, Key.dateFormat, Key.syncSource,
            Key.syncTarget, Key.syncAppendSourceName, Key.cameraSubfolders, Key.structure,
        ]
        for key in keys { defaults.removeObject(forKey: key) }
    }
}
