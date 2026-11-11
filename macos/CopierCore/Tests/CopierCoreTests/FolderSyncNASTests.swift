import Foundation
import Testing
@testable import CopierCore

@Suite("FolderSync through the NAS API")
struct FolderSyncNASTests {
    private let day = Date(timeIntervalSince1970: 1_000)
    private let smb = URL(string: "smb://yannick@cube/yannick")!

    @Test("a folder on an SMB mount maps to its share path")
    func nasPathOnMount() {
        #expect(
            FolderSync.nasPath(localPath: "/Volumes/yannick/Photos/2026", volumePath: "/Volumes/yannick", remountURL: smb)
                == "/yannick/Photos/2026"
        )
        #expect(FolderSync.nasPath(localPath: "/Volumes/yannick/", volumePath: "/Volumes/yannick", remountURL: smb) == "/yannick")
    }

    @Test("a mount of a subfolder and an encoded share name map too")
    func nasPathSubfolderMount() {
        let url = URL(string: "smb://cube/My%20Photos/2026")!
        #expect(
            FolderSync.nasPath(localPath: "/Volumes/2026/Trip", volumePath: "/Volumes/2026", remountURL: url)
                == "/My Photos/2026/Trip"
        )
    }

    @Test("no NAS path off SMB or outside the volume")
    func nasPathNone() {
        let afp = URL(string: "afp://cube/yannick")!
        #expect(FolderSync.nasPath(localPath: "/Volumes/yannick/a", volumePath: "/Volumes/yannick", remountURL: afp) == nil)
        #expect(FolderSync.nasPath(localPath: "/Volumes/yannick-1/a", volumePath: "/Volumes/yannick", remountURL: smb) == nil)
        #expect(FolderSync.nasPath(of: URL(fileURLWithPath: NSTemporaryDirectory())) == nil)
    }

    @Test("same entries when the API lists what the mount shows, ignoring system folders")
    func sameEntries() async throws {
        let directory = try TempDirectory()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory.url.appendingPathComponent("Sony"), withIntermediateDirectories: true)
        fileManager.createFile(atPath: directory.url.appendingPathComponent("a.jpg").path, contents: Data([1]))
        fileManager.createFile(atPath: directory.url.appendingPathComponent(".DS_Store").path, contents: Data())

        let browser = FakeBrowser([
            "/nas": .init(modified: day, files: [FileKey(name: "a.jpg", size: 1)]),
            "/nas/Sony": .init(modified: day, files: []),
            "/nas/@eaDir": .init(modified: day, files: []),
        ])
        #expect(await FolderSync.sameEntries(nasFolder: "/nas", localFolder: directory.url, browser: browser))

        browser.set("/nas/Canon", .init(modified: day, files: []))
        #expect(!(await FolderSync.sameEntries(nasFolder: "/nas", localFolder: directory.url, browser: browser)))
    }

    @Test("not the same NAS when the API can't list the folder")
    func sameEntriesListFails() async throws {
        let directory = try TempDirectory()
        let browser = FakeBrowser(["/nas": .init(modified: day, files: [], fails: true)])
        #expect(!(await FolderSync.sameEntries(nasFolder: "/nas", localFolder: directory.url, browser: browser)))
    }

    @Test("the API walk returns relative paths under the mount, without partials")
    func walk() async throws {
        let a = FileKey(name: "a.jpg", size: 1)
        let browser = FakeBrowser([
            "/nas/Trip": .init(modified: day, files: [a, FileKey(name: "x.jpg.copier-partial", size: 9)]),
            "/nas/Trip/2026.01.01": .init(modified: day, files: [FileKey(name: "b.mp4", size: 2), a]),
            "/nas/Trip/@eaDir": .init(modified: day, files: [FileKey(name: "thumb.jpg", size: 3)]),
        ])
        let mount = URL(fileURLWithPath: "/Volumes/yannick/Trip")
        let files = try await FolderSync.walk(nasRoot: "/nas/Trip/", localRoot: mount, browser: browser)

        #expect(files.map(\.relativePath) == ["2026.01.01/a.jpg", "2026.01.01/b.mp4", "a.jpg"])
        #expect(files.map(\.size) == [1, 2, 1])
        #expect(files[0].url.path == "/Volumes/yannick/Trip/2026.01.01/a.jpg")
        #expect(files[0].name == "a.jpg")
    }

    @Test("names come back as the mount shows them, with SMB's private-use characters mapped")
    func mountNames() async throws {
        #expect(FolderSync.mountName("Walk w\u{F022} Steven") == "Walk w: Steven")
        #expect(FolderSync.mountName("a\u{F021}b\u{F025}\u{F027}") == "a*b?|")
        #expect(FolderSync.mountName("plain ü.jpg") == "plain ü.jpg")

        let browser = FakeBrowser([
            "/nas/Trip": .init(modified: day, files: []),
            "/nas/Trip/Walk w\u{F022} Steven": .init(modified: day, files: [FileKey(name: "a\u{F022}b.jpg", size: 1)]),
        ])
        let mount = URL(fileURLWithPath: "/Volumes/yannick/Trip")
        let files = try await FolderSync.walk(nasRoot: "/nas/Trip", localRoot: mount, browser: browser)
        #expect(files.map(\.relativePath) == ["Walk w: Steven/a:b.jpg"])
        #expect(files.map(\.name) == ["a:b.jpg"])

        let directory = try TempDirectory()
        try FileManager.default.createDirectory(
            at: directory.url.appendingPathComponent("Walk w: Steven"),
            withIntermediateDirectories: true
        )
        #expect(await FolderSync.sameEntries(nasFolder: "/nas/Trip", localFolder: directory.url, browser: browser))
    }

    @Test("target tags are read only where the source file has tags")
    func tagReadsNarrowed() {
        func file(_ root: String, _ path: String) -> SyncFile {
            SyncFile(relativePath: path, url: URL(fileURLWithPath: "\(root)/\(path)"), name: path, size: 1)
        }
        let tagged = file("/src", "tagged.jpg")
        let plain = file("/src", "plain.jpg")
        let replaced = file("/src", "replaced.jpg")
        let new = file("/src", "new.jpg")
        let diff = SyncDiff(
            missing: [new],
            different: [replaced],
            present: [
                MatchedPair(source: tagged, destination: file("/dst", "old/tagged.jpg")),
                MatchedPair(source: plain, destination: file("/dst", "plain.jpg")),
            ]
        )
        let sourceTags: [URL: [String]] = [
            tagged.url: ["Red\n6"], replaced.url: ["Blue\n4"], new.url: ["Green\n2"],
        ]

        let urls = TagPlanner.destinationsToRead(
            diff: diff,
            sourceTags: sourceTags,
            destinationRoot: URL(fileURLWithPath: "/dst")
        )
        #expect(urls.map(\.path) == ["/dst/old/tagged.jpg", "/dst/replaced.jpg"])
    }
}
