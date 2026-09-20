import Foundation

/// Blocking helper for the few command-line tools the core shells out to
/// (`diskutil`, `op`). Never call this from the main actor.
enum ProcessRunner {
    struct Result: Sendable {
        var status: Int32
        var standardOutput: Data
        var standardError: String
        /// `true` when the child was killed because it outlived `timeout`.
        var timedOut: Bool = false
    }

    /// Run an executable and return stdout, or `nil` when it fails / times out.
    static func run(executable: String, arguments: [String], timeout: TimeInterval) -> Data? {
        guard let result = runCapturing(executable: executable, arguments: arguments, timeout: timeout),
              result.status == 0
        else { return nil }
        return result.standardOutput
    }

    /// - Parameter environment: replaces the child's environment when given.
    /// - Returns: `nil` only when the process could not be started; a timeout comes
    ///   back as a result with ``Result/timedOut`` set, so callers can tell them apart.
    static func runCapturing(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]? = nil
    ) -> Result? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            return nil
        }

        // Both pipes are drained in parallel: reading one to EOF first deadlocks as
        // soon as the child fills the other pipe's 64 KB buffer, and the timeout loop
        // below would never be reached.
        let outDrain = PipeDrain(out.fileHandleForReading)
        let errDrain = PipeDrain(err.fileHandleForReading)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "copier.process-runner", attributes: .concurrent)
        queue.async(group: group) { outDrain.run() }
        queue.async(group: group) { errDrain.run() }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            let hardDeadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < hardDeadline {
                usleep(20_000)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = group.wait(timeout: .now() + 2)
            return Result(
                status: -1,
                standardOutput: outDrain.data,
                standardError: String(data: errDrain.data, encoding: .utf8) ?? "",
                timedOut: true
            )
        }
        process.waitUntilExit()
        _ = group.wait(timeout: .now() + 2)
        return Result(
            status: process.terminationStatus,
            standardOutput: outDrain.data,
            standardError: String(data: errDrain.data, encoding: .utf8) ?? ""
        )
    }

    /// Look up a tool in the usual Homebrew locations and then on `PATH`.
    static func locate(_ tool: String, extraDirectories: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]) -> String? {
        let fm = FileManager.default
        for dir in extraDirectories {
            let candidate = (dir as NSString).appendingPathComponent(tool)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = (String(dir) as NSString).appendingPathComponent(tool)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

/// Reads one pipe to EOF on a background queue.
private final class PipeDrain: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func run() {
        let read = handle.readDataToEndOfFile()
        lock.lock()
        buffer = read
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}
