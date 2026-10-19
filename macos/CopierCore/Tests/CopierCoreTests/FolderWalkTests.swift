import Foundation
import Testing
@testable import CopierCore

/// An in-memory folder tree that records which folders were fully listed.
final class FakeBrowser: FolderBrowser, @unchecked Sendable {
    struct Folder {
        var modified: Date
        var files: [FileKey]
        var fails = false
    }

    private let lock = NSLock()
    private var tree: [String: Folder]
    private(set) var listed: [String] = []

    init(_ tree: [String: Folder]) { self.tree = tree }

    func set(_ path: String, _ folder: Folder?) {
        lock.withLock { tree[path] = folder }
    }

    func resetLog() { lock.withLock { listed = [] } }

    func list(_ folder: String) async throws -> FolderListing {
        try lock.withLock {
            listed.append(folder)
            if tree[folder]?.fails == true { throw BackupError.cancelled }
            return FolderListing(files: tree[folder]?.files ?? [], subfolders: children(of: folder))
        }
    }

    func subfolders(of folder: String, cached: [String]) async throws -> [Subfolder] {
        lock.withLock { children(of: folder) }
    }

    private func children(of folder: String) -> [Subfolder] {
        tree.filter { ($0.key as NSString).deletingLastPathComponent == folder }
            .map { Subfolder(path: $0.key, modified: $0.value.modified) }
    }
}

@Suite("FolderWalk")
struct FolderWalkTests {
    private let day1 = Date(timeIntervalSince1970: 1_000)
    private let day2 = Date(timeIntervalSince1970: 2_000)
    private let a = FileKey(name: "a.jpg", size: 1)
    private let b = FileKey(name: "b.jpg", size: 2)

    private func makeBrowser() -> FakeBrowser {
        FakeBrowser([
            "/nas": .init(modified: day1, files: []),
            "/nas/2026.01.01": .init(modified: day1, files: [a]),
            "/nas/2026.01.01/Sony": .init(modified: day1, files: [b]),
        ])
    }

    @Test("a second walk takes unchanged folders from the cache")
    func unchangedFromCache() async throws {
        let directory = try TempDirectory()
        let cacheFile = directory.url.appendingPathComponent("cache.json")
        let browser = makeBrowser()

        let first = try await FolderWalk.index(roots: ["/nas"], browser: browser, cacheFile: cacheFile)
        #expect(first.count == 2)
        #expect(browser.listed == ["/nas", "/nas/2026.01.01", "/nas/2026.01.01/Sony"])

        browser.resetLog()
        let second = try await FolderWalk.index(roots: ["/nas"], browser: browser, cacheFile: cacheFile)
        #expect(second.count == 2)
        #expect(second.folders(for: b)?.first?.path == "/nas/2026.01.01/Sony")
        // Roots are always read; everything below came from the cache.
        #expect(browser.listed == ["/nas"])
    }

    @Test("a folder with a new modification date is read again")
    func changedFolderIsRead() async throws {
        let directory = try TempDirectory()
        let cacheFile = directory.url.appendingPathComponent("cache.json")
        let browser = makeBrowser()
        _ = try await FolderWalk.index(roots: ["/nas"], browser: browser, cacheFile: cacheFile)

        let added = FileKey(name: "c.jpg", size: 3)
        browser.set("/nas/2026.01.01/Sony", .init(modified: day2, files: [b, added]))
        browser.resetLog()
        let index = try await FolderWalk.index(roots: ["/nas"], browser: browser, cacheFile: cacheFile)

        #expect(index.folders(for: added) != nil)
        #expect(browser.listed == ["/nas", "/nas/2026.01.01/Sony"])
    }

    @Test("a folder that fails to list is not cached and is retried")
    func failureNotCached() async throws {
        let directory = try TempDirectory()
        let cacheFile = directory.url.appendingPathComponent("cache.json")
        let browser = makeBrowser()
        browser.set("/nas/2026.01.01/Sony", .init(modified: day1, files: [b], fails: true))

        let first = try await FolderWalk.index(roots: ["/nas"], browser: browser, cacheFile: cacheFile)
        #expect(first.folders(for: b) == nil)

        browser.set("/nas/2026.01.01/Sony", .init(modified: day1, files: [b]))
        browser.resetLog()
        let second = try await FolderWalk.index(roots: ["/nas"], browser: browser, cacheFile: cacheFile)
        #expect(second.folders(for: b) != nil)
        #expect(browser.listed == ["/nas", "/nas/2026.01.01/Sony"])
    }

