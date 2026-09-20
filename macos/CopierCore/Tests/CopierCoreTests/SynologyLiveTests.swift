import Foundation
import Testing
@testable import CopierCore

/// Talks to a real NAS. Runs only when `COPIER_LIVE_NAS_HOST` is set, e.g.
/// `COPIER_LIVE_NAS_HOST=nas.local COPIER_LIVE_NAS_USER=me COPIER_LIVE_NAS_PASSWORD=… swift test --filter SynologyLive`.
@Suite("SynologyLive", .enabled(if: ProcessInfo.processInfo.environment["COPIER_LIVE_NAS_HOST"] != nil))
struct SynologyLiveTests {
    @Test("real transport accepts the self-signed certificate")
    func selfSignedCertificate() async throws {
        let host = ProcessInfo.processInfo.environment["COPIER_LIVE_NAS_HOST"]!
        let url = URL(string: "https://\(host):5001/webapi/query.cgi?api=SYNO.API.Info&version=1&method=query&query=SYNO.API.Auth")!
        let data = try await URLSessionSynologyTransport().send(URLRequest(url: url))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["success"] as? Bool == true)
    }

    @Test("login and list shares with the stored credentials")
    func loginAndListShares() async throws {
        let host = ProcessInfo.processInfo.environment["COPIER_LIVE_NAS_HOST"]!
        let user = try #require(ProcessInfo.processInfo.environment["COPIER_LIVE_NAS_USER"])
        let password = try #require(ProcessInfo.processInfo.environment["COPIER_LIVE_NAS_PASSWORD"])
        let client = SynologyClient(config: SynologyConfig(host: host, user: user, password: password, folders: []))
        let start = Date()
        try await client.login()
        let shares = try await client.listShares()
        await client.logout()
        print("live NAS: \(shares.count) shares in \(Date().timeIntervalSince(start))s: \(shares)")
        #expect(!shares.isEmpty)
    }
}
