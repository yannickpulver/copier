import Foundation
import Testing
@testable import CopierCore

/// Ported from `src/lib/tags.test.ts`.
@Suite("Finder tags")
struct FinderTagsTests {
    /// Real binary plist for ["Red\n6", "Holiday"].
    static let binaryPlistHex =
        "62706c6973743030a20102555265640a3657486f6c69646179080b11000000000000010100000000000000030000000000000000"
        + "0000000000000019"

    /// XML plist for ["Blue\n4"] as written by `xattr -w`.
    static let xmlPlist = """
    <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><array><string>Blue\n4</string></array></plist>
    """

    static func hexData(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    @Test("decodes binary plists (Finder-written)")
    func decodeBinary() {
        #expect(FinderTags.decode(Self.hexData(Self.binaryPlistHex)) == ["Red\n6", "Holiday"])
    }

    @Test("decodes XML plists")
    func decodeXML() {
        #expect(FinderTags.decode(Data(Self.xmlPlist.utf8)) == ["Blue\n4"])
    }

    @Test("round-trips through encode")
    func roundTrip() throws {
        let data = try FinderTags.encode(["Red\n6", "Trip"])
        #expect(FinderTags.decode(data) == ["Red\n6", "Trip"])
    }

    @Test("tag name strips the color suffix")
    func tagName() {
        #expect(FinderTags.name(of: "Red\n6") == "Red")
        #expect(FinderTags.name(of: "Holiday") == "Holiday")
    }

    @Test("merge adds source tags missing from target, target first")
    func merge() {
        #expect(FinderTags.merge(source: ["Red\n6", "Trip"], target: ["Blue\n4"]) == ["Blue\n4", "Red\n6", "Trip"])
    }

    @Test("merge returns nil when the target already has every source tag name")
    func mergeNothingToAdd() {
        #expect(FinderTags.merge(source: ["Red"], target: ["Red\n6", "Other"]) == nil)
        #expect(FinderTags.merge(source: [], target: ["Blue\n4"]) == nil)
        #expect(FinderTags.merge(source: ["Red\n6"], target: ["Red"]) == nil)
    }

    @Test("writes and reads tags through the xattr")
    func writeAndRead() throws {
        let root = try TempDirectory()
        let file = root.url.appendingPathComponent("a.jpg")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        #expect(FinderTags.read(at: file).isEmpty)
        try FinderTags.write(["Red\n6", "Trip"], to: file)
        #expect(FinderTags.read(at: file) == ["Red\n6", "Trip"])
    }
}

@Suite("TagPlanner")
struct TagPlannerTests {
    private func file(_ path: String) -> SyncFile {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return SyncFile(relativePath: name, url: URL(fileURLWithPath: path), name: name, size: 1)
    }

    private func sourceFile(_ relativePath: String) -> SyncFile {
        SyncFile(
            relativePath: relativePath,
            url: URL(fileURLWithPath: "/src/\(relativePath)"),
            name: relativePath.split(separator: "/").last.map(String.init) ?? relativePath,
            size: 1
        )
    }

    @Test("updates only where the source has tags the target lacks")
    func updatesOnlyWhereNeeded() {
        let pairs = [
            MatchedPair(source: file("/src/a.jpg"), destination: file("/dst/a.jpg")),
            MatchedPair(source: file("/src/b.jpg"), destination: file("/dst/b.jpg")),
            MatchedPair(source: file("/src/c.jpg"), destination: file("/dst/c.jpg")),
        ]
        let sourceTags: [URL: [String]] = [
            URL(fileURLWithPath: "/src/a.jpg"): ["Red\n6"],
            URL(fileURLWithPath: "/src/b.jpg"): ["Holiday"],
        ]
        let destinationTags: [URL: [String]] = [
            URL(fileURLWithPath: "/dst/b.jpg"): ["Holiday"],
            URL(fileURLWithPath: "/dst/c.jpg"): ["Keep"],
        ]
        let updates = TagPlanner.updates(for: pairs, sourceTags: sourceTags, destinationTags: destinationTags)
        #expect(updates == [
            TagUpdate(
                destinationURL: URL(fileURLWithPath: "/dst/a.jpg"),
                relativePath: "a.jpg",
                tags: ["Red\n6"],
                addedNames: ["Red"]
            )
        ])
    }

    @Test("merges into existing target tags")
    func mergesIntoTarget() {
        let pairs = [MatchedPair(source: file("/src/a.jpg"), destination: file("/dst/a.jpg"))]
        let updates = TagPlanner.updates(
            for: pairs,
            sourceTags: [URL(fileURLWithPath: "/src/a.jpg"): ["Red\n6", "Trip"]],
            destinationTags: [URL(fileURLWithPath: "/dst/a.jpg"): ["Trip", "Own"]]
        )
        #expect(updates[0].tags == ["Trip", "Own", "Red\n6"])
        #expect(updates[0].addedNames == ["Red"])
    }

    @Test("copy updates target destinationRoot/relPath with the source tags")
    func copyUpdates() {
        let updates = TagPlanner.copyUpdates(
            for: [sourceFile("B/a.jpg")],
            sourceTags: [URL(fileURLWithPath: "/src/B/a.jpg"): ["Red\n6", "Holiday"]],
            destinationTags: [:],
            destinationRoot: URL(fileURLWithPath: "/dst")
        )
        #expect(updates == [
            TagUpdate(
                destinationURL: URL(fileURLWithPath: "/dst/B/a.jpg"),
                relativePath: "B/a.jpg",
                tags: ["Red\n6", "Holiday"],
                addedNames: ["Red", "Holiday"]
            )
        ])
    }

    @Test("untagged file produces no copy update")
    func untaggedNoUpdate() {
        let updates = TagPlanner.copyUpdates(
            for: [sourceFile("a.jpg")],
            sourceTags: [:],
            destinationTags: [:],
            destinationRoot: URL(fileURLWithPath: "/dst")
        )
        #expect(updates.isEmpty)
    }

    @Test("overwrite case: union merge, destination tags first")
    func overwriteUnion() {
        let updates = TagPlanner.copyUpdates(
            for: [sourceFile("a.jpg")],
            sourceTags: [URL(fileURLWithPath: "/src/a.jpg"): ["Red\n6", "Trip"]],
            destinationTags: [URL(fileURLWithPath: "/dst/a.jpg"): ["Own"]],
            destinationRoot: URL(fileURLWithPath: "/dst")
        )
        #expect(updates == [
            TagUpdate(
                destinationURL: URL(fileURLWithPath: "/dst/a.jpg"),
                relativePath: "a.jpg",
                tags: ["Own", "Red\n6", "Trip"],
                addedNames: ["Red", "Trip"]
            )
        ])
    }

    @Test("no update when the destination path already has every source tag")
    func noUpdateWhenPresent() {
        let updates = TagPlanner.copyUpdates(
            for: [sourceFile("a.jpg")],
            sourceTags: [URL(fileURLWithPath: "/src/a.jpg"): ["Red\n6"]],
            destinationTags: [URL(fileURLWithPath: "/dst/a.jpg"): ["Red\n6", "Own"]],
            destinationRoot: URL(fileURLWithPath: "/dst")
        )
        #expect(updates.isEmpty)
    }
}
