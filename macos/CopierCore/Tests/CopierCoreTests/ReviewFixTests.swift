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
        // A timeout comes back flagged, so callers can tell it from a launch failure.
        #expect(result?.timedOut == true)
        #expect(result?.status != 0)
        #expect(ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "sleep 30"], timeout: 0.3) == nil)
        #expect(Date().timeIntervalSince(started) < 10)
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

// MARK: - NAS connection test plumbing

@Suite("Synology connection test")
struct SynologyConnectionTests {
    private func store(
        host: String? = "nas.local",
        user: String? = "yannick",
        password: String? = "pw",
        folders: [String] = []
    ) -> SettingsStore {
        let defaults = UserDefaults(suiteName: "copier-core-tests-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        store.synologyHost = host
        store.synologyUser = user
        store.synologyPassword = password
        store.synologyFolders = folders
        return store
    }

    @Test("a login-only config does not need shared folders")
    func loginConfigIgnoresFolders() async throws {
        let result = await CredentialResolver.makeSynologyConfig(
            settings: store(),
            keychain: KeychainStore(service: "copier.tests.\(UUID().uuidString)"),
            requireFolders: false
        )
        let config = try result.get()
        #expect(config.host == "nas.local")
        #expect(config.folders.isEmpty)
    }

    @Test("indexing still requires shared folders")
    func indexingRequiresFolders() async throws {
        let result = await CredentialResolver.makeSynologyConfig(
            settings: store(),
            keychain: KeychainStore(service: "copier.tests.\(UUID().uuidString)"),
            requireFolders: true
        )
        #expect(result == .failure(.missingFolders))
    }

    @Test("each missing field names itself")
    func missingFieldsAreNamed() async throws {
        let keychain = KeychainStore(service: "copier.tests.\(UUID().uuidString)")
        let noHost = await CredentialResolver.makeSynologyConfig(
            settings: store(host: nil), keychain: keychain, requireFolders: false
        )
        #expect(noHost == .failure(.missingHost))
        #expect(CredentialProblem.missingHost.message == "Host is missing.")

        let noUser = await CredentialResolver.makeSynologyConfig(
            settings: store(user: nil), keychain: keychain, requireFolders: false
        )
        #expect(noUser == .failure(.missingUser))

        let noPassword = await CredentialResolver.makeSynologyConfig(
            settings: store(password: nil), keychain: keychain, requireFolders: false
        )
        #expect(noPassword == .failure(.missingPassword))
        #expect(CredentialProblem.missingPassword.message == "Password is missing.")
    }

    @Test("login failures report the Synology reason")
    func loginFailureReason() {
        #expect(SynologyClient.loginErrorReason(400) == "wrong user name or password")
        #expect(SynologyClient.loginErrorReason(403) == "a two-step verification code is required")
        #expect(SynologyClient.loginErrorReason(1234) == "login failed (Synology error 1234)")
        #expect(SynologyClient.loginErrorReason(nil) == "login failed")
    }

    @Test("the share list comes back as paths")
    func listsShares() async throws {
        let shares = Data(
            #"{"success":true,"data":{"shares":[{"name":"photo","path":"/photo"},{"name":"video","path":"/video"}]}}"#.utf8
        )
        let transport = CannedTransport(responses: ["": [shares]])
        let client = SynologyClient(
            config: SynologyConfig(host: "nas.local", user: "u", password: "p", folders: []),
            transport: transport
        )
        try await client.login()
        #expect(try await client.listShares() == ["/photo", "/video"])
    }
}
