import Foundation

/// Smoothed transfer speed and time remaining, ported from `renderer.ts`.
///
/// The rate is updated at most every ``minimumInterval`` seconds and blended
/// `0.7 * previous + 0.3 * instantaneous`.
public struct SpeedEstimator: Sendable {
    /// Weight of the newest sample.
    public let smoothing: Double
    /// Minimum time between rate updates.
    public let minimumInterval: TimeInterval

    private var lastTime: TimeInterval?
    private var lastBytes: Int64 = 0

    /// Current smoothed speed in bytes per second. Zero until the first update lands.
    public private(set) var bytesPerSecond: Double = 0

    public init(smoothing: Double = 0.3, minimumInterval: TimeInterval = 0.5) {
        self.smoothing = smoothing
        self.minimumInterval = minimumInterval
    }

    /// Feed a progress sample. `time` is a monotonic clock in seconds
    /// (e.g. `ProcessInfo.processInfo.systemUptime`).
    public mutating func update(bytesDone: Int64, at time: TimeInterval) {
        guard let last = lastTime else {
            lastTime = time
            lastBytes = bytesDone
            return
        }
        let elapsed = time - last
        guard elapsed >= minimumInterval else { return }
        let instantaneous = Double(bytesDone - lastBytes) / elapsed
        bytesPerSecond = bytesPerSecond > 0
            ? bytesPerSecond * (1 - smoothing) + instantaneous * smoothing
            : instantaneous
        lastTime = time
        lastBytes = bytesDone
    }

    /// Seconds remaining, or `nil` while no speed is known yet.
    public func timeRemaining(bytesDone: Int64, bytesTotal: Int64) -> TimeInterval? {
        guard bytesPerSecond > 0, bytesTotal > 0 else { return nil }
        let remaining = Double(max(0, bytesTotal - bytesDone))
        return remaining / bytesPerSecond
    }

    /// `"45s"`, `"3m 12s"`, `"1h 04m"` — the format the Electron app shows.
    public static func formatTimeRemaining(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m \(total % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
