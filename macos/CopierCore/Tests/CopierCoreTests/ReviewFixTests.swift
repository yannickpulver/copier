import Foundation
import Testing

@testable import CopierCore

// MARK: - Unreachable check paths

@Suite("LocalPathSource availability")
struct LocalPathSourceTests {
    @Test("a path that does not exist throws instead of reporting an empty index")
    func missingPathThrows() async throws {
        let source = LocalPathSource(CheckPath(path: "/Volumes/Definitely Not Mounted \(UUID().uuidString)"))
        await #expect(throws: BackupError.self) {
            _ = try await source.index(targetKeys: [], progress: nil)
        }
    }

    @Test("a file instead of a folder throws")
    func filePathThrows() async throws {
        let root = try TempDirectory()
        let file = root.url.appendingPathComponent("not-a-folder.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let source = LocalPathSource(CheckPath(path: file.path))
        await #expect(throws: BackupError.self) {
            _ = try await source.index(targetKeys: [], progress: nil)
        }
    }

    @Test("an unreachable path lands as a failed source, so the card is not declared new")
    func unreachableSourceFailsTheScan() async throws {
        let root = try TempDirectory()
        let card = root.url.appendingPathComponent("card")
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        try "photo".write(to: card.appendingPathComponent("IMG_1.JPG"), atomically: true, encoding: .utf8)

        let missing = CheckPath(path: root.url.appendingPathComponent("gone").path)
        let result = try await BackupScan().run(card: card, sources: [LocalPathSource(missing)])

        #expect(result.sources.count == 1)
        #expect(result.sources[0].succeeded == false)
        #expect(result.sources[0].errorDescription?.isEmpty == false)
        #expect(result.missing.count == 1)
    }

    @Test("a readable path still indexes")
    func readablePathIndexes() async throws {
        let root = try TempDirectory()
        let library = root.url.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try "photo".write(to: library.appendingPathComponent("IMG_1.JPG"), atomically: true, encoding: .utf8)

        let index = try await LocalPathSource(CheckPath(path: library.path)).index(targetKeys: [], progress: nil)
        #expect(index.count == 1)
    }
}

// MARK: - ProcessRunner

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    @Test("a child that fills stderr does not deadlock")
    func largeStderrDoesNotDeadlock() throws {
        let result = try #require(
            ProcessRunner.runCapturing(
                executable: "/bin/sh",
                arguments: ["-c", "yes x | head -c 200000 1>&2; echo done"],
                timeout: 20
            )
        )
        #expect(result.status == 0)
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == "done\n")
        #expect(result.standardError.count == 200_000)
    }

    @Test("both pipes are captured")
    func capturesBothPipes() throws {
        let result = try #require(
            ProcessRunner.runCapturing(
                executable: "/bin/sh",
                arguments: ["-c", "echo out; echo err 1>&2; exit 3"],
                timeout: 5
            )
        )
        #expect(result.status == 3)
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == "out\n")
        #expect(result.standardError == "err\n")
    }

    @Test("a hanging child hits the timeout and is terminated")
    func timeoutTerminates() throws {
        let started = Date()
        let result = ProcessRunner.runCapturing(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 30"],
            timeout: 0.3
        )
        #expect(result == nil)
        #expect(Date().timeIntervalSince(started) < 5)
    }
}

// MARK: - Synology form encoding

@Suite("Synology form encoding")
struct SynologyFormBodyTests {
    @Test("reserved characters in a password are percent-encoded")
    func encodesReservedCharacters() async throws {
        let transport = CannedTransport(responses: [:])
        let config = SynologyConfig(
            host: "nas.local",
            user: "yannick",
            password: "s3cret+pw&x=1",
            folders: ["/photo"]
        )
        let client = SynologyClient(config: config, transport: transport)
        try await client.login()

        let body = try #require(transport.loginBodies.first)
        #expect(body.contains("passwd=s3cret%2Bpw%26x%3D1"))
        // Every field stays its own key=value pair.
        let keys = body.split(separator: "&").map { $0.split(separator: "=")[0] }.sorted()
        #expect(keys == ["account", "api", "format", "method", "passwd", "session", "version"])
    }

    @Test("spaces and unicode survive a round trip")
    func encodesSpaces() {
        let body = String(decoding: SynologyClient.formBody(["passwd": "a b/ü"]), as: UTF8.self)
        #expect(body == "passwd=a%20b%2F%C3%BC")
    }
}

// MARK: - FinderTags

@Suite("FinderTags.read(urls:)")
struct FinderTagsReadTests {
    @Test("reads tags for known urls without walking the tree")
    func readsKnownURLs() throws {
        let root = try TempDirectory()
        let tagged = root.url.appendingPathComponent("tagged.jpg")
        let plain = root.url.appendingPathComponent("plain.jpg")
        try "a".write(to: tagged, atomically: true, encoding: .utf8)
        try "b".write(to: plain, atomically: true, encoding: .utf8)
        try FinderTags.write(["Red\n6"], to: tagged)

        let tags = FinderTags.read(urls: [tagged, plain, root.url.appendingPathComponent("missing.jpg")])
        #expect(tags.count == 1)
        #expect(tags[tagged] == ["Red\n6"])
    }
}