    @Test("a full walk drops removed folders, an early stop keeps unvisited ones")
    func pruning() async throws {
        let directory = try TempDirectory()
        let cacheFile = directory.url.appendingPathComponent("cache.json")
        let browser = makeBrowser()
        browser.set("/nas/2020.01.01", .init(modified: day1, files: [FileKey(name: "old.jpg", size: 9)]))
        _ = try await FolderWalk.index(roots: ["/nas"], browser: browser, cacheFile: cacheFile)

        // Stops in the newest folder, so the 2020 folder stays cached.
        _ = try await FolderWalk.index(roots: ["/nas"], browser: browser, targetKeys: [a], cacheFile: cacheFile)
        #expect(FolderCache.load(from: cacheFile).folders["/nas/2020.01.01"] != nil)

        browser.set("/nas/2020.01.01", nil)
        browser.set("/nas", .init(modified: day2, files: []))
        _ = try await FolderWalk.index(roots: ["/nas"], browser: browser, cacheFile: cacheFile)
        #expect(FolderCache.load(from: cacheFile).folders["/nas/2020.01.01"] == nil)
        #expect(FolderCache.load(from: cacheFile).folders["/nas/2026.01.01/Sony"] != nil)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test("folders dated before notBefore are skipped, undated ones are walked")
    func skipsOldDatedFolders() async throws {
        let browser = makeBrowser()
        browser.set("/nas/2025.12.31 - Party", .init(modified: day1, files: [FileKey(name: "old.jpg", size: 9)]))
        browser.set("/nas/2024", .init(modified: day1, files: []))
        browser.set("/nas/2024/2024-06-01", .init(modified: day1, files: []))
        browser.set("/nas/Exports", .init(modified: day1, files: []))

        let index = try await FolderWalk.index(roots: ["/nas"], browser: browser, notBefore: date(2026, 1, 1))

        #expect(index.folders(for: a) != nil)
        #expect(index.folders(for: FileKey(name: "old.jpg", size: 9)) == nil)
        #expect(Set(browser.listed) == ["/nas", "/nas/2026.01.01", "/nas/2026.01.01/Sony", "/nas/Exports"])
    }

    @Test("a year folder is walked while any of its days is in range")
    func yearFolderInRange() async throws {
        let browser = FakeBrowser([
            "/nas": .init(modified: day1, files: []),
            "/nas/2025": .init(modified: day1, files: []),
            "/nas/2025/2025.12.01": .init(modified: day1, files: [a]),
            "/nas/2025/2025.06.01": .init(modified: day1, files: [b]),
        ])
        let index = try await FolderWalk.index(roots: ["/nas"], browser: browser, notBefore: date(2025, 11, 15))
        #expect(index.folders(for: a) != nil)
        #expect(index.folders(for: b) == nil)
    }

    @Test("a full walk keeps the cache of skipped folders")
    func skippedFoldersStayCached() async throws {
        let directory = try TempDirectory()
        let cacheFile = directory.url.appendingPathComponent("cache.json")
        let browser = makeBrowser()
        browser.set("/nas/2020.01.01", .init(modified: day1, files: []))
        browser.set("/nas/2020.01.01/Sony", .init(modified: day1, files: [FileKey(name: "old.jpg", size: 9)]))
        _ = try await FolderWalk.index(roots: ["/nas"], browser: browser, cacheFile: cacheFile)

        _ = try await FolderWalk.index(roots: ["/nas"], browser: browser, notBefore: date(2026, 1, 1), cacheFile: cacheFile)
        let cache = FolderCache.load(from: cacheFile)
        #expect(cache.folders["/nas/2020.01.01"] != nil)
        #expect(cache.folders["/nas/2020.01.01/Sony"] != nil)
    }

    @Test("modification dates survive a save and load unchanged")
    func roundTrip() throws {
        let directory = try TempDirectory()
        let cacheFile = directory.url.appendingPathComponent("nested/cache.json")
        let date = Date(timeIntervalSince1970: 1_760_000_000.123456789)
        let cache = FolderCache(folders: ["/nas/x": CachedFolder(modified: date, files: [a], subfolders: ["/nas/x/y"])])
        try cache.save(to: cacheFile)
        #expect(FolderCache.load(from: cacheFile) == cache)
    }

    @Test("local paths: a file added to a cached folder is found on the next walk")
    func localFolderChange() async throws {
        let root = try TempDirectory()
        let cacheDirectory = try TempDirectory()
        let cacheFile = cacheDirectory.url.appendingPathComponent("cache.json")
        let fm = FileManager.default
        let shoot = root.url.appendingPathComponent("2026.01.01 - Trip/Sony")
        try fm.createDirectory(at: shoot, withIntermediateDirectories: true)
        try "x".write(to: shoot.appendingPathComponent("a.jpg"), atomically: true, encoding: .utf8)

        let first = await Matcher.indexLocalPath(root.url, cacheFile: cacheFile)
        #expect(first.folders(for: FileKey(name: "a.jpg", size: 1)) != nil)
        // The listing resolves /var to /private/var, so match on the tail.
        #expect(FolderCache.load(from: cacheFile).folders.keys.contains { $0.hasSuffix("/2026.01.01 - Trip/Sony") })

        try "yy".write(to: shoot.appendingPathComponent("b.jpg"), atomically: true, encoding: .utf8)
        let second = await Matcher.indexLocalPath(root.url, cacheFile: cacheFile)
        #expect(second.folders(for: FileKey(name: "a.jpg", size: 1)) != nil)
        #expect(second.folders(for: FileKey(name: "b.jpg", size: 2)) != nil)
    }
}
