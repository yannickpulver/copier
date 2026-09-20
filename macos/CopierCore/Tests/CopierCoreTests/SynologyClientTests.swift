import Foundation
import Testing
@testable import CopierCore

/// Serves canned JSON and records every request.
final class CannedTransport: SynologyTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: [Data]]
    private(set) var requestedFolders: [String] = []
    private(set) var loginBodies: [String] = []

    /// - Parameter responses: folder path -> one JSON body per page.
    init(responses: [String: [Data]]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> Data {
        respond(to: request)
    }

    private func respond(to request: URLRequest) -> Data {
        lock.lock()
        defer { lock.unlock() }

        guard let url = request.url else { return Self.failure }
        if url.path.hasSuffix("auth.cgi") {
            if let body = request.httpBody {
                loginBodies.append(String(decoding: body, as: UTF8.self))
            }
            return Data(#"{"success":true,"data":{"sid":"SID-1"}}"#.utf8)
        }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let folder = items.first { $0.name == "folder_path" }?.value ?? ""
        let offset = Int(items.first { $0.name == "offset" }?.value ?? "0") ?? 0
        let limit = Int(items.first { $0.name == "limit" }?.value ?? "0") ?? 0
        requestedFolders.append("\(folder)@\(offset)")

        guard let pages = responses[folder] else { return Self.emptyPage }
        let page = offset / max(limit, 1)
        return page < pages.count ? pages[page] : Self.emptyPage
    }

    static let failure = Data(#"{"success":false,"error":{"code":119}}"#.utf8)
    static let emptyPage = Data(#"{"success":true,"data":{"files":[]}}"#.utf8)

    static func page(files: [(String, Int, Bool)], folder: String) -> Data {
        let entries = files.map { name, size, isDirectory in
            """
            {"name":"\(name)","path":"\(folder)/\(name)","isdir":\(isDirectory),"additional":{"size":\(size)}}
            """
        }
        return Data(#"{"success":true,"data":{"files":[\#(entries.joined(separator: ","))]}}"#.utf8)
    }
}

@Suite("SynologyClient")
struct SynologyClientTests {
    private let config = SynologyConfig(
        host: "nas.local",
        port: 5001,
        user: "user",
        password: "secret",
        secure: true,
        folders: ["/photo"]
    )

    @Test("login posts the credentials and stores the session id")
    func login() async throws {
        let transport = CannedTransport(responses: [:])
        let client = SynologyClient(config: config, transport: transport)
        try await client.login()
        #expect(await client.isLoggedIn)
        let body = try #require(transport.loginBodies.first)
        #expect(body.contains("api=SYNO.API.Auth"))
        #expect(body.contains("method=login"))
        #expect(body.contains("passwd=secret"))
        #expect(body.contains("session=FileStation"))
    }

    @Test("a rejected login throws nasUnreachable")
    func loginFails() async {
        final class Rejecting: SynologyTransport, @unchecked Sendable {
            func send(_ request: URLRequest) async throws -> Data { CannedTransport.failure }
        }
        let client = SynologyClient(config: config, transport: Rejecting())
        await #expect(throws: BackupError.self) { try await client.login() }
    }

    @Test("indexes files by name and size across paginated folders")
    func pagination() async throws {
        let transport = CannedTransport(responses: [
            "/photo": [
                CannedTransport.page(files: [("a.jpg", 10, false), ("b.jpg", 20, false)], folder: "/photo"),
                CannedTransport.page(files: [("c.jpg", 30, false)], folder: "/photo"),
            ]
        ])
        let client = SynologyClient(config: config, transport: transport, pageSize: 2)
        try await client.login()
        let index = try await client.index(folders: ["/photo"])

        #expect(index.count == 3)
        #expect(index.folders(for: FileKey(name: "c.jpg", size: 30))?.first?.path == "/photo")
        #expect(transport.requestedFolders == ["/photo@0", "/photo@2"])
    }

    @Test("walks subfolders newest first and stops once every key is found")
    func earlyExit() async throws {
        let transport = CannedTransport(responses: [
            "/photo": [CannedTransport.page(
                files: [("2020.01.01", 0, true), ("2026.09.18", 0, true)],
                folder: "/photo"
            )],
            "/photo/2026.09.18": [CannedTransport.page(files: [("new.jpg", 10, false)], folder: "/photo/2026.09.18")],
            "/photo/2020.01.01": [CannedTransport.page(files: [("old.jpg", 10, false)], folder: "/photo/2020.01.01")],
        ])
        let client = SynologyClient(config: config, transport: transport, pageSize: 5000)
        try await client.login()
        let index = try await client.index(folders: ["/photo"], targetKeys: [FileKey(name: "new.jpg", size: 10)])

        #expect(index.folders(for: FileKey(name: "new.jpg", size: 10)) != nil)
        #expect(index.folders(for: FileKey(name: "old.jpg", size: 10)) == nil)
        #expect(transport.requestedFolders == ["/photo@0", "/photo/2026.09.18@0"])
    }

    @Test("a folder that errors out is skipped, the walk continues")
    func skipsFailingFolder() async throws {
        let transport = CannedTransport(responses: [
            "/photo": [CannedTransport.page(files: [("broken", 0, true), ("zz", 0, true)], folder: "/photo")],
            "/photo/zz": [CannedTransport.page(files: [("a.jpg", 1, false)], folder: "/photo/zz")],
        ])
        let client = SynologyClient(config: config, transport: transport)
        try await client.login()
        let index = try await client.index(folders: ["/photo"])
        #expect(index.count == 1)
        #expect(index.folders(for: FileKey(name: "a.jpg", size: 1))?.first?.path == "/photo/zz")
    }
}
