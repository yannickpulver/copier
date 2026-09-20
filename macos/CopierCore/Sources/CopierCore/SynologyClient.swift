import Foundation

/// The HTTP layer of ``SynologyClient``, injectable so tests can serve canned JSON.
public protocol SynologyTransport: Sendable {
    /// Perform the request and return the raw response body.
    func send(_ request: URLRequest) async throws -> Data
}

/// `URLSession`-based transport. Tolerates the self-signed certificate Synology
/// boxes ship with, matching the Electron client (`rejectUnauthorized: false`).
public final class URLSessionSynologyTransport: NSObject, SynologyTransport, URLSessionDelegate, @unchecked Sendable {
    private let session: URLSession

    public init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        // `session` needs `self` as delegate, so build it after super.init.
        self.session = URLSession(configuration: configuration)
        super.init()
    }

    public func send(_ request: URLRequest) async throws -> Data {
        let delegate = InsecureTrustDelegate()
        let (data, _) = try await session.data(for: request, delegate: delegate)
        return data
    }

    /// Accepts the NAS's self-signed certificate. A per-task delegate only gets
    /// the task-level challenge callback, the session-level one is never called.
    final class InsecureTrustDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didReceive challenge: URLAuthenticationChallenge
        ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust
            else { return (.performDefaultHandling, nil) }
            return (.useCredential, URLCredential(trust: trust))
        }
    }
}

