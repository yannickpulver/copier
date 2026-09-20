import Foundation
import Testing

@testable import CopierCore

/// Writes throwaway `op` stand-ins, so the tests never touch the real 1Password CLI.
private struct FakeOp {
    let directory: TempDirectory
    let path: String

    init(script: String) throws {
        directory = try TempDirectory()
        let url = directory.url.appendingPathComponent("op")
        try ("#!/bin/sh\n" + script).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        path = url.path
    }
}

@Suite("CredentialResolver")
struct CredentialResolverTests {
    @Test("a literal value is passed through without running anything")
    func literalPassesThrough() async throws {
        let result = await CredentialResolver.read("plain-password", opPath: "/nonexistent/op")
        #expect(try result.get() == "plain-password")
        #expect(CredentialResolver.isReference("op://Vault/Item/password"))
        #expect(CredentialResolver.isReference("plain-password") == false)
    }

    @Test("a reference is read through op")
    func readsReference() async throws {
        let op = try FakeOp(script: #"printf 'hunter2'"#)
        let result = await CredentialResolver.read("op://Vault/Item/password", opPath: op.path)
        #expect(try result.get() == "hunter2")
    }

    @Test("op is called with read --no-newline and the reference")
    func passesExpectedArguments() async throws {
        let op = try FakeOp(script: #"printf '%s' "$*""#)
        let result = await CredentialResolver.read("op://Vault/Item/password", opPath: op.path)
        #expect(try result.get() == "read --no-newline op://Vault/Item/password")
    }

    @Test("a failing op surfaces its stderr")
    func surfacesStderr() async throws {
        let op = try FakeOp(script: #"echo "[ERROR] 2026/09/20 account is not signed in" 1>&2; exit 1"#)
        let result = await CredentialResolver.read("op://Vault/Item/password", opPath: op.path)
        guard case let .failure(problem) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(problem == .opFailed("[ERROR] 2026/09/20 account is not signed in"))
        #expect(problem.message == "1Password: [ERROR] 2026/09/20 account is not signed in")
    }

    @Test("an empty answer counts as a failure")
    func emptyValueFails() async throws {
        let op = try FakeOp(script: "exit 0")
        let result = await CredentialResolver.read("op://Vault/Item/password", opPath: op.path)
        #expect(result == .failure(.opFailed("the reference resolved to an empty value")))
    }

    @Test("a hanging op times out instead of blocking forever")
    func timesOut() async throws {
        let op = try FakeOp(script: "sleep 30")
        let started = Date()
        let result = await CredentialResolver.read("op://Vault/Item/password", opPath: op.path, timeout: 0.4)
        #expect(result == .failure(.opTimedOut))
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(CredentialProblem.opTimedOut.message.hasPrefix("1Password:"))
    }

    @Test("a missing op is named as such")
    func missingOp() async throws {
        let result = await CredentialResolver.read("op://Vault/Item/password", opPath: "/nonexistent/op")
        #expect(result == .failure(.opFailed("could not start /nonexistent/op")))
        #expect(CredentialProblem.opNotInstalled.message.contains("1password-cli"))
    }

    @Test("op runs with Homebrew on PATH and a HOME")
    func environmentIsSane() {
        let environment = CredentialResolver.opEnvironment
        let path = environment["PATH"] ?? ""
        #expect(path.contains("/opt/homebrew/bin"))
        #expect(path.contains("/usr/local/bin"))
        #expect(environment["HOME"]?.isEmpty == false)
    }

    @Test("a reference that cannot be read fails the whole config with its reason")
    func configReportsReferenceFailure() async throws {
        let defaults = UserDefaults(suiteName: "copier-core-tests-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        store.synologyHost = "nas.local"
        store.synologyUser = "yannick"
        store.synologyPassword = "op://Vault/Item/password"
        store.synologyFolders = ["/photo"]

        // A stub op that refuses, so the real 1Password is never touched.
        let op = try FakeOp(script: #"echo "[ERROR] item not found" 1>&2; exit 1"#)
        let result = await CredentialResolver.makeSynologyConfig(
            settings: store,
            keychain: KeychainStore(service: "copier.tests.\(UUID().uuidString)"),
            opPath: op.path
        )
        guard case let .failure(problem) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(problem == .opFailed("[ERROR] item not found"))
        #expect(problem.message == "1Password: [ERROR] item not found")
    }
}

@Suite("SynologyClient.listFolders")
struct SynologyListFoldersTests {
    @Test("subfolders come back as full paths, newest first, system folders skipped")
    func listsSubfolders() async throws {
        let listing = Data(
            """
            {"success":true,"data":{"files":[
              {"name":"2026","path":"/photo/2026","isdir":true},
              {"name":"2025","path":"/photo/2025","isdir":true},
              {"name":"@eaDir","path":"/photo/@eaDir","isdir":true},
              {"name":"cover.jpg","path":"/photo/cover.jpg","isdir":false}
            ]}}
            """.utf8
        )
        let transport = CannedTransport(responses: ["/photo": [listing]])
        let client = SynologyClient(
            config: SynologyConfig(host: "nas.local", user: "u", password: "p", folders: []),
            transport: transport
        )
        try await client.login()

        let folders = try await client.listFolders(in: "/photo")
        #expect(folders == ["/photo/2026", "/photo/2025"])
    }

    @Test("a folder the NAS refuses throws")
    func failingFolderThrows() async throws {
        let transport = CannedTransport(responses: ["/nope": [CannedTransport.failure]])
        let client = SynologyClient(
            config: SynologyConfig(host: "nas.local", user: "u", password: "p", folders: []),
            transport: transport
        )
        try await client.login()
        await #expect(throws: BackupError.self) {
            _ = try await client.listFolders(in: "/nope")
        }
    }
}
