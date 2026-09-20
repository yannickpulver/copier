import Foundation
import Testing
@testable import CopierCore

@Suite("Matcher")
struct MatcherTests {
    private func media(_ name: String, _ size: Int64, relativePath: String? = nil) -> MediaFile {
        MediaFile(
            name: name,
            url: URL(fileURLWithPath: "/card/\(relativePath ?? name)"),
            relativePath: relativePath ?? name,
            size: size,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isMedia: true
        )
    }

    @Test("backed up = name + exact size found in any location")
    func nameAndSizeRule() {
        var index = LocationIndex()
        index.add(FileKey(name: "IMG_0001.JPG", size: 100), folder: URL(fileURLWithPath: "/nas/2026.01.01 - Trip"))
        let result = Matcher.checkBackedUp(
            files: [media("IMG_0001.JPG", 100), media("IMG_0002.JPG", 100), media("IMG_0001.JPG", 101, relativePath: "b/IMG_0001.JPG")],
            sources: [SourceIndex(name: "NAS", index: index)]
        )
        #expect(result.backedUp.map(\.relativePath) == ["IMG_0001.JPG"])
        #expect(result.missing.map(\.relativePath) == ["IMG_0002.JPG", "b/IMG_0001.JPG"])
    }

    @Test("suggests the date-level folder with source and count")
    func suggestsFolders() {
        var index = LocationIndex()
        let folder = URL(fileURLWithPath: "/nas/2026.01.01 - Trip/Sony")
        index.add(FileKey(name: "a.jpg", size: 1), folder: folder)
        index.add(FileKey(name: "b.jpg", size: 2), folder: folder)
        let result = Matcher.checkBackedUp(
            files: [media("a.jpg", 1), media("b.jpg", 2)],
            sources: [SourceIndex(name: "NAS", index: index)]
        )
        #expect(result.suggestedFolders.count == 1)
        #expect(result.suggestedFolders[0].folder.path == "/nas/2026.01.01 - Trip")
        #expect(result.suggestedFolders[0].count == 2)
        #expect(result.suggestedFolders[0].source == "NAS")
    }

    @Test("indexing skips ignored system folders")
    func ignoresSystemFolders() async throws {
        let root = try TempDirectory()
        let fm = FileManager.default
        for folder in ["@eaDir", "$RECYCLE.BIN", "#recycle", "keep"] {
            try fm.createDirectory(at: root.url.appendingPathComponent(folder), withIntermediateDirectories: true)
            try "x".write(to: root.url.appendingPathComponent("\(folder)/a.jpg"), atomically: true, encoding: .utf8)
        }
        try fm.createDirectory(at: root.url.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try "x".write(to: root.url.appendingPathComponent(".hidden/b.jpg"), atomically: true, encoding: .utf8)

        let index = await Matcher.indexLocalPath(root.url)
        let folders = index.folders(for: FileKey(name: "a.jpg", size: 1)) ?? []
        #expect(folders.count == 1)
        #expect(folders[0].lastPathComponent == "keep")
        #expect(index.folders(for: FileKey(name: "b.jpg", size: 1)) == nil)
    }

    @Test("indexing stops early once every target key is found")
    func earlyExit() async throws {
        let root = try TempDirectory()
        let fm = FileManager.default
        try fm.createDirectory(at: root.url.appendingPathComponent("2026.02.02"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.url.appendingPathComponent("2020.01.01"), withIntermediateDirectories: true)
        try "xx".write(to: root.url.appendingPathComponent("2026.02.02/new.jpg"), atomically: true, encoding: .utf8)
        try "xx".write(to: root.url.appendingPathComponent("2020.01.01/old.jpg"), atomically: true, encoding: .utf8)

        let index = await Matcher.indexLocalPath(root.url, targetKeys: [FileKey(name: "new.jpg", size: 2)])
        // Newest folder first, then stop — the old folder is never indexed.
        #expect(index.folders(for: FileKey(name: "new.jpg", size: 2)) != nil)
        #expect(index.folders(for: FileKey(name: "old.jpg", size: 2)) == nil)
    }

    @Test("date-level folder walks up to the YYYY.MM.DD ancestor")
    func dateLevelFolder() {
        #expect(
            Matcher.dateLevelFolder(URL(fileURLWithPath: "/nas/photo/2026.01.02 - Trip/Sony/sub")).path
                == "/nas/photo/2026.01.02 - Trip"
        )
        #expect(
            Matcher.dateLevelFolder(URL(fileURLWithPath: "/nas/photo/2026-01-02/Sony")).path
                == "/nas/photo/2026-01-02"
        )
        #expect(Matcher.dateLevelFolder(URL(fileURLWithPath: "/nas/photo/misc")).path == "/nas/photo/misc")
    }
}

@Suite("BackupScan source selection")
struct BackupScanSourceTests {
    private struct StubSource: BackupIndexSource {
        var name: String
        var kind: SourceKind
        var isFallbackOnly: Bool
        var succeeds: Bool
        var recorder: Recorder

        func index(
            targetKeys: Set<FileKey>,
            progress: (@Sendable (ScanProgress) -> Void)?
        ) async throws -> LocationIndex {
            await recorder.record(name)
            if !succeeds { throw BackupError.nasUnreachable(host: name, reason: "offline") }
            return LocationIndex()
        }
    }

    actor Recorder {
        private(set) var names: [String] = []
        func record(_ name: String) { names.append(name) }
    }

    private func makeCard() throws -> TempDirectory {
        let root = try TempDirectory()
        try "hello".write(to: root.url.appendingPathComponent("IMG_0001.JPG"), atomically: true, encoding: .utf8)
        return root
    }

    @Test("fallback source runs only when the API source failed")
    func fallbackRunsWhenAPIFails() async throws {
        let card = try makeCard()
        let recorder = Recorder()
        let sources: [any BackupIndexSource] = [
            StubSource(name: "Synology API", kind: .api, isFallbackOnly: false, succeeds: false, recorder: recorder),
            StubSource(name: "Backup", kind: .local, isFallbackOnly: true, succeeds: true, recorder: recorder),
        ]
        _ = try await BackupScan().run(card: card.url, sources: sources)
        #expect(await recorder.names == ["Synology API", "Backup"])
    }

    @Test("fallback source is skipped when the API source succeeded")
    func fallbackSkippedWhenAPIWorks() async throws {
        let card = try makeCard()
        let recorder = Recorder()
        let sources: [any BackupIndexSource] = [
            StubSource(name: "Synology API", kind: .api, isFallbackOnly: false, succeeds: true, recorder: recorder),
            StubSource(name: "Backup", kind: .local, isFallbackOnly: true, succeeds: true, recorder: recorder),
        ]
        _ = try await BackupScan().run(card: card.url, sources: sources)
        #expect(await recorder.names == ["Synology API"])
    }

    @Test("fast scan treats every media file as new and runs no source")
    func fastScan() async throws {
        let card = try makeCard()
        let recorder = Recorder()
        let sources: [any BackupIndexSource] = [
            StubSource(name: "Synology API", kind: .api, isFallbackOnly: false, succeeds: true, recorder: recorder)
        ]
        let result = try await BackupScan().run(card: card.url, sources: sources, skipCheck: true)
        #expect(await recorder.names.isEmpty)
        #expect(result.missing.map(\.name) == ["IMG_0001.JPG"])
        #expect(result.backedUp.isEmpty)
        // Metadata enrichment still ran: capture date falls back to the file mtime.
        #expect(result.missing[0].captureDate != nil)
    }
}
