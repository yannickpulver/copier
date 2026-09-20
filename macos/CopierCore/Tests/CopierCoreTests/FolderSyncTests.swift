import Foundation
import Testing
@testable import CopierCore

/// Ported from `src/lib/sync.test.ts`.
@Suite("FolderSync.diff")
struct FolderSyncDiffTests {
    private func file(_ relativePath: String, _ size: Int64, mtime: TimeInterval = 0) -> SyncFile {
        SyncFile(
            relativePath: relativePath,
            url: URL(fileURLWithPath: "/root/\(relativePath)"),
            name: relativePath.split(separator: "/").last.map(String.init) ?? relativePath,
            size: size,
            modificationDate: Date(timeIntervalSince1970: mtime)
        )
    }

    @Test("missing when no file with that name exists in dest")
    func missing() {
        let diff = FolderSync.diff(source: [file("a.jpg", 100)], destination: [file("b.jpg", 100)])
        #expect(diff.missing.map(\.name) == ["a.jpg"])
        #expect(diff.different.isEmpty)
        #expect(diff.present.isEmpty)
    }

    @Test("present when name+size match in a different subfolder")
    func presentAcrossFolders() {
        let source = file("sub/a.jpg", 100)
        let destination = file("other/deep/a.jpg", 100)
        let diff = FolderSync.diff(source: [source], destination: [destination])
        #expect(diff.present == [MatchedPair(source: source, destination: destination)])
        #expect(diff.missing.isEmpty)
        #expect(diff.different.isEmpty)
    }

    @Test("present when source is nested and dest is flat")
    func presentNestedSource() {
        let diff = FolderSync.diff(source: [file("x/y/z/a.jpg", 5)], destination: [file("a.jpg", 5)])
        #expect(diff.present.count == 1)
    }

    @Test("ignores mtime")
    func ignoresModificationDate() {
        let diff = FolderSync.diff(
            source: [file("a.jpg", 100, mtime: 999_999_999)],
            destination: [file("a.jpg", 100, mtime: 0)]
        )
        #expect(diff.present.count == 1)
        #expect(diff.different.isEmpty)
    }

    @Test("different when name matches but no candidate has the same size")
    func different() {
        let diff = FolderSync.diff(source: [file("a.jpg", 100)], destination: [file("sub/a.jpg", 200)])
        #expect(diff.different.count == 1)
        #expect(diff.different[0].destinationRelativePath == "sub/a.jpg")
        #expect(diff.missing.isEmpty)
        #expect(diff.present.isEmpty)
    }

    @Test("different at identical relPath does not set destinationRelativePath")
    func differentSamePath() {
        let diff = FolderSync.diff(source: [file("a.jpg", 100)], destination: [file("a.jpg", 200)])
        #expect(diff.different[0].destinationRelativePath == nil)
    }

    @Test("prefers exact relPath among several same-name same-size candidates")
    func prefersExactPath() {
        let source = file("sub/a.jpg", 100)
        let other = file("elsewhere/a.jpg", 100)
        let exact = file("sub/a.jpg", 100)
        let diff = FolderSync.diff(source: [source], destination: [other, exact])
        #expect(diff.present[0].destination.relativePath == exact.relativePath)
    }

    @Test("two sources sharing a name: size match is present, the other points at it")
    func twoSourcesSameName() {
        let a = file("A/a.jpg", 100)
        let b = file("B/a.jpg", 200)
        let destination = file("x/a.jpg", 100)
        let diff = FolderSync.diff(source: [a, b], destination: [destination])
        #expect(diff.present == [MatchedPair(source: a, destination: destination)])
        #expect(diff.different.count == 1)
        var expected = b
        expected.destinationRelativePath = "x/a.jpg"
        #expect(diff.different[0] == expected)
        #expect(diff.missing.isEmpty)
    }

    @Test("multi-candidate mixed sizes: matches the same size, not the first found")
    func mixedSizes() {
        let source = file("a.jpg", 100)
        let wrongSize = file("sub/a.jpg", 200)
        let rightSize = file("deep/a.jpg", 100)
        let diff = FolderSync.diff(source: [source], destination: [wrongSize, rightSize])
        #expect(diff.present == [MatchedPair(source: source, destination: rightSize)])
        #expect(diff.different.isEmpty)
        #expect(diff.missing.isEmpty)
    }
}

@Suite("FolderSync.copy")
struct FolderSyncCopyTests {
    @Test("always copies to the source relPath, never to destinationRelativePath")
    func copiesToSourceRelativePath() async throws {
        let root = try TempDirectory()
        let sourceDirectory = root.url.appendingPathComponent("src/B")
        let destinationRoot = root.url.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot.appendingPathComponent("x"), withIntermediateDirectories: true)

        let sourceFile = sourceDirectory.appendingPathComponent("a.jpg")
        try "source content".write(to: sourceFile, atomically: true, encoding: .utf8)
        // An existing candidate at the matched (but different) location must not be touched.
        try "existing content".write(
            to: destinationRoot.appendingPathComponent("x/a.jpg"),
            atomically: true,
            encoding: .utf8
        )

        let file = SyncFile(
            relativePath: "B/a.jpg",
            url: sourceFile,
            name: "a.jpg",
            size: Int64("source content".utf8.count),
            destinationRelativePath: "x/a.jpg"
        )

        let outcome = await FolderSync.copy(files: [file], destinationRoot: destinationRoot)
        #expect(outcome.failures.isEmpty)
        #expect(outcome.copied == 1)
        #expect(outcome.cancelled == false)

        let copied = try String(contentsOf: destinationRoot.appendingPathComponent("B/a.jpg"), encoding: .utf8)
        let untouched = try String(contentsOf: destinationRoot.appendingPathComponent("x/a.jpg"), encoding: .utf8)
        #expect(copied == "source content")
        #expect(untouched == "existing content")
    }

    @Test("walk skips dot files and stale partials")
    func walkSkips() async throws {
        let root = try TempDirectory()
        try FileManager.default.createDirectory(at: root.url.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "a".write(to: root.url.appendingPathComponent("sub/a.jpg"), atomically: true, encoding: .utf8)
        try "b".write(to: root.url.appendingPathComponent(".hidden.jpg"), atomically: true, encoding: .utf8)
        try "c".write(to: root.url.appendingPathComponent("b.jpg.copier-partial"), atomically: true, encoding: .utf8)

        let files = try await FolderSync.walk(root.url)
        #expect(files.map(\.relativePath) == ["sub/a.jpg"])
    }
}

/// A temporary directory that removes itself.
final class TempDirectory {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("copier-core-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
