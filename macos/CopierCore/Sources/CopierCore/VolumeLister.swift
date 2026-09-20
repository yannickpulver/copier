import Foundation

/// A mounted volume that qualifies as a card / external drive.
public struct RemovableVolume: Sendable, Hashable, Identifiable {
    public var name: String
    public var url: URL
    public var totalBytes: Int64
    public var freeBytes: Int64
    /// `true` for the injected dev fixture rather than a real volume.
    public var isFixture: Bool

    public var id: URL { url }

    public init(name: String, url: URL, totalBytes: Int64 = 0, freeBytes: Int64 = 0, isFixture: Bool = false) {
        self.name = name
        self.url = url
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.isFixture = isFixture
    }
}

/// The `diskutil info` fields the card rule looks at.
public struct DiskInfo: Sendable, Hashable {
    public var removableMedia: Bool
    public var external: Bool
    public var ioRegistryEntryName: String
    public var busProtocol: String
    public var solidState: Bool

    public init(
        removableMedia: Bool = false,
        external: Bool = false,
        ioRegistryEntryName: String = "",
        busProtocol: String = "",
        solidState: Bool = false
    ) {
        self.removableMedia = removableMedia
        self.external = external
        self.ioRegistryEntryName = ioRegistryEntryName
        self.busProtocol = busProtocol
        self.solidState = solidState
    }

    /// Parse a `diskutil info -plist` property list.
    public init?(plistData: Data) {
        guard let raw = try? PropertyListSerialization.propertyList(from: plistData, format: nil),
              let dict = raw as? [String: Any]
        else { return nil }
        self.init(
            removableMedia: (dict["RemovableMedia"] as? Bool) ?? false,
            external: (dict["External"] as? Bool) ?? false,
            ioRegistryEntryName: (dict["IORegistryEntryName"] as? String) ?? "",
            busProtocol: (dict["BusProtocol"] as? String) ?? "",
            solidState: (dict["SolidState"] as? Bool) ?? false
        )
    }

    /// The rule ported from `scanner.ts`: removable, external, an SD reader, or on USB/Thunderbolt.
    public var qualifiesAsCard: Bool {
        removableMedia
            || external
            || ioRegistryEntryName.contains("Secure Digital")
            || busProtocol == "USB"
            || busProtocol == "Thunderbolt"
    }
}

/// Supplies `diskutil info` for a mount point. Injectable so tests can feed canned plists.
public protocol DiskInfoProviding: Sendable {
    func diskInfo(forMountPath path: String) async -> DiskInfo?
}

/// Runs `/usr/sbin/diskutil info -plist <mount>`.
public struct DiskutilInfoProvider: DiskInfoProviding {
    public init() {}

    public func diskInfo(forMountPath path: String) async -> DiskInfo? {
        guard let data = ProcessRunner.run(
            executable: "/usr/sbin/diskutil",
            arguments: ["info", "-plist", path],
            timeout: 5
        ) else { return nil }
        return DiskInfo(plistData: data)
    }
}

/// Lists the volumes that count as cards. Pure enough to drive from
/// `NSWorkspace` mount/unmount notifications — the app calls ``list()`` again on each event.
public struct VolumeLister: Sendable {
    private let diskInfo: any DiskInfoProviding
    private let fixtureCard: URL?

    /// - Parameters:
    ///   - diskInfo: source of the `diskutil` rule inputs.
    ///   - fixtureCard: a folder to expose as an extra card (debug builds point this at
    ///     `dev-fixtures/test-sd`). Ignored when it does not exist.
    public init(
        diskInfo: any DiskInfoProviding = DiskutilInfoProvider(),
        fixtureCard: URL? = nil
    ) {
        self.diskInfo = diskInfo
        self.fixtureCard = fixtureCard
    }

    /// Currently mounted removable/external volumes, fixture card first.
    public func list() async -> [RemovableVolume] {
        var result: [RemovableVolume] = []

        if let fixtureCard, FileManager.default.fileExists(atPath: fixtureCard.path) {
            result.append(
                RemovableVolume(
                    name: "Test SD (dev)",
                    url: fixtureCard,
                    totalBytes: 0,
                    freeBytes: 0,
                    isFixture: true
                )
            )
        }

        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsBrowsableKey,
        ]
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        for url in mounted {
            let path = url.path
            guard path != "/" else { continue }
            guard let info = await diskInfo.diskInfo(forMountPath: path), info.qualifiesAsCard else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = values?.volumeName ?? url.lastPathComponent
            result.append(
                RemovableVolume(
                    name: name,
                    url: url,
                    totalBytes: Int64(values?.volumeTotalCapacity ?? 0),
                    freeBytes: Int64(values?.volumeAvailableCapacity ?? 0)
                )
            )
        }

        return result
    }

    /// Eject a volume via `diskutil eject`. Throws when diskutil reports a failure.
    public static func eject(_ url: URL) throws {
        let result = ProcessRunner.runCapturing(
            executable: "/usr/sbin/diskutil",
            arguments: ["eject", url.path],
            timeout: 15
        )
        guard let result, result.status == 0 else {
            let message = result?.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BackupError.copyFailed(
                file: url.lastPathComponent,
                reason: (message?.isEmpty == false ? message! : "eject failed")
            )
        }
    }
}
