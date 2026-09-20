import Foundation
import Testing
@testable import CopierCore

@Suite("Scanner")
struct ScannerTests {
    /// `dev-fixtures/test-sd` in the repo, five directories above this file.
    static var fixtureCard: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CopierCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // CopierCore
            .deletingLastPathComponent()   // macos
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("dev-fixtures/test-sd")
    }

    @Test("scans the dev fixture card", .enabled(if: FileManager.default.fileExists(atPath: ScannerTests.fixtureCard.path)))
    func scansFixture() async throws {
        var files = try await Scanner.scan(volume: Self.fixtureCard)
        #expect(files.count == 11)
        #expect(files.filter(\.isMedia).count == files.count)
        #expect(files.contains { $0.relativePath == "DCIM/100CANON/IMG_0001.JPG" })
        #expect(files.filter { $0.modificationDate != nil }.count == files.count)

        // DJI panorama file names repeat across subfolders and get disambiguated.
        Scanner.disambiguateDuplicateNames(&files)
        let names = Set(files.map(\.name))
        #expect(names.contains("100_0001_DJI_0001.JPG"))
        #expect(names.contains("100_0002_DJI_0001.JPG"))
        #expect(names.count == files.count)
    }

    @Test("skips hidden and system directories")
    func skipsHidden() async throws {
        let root = try TempDirectory()
        let fm = FileManager.default
        for folder in [".Trashes", ".Spotlight-V100", "__MACOSX", "DCIM"] {
            try fm.createDirectory(at: root.url.appendingPathComponent(folder), withIntermediateDirectories: true)
            try "x".write(to: root.url.appendingPathComponent("\(folder)/a.jpg"), atomically: true, encoding: .utf8)
        }
        try "x".write(to: root.url.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        try "note".write(to: root.url.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let files = try await Scanner.scan(volume: root.url)
        #expect(files.map(\.relativePath).sorted() == ["DCIM/a.jpg", "notes.txt"])
        #expect(files.first { $0.name == "notes.txt" }?.isMedia == false)
        #expect(files.first { $0.name == "a.jpg" }?.size == 1)
    }

    @Test("media extensions cover photos, raw, video and sidecars")
    func mediaExtensions() {
        #expect(MediaExtensions.isMedia("IMG.JPG"))
        #expect(MediaExtensions.isMedia("IMG.cr3"))
        #expect(MediaExtensions.isMedia("clip.MP4"))
        #expect(MediaExtensions.isMedia("IMG.xmp"))
        #expect(MediaExtensions.isSidecar("IMG.AAE"))
        #expect(!MediaExtensions.isMedia("notes.txt"))
        #expect(!MediaExtensions.isMedia("noextension"))
    }

    @Test("names are only disambiguated when they actually collide")
    func disambiguation() {
        func file(_ relativePath: String) -> MediaFile {
            MediaFile(
                name: relativePath.split(separator: "/").last.map(String.init) ?? relativePath,
                url: URL(fileURLWithPath: "/card/\(relativePath)"),
                relativePath: relativePath,
                size: 1,
                isMedia: true
            )
        }
        var files = [file("A/x.jpg"), file("B/x.jpg"), file("C/unique.jpg")]
        Scanner.disambiguateDuplicateNames(&files)
        #expect(files.map(\.name) == ["A_x.jpg", "B_x.jpg", "unique.jpg"])
        // The copy source is untouched.
        #expect(files[0].url.path == "/card/A/x.jpg")
    }
}

@Suite("VolumeLister")
struct VolumeListerTests {
    @Test("the card rule matches removable, external, SD and USB/Thunderbolt volumes")
    func cardRule() {
        #expect(DiskInfo(removableMedia: true).qualifiesAsCard)
        #expect(DiskInfo(external: true).qualifiesAsCard)
        #expect(DiskInfo(ioRegistryEntryName: "Built In Secure Digital").qualifiesAsCard)
        #expect(DiskInfo(busProtocol: "USB").qualifiesAsCard)
        #expect(DiskInfo(busProtocol: "Thunderbolt").qualifiesAsCard)
        #expect(!DiskInfo(busProtocol: "PCI-Express", solidState: true).qualifiesAsCard)
    }

    @Test("parses a diskutil info plist")
    func parsesPlist() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>RemovableMedia</key><true/>
          <key>External</key><true/>
          <key>IORegistryEntryName</key><string>Secure Digital Card</string>
          <key>BusProtocol</key><string>USB</string>
          <key>SolidState</key><false/>
        </dict></plist>
        """
        let info = try #require(DiskInfo(plistData: Data(plist.utf8)))
        #expect(info.removableMedia)
        #expect(info.busProtocol == "USB")
        #expect(info.qualifiesAsCard)
    }

    @Test("the injected fixture card is listed first")
    func fixtureCard() async throws {
        struct NoDisks: DiskInfoProviding {
            func diskInfo(forMountPath path: String) async -> DiskInfo? { nil }
        }
        let root = try TempDirectory()
        let lister = VolumeLister(diskInfo: NoDisks(), fixtureCard: root.url)
        let volumes = await lister.list()
        #expect(volumes.first?.isFixture == true)
        #expect(volumes.first?.url == root.url)

        let missing = VolumeLister(diskInfo: NoDisks(), fixtureCard: root.url.appendingPathComponent("nope"))
        #expect(await missing.list().isEmpty)
    }
}

@Suite("SettingsStore")
struct SettingsStoreTests {
    private func makeStore() throws -> (SettingsStore, UserDefaults) {
        let suiteName = "copier-core-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (SettingsStore(defaults: defaults), defaults)
    }

    @Test("defaults match the Electron store")
    func defaults() throws {
        let (store, _) = try makeStore()
        #expect(store.checkPaths.isEmpty)
        #expect(store.transferDestinations.isEmpty)
        #expect(store.selectedDestination == nil)
        #expect(store.synologyPort == 5001)
        #expect(store.synologySecure)
        #expect(store.synologyFolders.isEmpty)
        #expect(store.dateFormat == "YYYY.MM.DD")
        #expect(store.structure == .folderPerDay)
        #expect(store.cameraSubfolders == false)
        #expect(store.syncAppendSourceName == false)
    }

    @Test("round-trips every value")
    func roundTrip() throws {
        let (store, _) = try makeStore()
        store.checkPaths = [CheckPath(path: "/Volumes/NAS"), CheckPath(path: "/Volumes/Backup", fallbackOnly: true)]
        store.transferDestinations = ["/Volumes/SSD"]
        store.selectedDestination = "/Volumes/SSD"
        store.synologyHost = "nas.local"
        store.synologyPort = 5000
        store.synologyUser = "op://vault/nas/username"
        store.synologyPassword = "op://vault/nas/password"
        store.synologySecure = false
        store.synologyFolders = ["/photo", "/video"]
        store.dateFormat = "YY-MM-DD"
        store.structure = .oneFolder
        store.cameraSubfolders = true
        store.syncSource = "/src"
        store.syncTarget = "/dst"
        store.syncAppendSourceName = true

        #expect(store.checkPaths.map(\.fallbackOnly) == [false, true])
        #expect(store.checkPaths[1].label == "Backup")
        #expect(store.transferDestinations == ["/Volumes/SSD"])
        #expect(store.synologyPort == 5000)
        #expect(store.synologySecure == false)
        #expect(store.synologyFolders == ["/photo", "/video"])
        #expect(store.dateFormat == "YY-MM-DD")
        #expect(store.structure == .oneFolder)
        #expect(store.cameraSubfolders)
        #expect(store.syncAppendSourceName)
        #expect(CredentialResolver.isReference(store.synologyPassword ?? ""))

        store.reset()
        #expect(store.checkPaths.isEmpty)
        #expect(store.dateFormat == "YYYY.MM.DD")
    }

    @Test("syncSources round-trips a list")
    func syncSourcesRoundTrip() throws {
        let (store, _) = try makeStore()
        store.syncSources = ["/src/A", "/src/B"]
        #expect(store.syncSources == ["/src/A", "/src/B"])
    }

    @Test("syncSources falls back to the legacy syncSource when the list key is unset")
    func syncSourcesFallsBackToLegacy() throws {
        let (store, _) = try makeStore()
        store.syncSource = "/src/legacy"
        #expect(store.syncSources == ["/src/legacy"])
    }

    @Test("an explicit empty syncSources list means no sources, and does not fall back")
    func syncSourcesExplicitEmptyDoesNotFallBack() throws {
        let (store, _) = try makeStore()
        store.syncSource = "/src/legacy"
        store.syncSources = []
        #expect(store.syncSources.isEmpty)
    }
}
