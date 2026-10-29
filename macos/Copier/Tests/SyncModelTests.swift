import CopierCore
import Foundation
import Testing

/// A source and a target folder on disk, removed again by `remove()`.
private struct SyncFixture {
    let root: URL
    var source: URL { root.appendingPathComponent("2026.05.16 – Bath") }
    var target: URL { root.appendingPathComponent("Target") }

    /// `files` are `relative path: size` pairs under the source or the target.
    init(source: [String: Int], target: [String: Int]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("copier-sync-\(UUID().uuidString)")
        try Self.write(source, under: root.appendingPathComponent("2026.05.16 – Bath"))
        try Self.write(target, under: root.appendingPathComponent("Target"))
    }

    private static func write(_ files: [String: Int], under folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (path, size) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: size).write(to: url)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func makeModel(_ fixture: SyncFixture) -> SyncModel {
    let settings = SettingsStore(defaults: UserDefaults(suiteName: "copier-sync-tests-\(UUID().uuidString)")!)
    let model = SyncModel(settings: settings)
    model.appendSourceName = false
    model.syncFinderTags = false
    model.target = fixture.target
    model.sources = [fixture.source]
    return model
}

@MainActor
private func compare(_ model: SyncModel) async throws {
    model.compare()
    for _ in 0..<600 {
        if case .compared = model.phase { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Timed out waiting for the compare")
}

@MainActor
@Suite("SyncModel")
struct SyncModelTests {
    @Test("Files are grouped by folder, top-level files under the source folder's name")
    func groupsByFolder() async throws {
        let fixture = try SyncFixture(
            source: ["export/a.jpg": 10, "export/b.jpg": 20, "top.jpg": 5, "RAW/c.arw": 30],
            target: ["export/a.jpg": 10]
        )
        defer { fixture.remove() }
        let model = makeModel(fixture)
        try await compare(model)

        let groups = model.fileGroups
        #expect(groups.map(\.title) == ["2026.05.16 – Bath", "export", "RAW"])
        #expect(groups[1].rows.map(\.name) == ["b.jpg"])
        #expect(groups[2].bytes == 30)
        // A short list opens every group.
        #expect(model.expandedGroups == Set(groups.map(\.id)))
    }

    @Test("A long list starts closed, unless it is a single group")
    func longListStartsClosed() async throws {
        var files: [String: Int] = [:]
        for index in 0...SyncModel.openListLimit { files["export/\(index).jpg"] = 10 }
        files["top.jpg"] = 5
        let fixture = try SyncFixture(source: files, target: [:])
        defer { fixture.remove() }
        let model = makeModel(fixture)
        try await compare(model)
        #expect(model.expandedGroups.isEmpty)

        files["top.jpg"] = nil
        let single = try SyncFixture(source: files, target: [:])
        defer { single.remove() }
        let singleModel = makeModel(single)
        try await compare(singleModel)
        #expect(singleModel.expandedGroups == ["export"])
    }

    @Test("Identical files are counted, a file with another size is marked as replaced")
    func countsIdenticalAndReplaced() async throws {
        let fixture = try SyncFixture(
            source: ["a.jpg": 10, "b.jpg": 20, "c.jpg": 30],
            target: ["a.jpg": 10, "b.jpg": 99]
        )
        defer { fixture.remove() }
        let model = makeModel(fixture)
        try await compare(model)

        #expect(model.identicalCount == 1)
        let rows = model.fileGroups.flatMap(\.rows)
        #expect(rows.first { $0.name == "b.jpg" }?.replaces == true)
        #expect(rows.first { $0.name == "c.jpg" }?.replaces == false)
    }

    @Test("Changing the sources clears the open groups")
    func resetClearsGroups() async throws {
        let fixture = try SyncFixture(source: ["export/a.jpg": 10], target: [:])
        defer { fixture.remove() }
        let model = makeModel(fixture)
        try await compare(model)
        #expect(!model.expandedGroups.isEmpty)

        model.sources = []
        #expect(model.expandedGroups.isEmpty)
    }
}