/// Minimal Synology FileStation client: log in, walk folders newest-first and
/// index every file by name and size.
public actor SynologyClient {
    /// Files requested per `SYNO.FileStation.List` page.
    public static let defaultPageSize = 5000

    private let config: SynologyConfig
    private let transport: any SynologyTransport
    private let pageSize: Int
    private var sessionID: String?

    /// - Parameter pageSize: page size for `SYNO.FileStation.List`; only lowered by tests.
    public init(
        config: SynologyConfig,
        transport: any SynologyTransport = URLSessionSynologyTransport(),
        pageSize: Int = defaultPageSize
    ) {
        self.config = config
        self.transport = transport
        self.pageSize = pageSize
    }

    /// `true` once ``login()`` succeeded.
    public var isLoggedIn: Bool { sessionID != nil }

    private var baseURL: URL {
        URL(string: "\(config.secure ? "https" : "http")://\(config.host):\(config.port)")!
    }

    /// Log in via `SYNO.API.Auth`. The password goes in a POST body so it never
    /// reaches proxy or NAS access logs.
    /// - Throws: ``BackupError/nasUnreachable(host:reason:)``.
    public func login() async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("webapi/auth.cgi"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "api": "SYNO.API.Auth",
            "version": "6",
            "method": "login",
            "account": config.user,
            "passwd": config.password,
            "session": "FileStation",
            "format": "sid",
        ])

        let response = try await perform(request)
        guard response.success, let sid = response.data?["sid"] as? String else {
            throw BackupError.nasUnreachable(
                host: config.host,
                reason: Self.loginErrorReason(response.errorCode)
            )
        }
        sessionID = sid
    }

    /// Synology's documented `SYNO.API.Auth` error codes, so the UI can show the real reason.
    static func loginErrorReason(_ code: Int?) -> String {
        switch code {
        case 400: return "wrong user name or password"
        case 401: return "the account is disabled"
        case 402: return "permission denied"
        case 403: return "a two-step verification code is required"
        case 404: return "the two-step verification code failed"
        case 406: return "two-step verification must be enforced"
        case 407: return "this IP address is blocked"
        case 408, 409, 410: return "the password is expired and must be changed"
        case let code?: return "login failed (Synology error \(code))"
        case nil: return "login failed"
        }
    }

    /// The NAS's shared folders, e.g. `["/photo", "/video"]`.
    /// Used by Settings to offer them instead of making the user type paths.
    public func listShares() async throws -> [String] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("webapi/entry.cgi"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.FileStation.List"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "list_share"),
            URLQueryItem(name: "limit", value: String(pageSize)),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "_sid", value: sessionID ?? ""),
        ]
        guard let url = components.url else { return [] }

        let response = try await perform(URLRequest(url: url))
        guard response.success, let raw = response.data?["shares"] as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            (entry["path"] as? String) ?? (entry["name"] as? String).map { "/\($0)" }
        }
    }

    /// Log out and drop the session id. Failures are ignored.
    public func logout() async {
        guard let sid = sessionID else { return }
        var components = URLComponents(url: baseURL.appendingPathComponent("webapi/auth.cgi"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.API.Auth"),
            URLQueryItem(name: "version", value: "6"),
            URLQueryItem(name: "method", value: "logout"),
            URLQueryItem(name: "session", value: "FileStation"),
            URLQueryItem(name: "_sid", value: sid),
        ]
        if let url = components.url {
            _ = try? await perform(URLRequest(url: url))
        }
        sessionID = nil
    }

    /// Index the configured folders.
    ///
    /// Folders are traversed newest-first (names sorted descending) and the walk
    /// stops as soon as every key in `targetKeys` has been found.
    public func index(
        folders: [String],
        targetKeys: Set<FileKey>? = nil,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> LocationIndex {
        var index = LocationIndex()
        var remaining = targetKeys
        var scanned = 0

        for root in folders {
            var stack: [String] = [root]
            while let folder = stack.popLast() {
                if Task.isCancelled { throw BackupError.cancelled }
                scanned += 1
                if scanned % 5 == 0 {
                    progress?(ScanProgress(count: scanned, folder: folder.split(separator: "/").last.map(String.init) ?? folder))
                }

                var subdirectories: [String] = []
                var offset = 0
                while true {
                    let response = try await list(folder: folder, offset: offset)
                    guard response.success, let items = response.files, !items.isEmpty else { break }
                    for item in items {
                        if item.isDirectory {
                            subdirectories.append(item.path)
                        } else {
                            let key = FileKey(name: item.name, size: item.size)
                            index.add(key, folder: URL(fileURLWithPath: folder))
                            remaining?.remove(key)
                        }
                    }
                    if items.count < pageSize { break }
                    offset += pageSize
                }

                if let remaining, remaining.isEmpty {
                    progress?(ScanProgress(count: scanned, folder: "done — all found"))
                    return index
                }

                // Ascending push, pop() takes from the end — newest folders first.
                stack.append(contentsOf: subdirectories.sorted())
            }
        }

        progress?(ScanProgress(count: scanned, folder: "done"))
        return index
    }

    /// The subfolders of one folder, e.g. `listFolders(in: "/photo")` → `["/photo/2026", …]`.
    /// Used by the Settings folder browser, so a subfolder can be picked without typing.
    public func listFolders(in path: String) async throws -> [String] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("webapi/entry.cgi"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.FileStation.List"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "list"),
            URLQueryItem(name: "folder_path", value: path),
            URLQueryItem(name: "filetype", value: "dir"),
            URLQueryItem(name: "limit", value: String(pageSize)),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "_sid", value: sessionID ?? ""),
        ]
        guard let url = components.url else { return [] }

        let response = try await perform(URLRequest(url: url))
        guard response.success, let raw = response.data?["files"] as? [[String: Any]] else {
            throw BackupError.nasUnreachable(host: config.host, reason: "could not list \(path)")
        }
        return raw
            .filter { ($0["isdir"] as? Bool) ?? false }
            .compactMap { entry in
                (entry["path"] as? String)
                    ?? (entry["name"] as? String).map { "\(path)/\($0)" }
            }
            .filter { !Matcher.isIgnored(directoryName: ($0 as NSString).lastPathComponent) }
            .sorted(by: >)
    }

    // MARK: - Requests

    private struct ListItem {
        var name: String
        var path: String
        var size: Int64
        var isDirectory: Bool
    }

    private struct ListResponse {
        var success: Bool
        var files: [ListItem]?
    }

    private func list(folder: String, offset: Int) async throws -> ListResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("webapi/entry.cgi"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.FileStation.List"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "list"),
            URLQueryItem(name: "folder_path", value: folder),
            URLQueryItem(name: "additional", value: "[\"size\"]"),
            URLQueryItem(name: "limit", value: String(pageSize)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "_sid", value: sessionID ?? ""),
        ]
        guard let url = components.url else { return ListResponse(success: false, files: nil) }

        let response: SynologyResponse
        do {
            response = try await perform(URLRequest(url: url))
        } catch {
            // A failing folder is skipped, as in the Electron client.
            return ListResponse(success: false, files: nil)
        }
        guard response.success, let raw = response.data?["files"] as? [[String: Any]] else {
            return ListResponse(success: response.success, files: nil)
        }
        let items = raw.map { entry in
            ListItem(
                name: entry["name"] as? String ?? "",
                path: entry["path"] as? String ?? "",
                size: ((entry["additional"] as? [String: Any])?["size"] as? NSNumber)?.int64Value ?? 0,
                isDirectory: (entry["isdir"] as? Bool) ?? false
            )
        }
        return ListResponse(success: true, files: items)
    }

    private struct SynologyResponse {
        var success: Bool
        var data: [String: Any]?
        var errorCode: Int?
    }

    private func perform(_ request: URLRequest) async throws -> SynologyResponse {
        let data: Data
        do {
            data = try await transport.send(request)
        } catch {
            throw BackupError.nasUnreachable(host: config.host, reason: error.localizedDescription)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BackupError.nasUnreachable(host: config.host, reason: "invalid JSON response")
        }
        return SynologyResponse(
            success: (json["success"] as? Bool) ?? false,
            data: json["data"] as? [String: Any],
            errorCode: ((json["error"] as? [String: Any])?["code"] as? NSNumber)?.intValue
        )
    }

    /// `application/x-www-form-urlencoded` body.
    ///
    /// Every field is percent-encoded against an unreserved set, because
    /// `URLComponents` leaves `+`, `&` and `=` untouched — a password containing any
    /// of them would be cut in half by the NAS.
    static func formBody(_ fields: [String: String]) -> Data {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        let pairs = fields.keys.sorted().map { key -> String in
            let name = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? key
            let raw = fields[key] ?? ""
            let value = raw.addingPercentEncoding(withAllowedCharacters: unreserved) ?? raw
            return "\(name)=\(value)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }
}
