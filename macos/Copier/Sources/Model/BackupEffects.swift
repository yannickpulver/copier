import Foundation

/// Side effects the backup model triggers but that do not belong to its logic:
/// the dock tile and the "backup finished" notification. Injected so tests stay silent.
@MainActor
protocol BackupEffects: AnyObject {
    /// 0…1 while copying, `nil` when there is nothing to show.
    func setDockProgress(_ fraction: Double?)
    /// Posted once a backup finished.
    func backupFinished(files: Int, failures: Int)
}

/// Does nothing — the default for tests and previews.
@MainActor
final class SilentBackupEffects: BackupEffects {
    func setDockProgress(_ fraction: Double?) {}
    func backupFinished(files: Int, failures: Int) {}
}

/// Fires a value on the main actor at most once per `interval`, from any thread.
///
/// CopierCore's progress callbacks arrive off the main actor and several hundred
/// times per second; this keeps the UI at roughly ten updates per second.
final class Throttle<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var lastFire: TimeInterval = 0
    private var issued: UInt64 = 0
    private var applied: UInt64 = 0
    private let interval: TimeInterval
    private let action: @MainActor @Sendable (Value) -> Void

    init(interval: TimeInterval = 0.1, action: @escaping @MainActor @Sendable (Value) -> Void) {
        self.interval = interval
        self.action = action
    }

    /// Deliver `value`, unless the previous delivery was less than `interval` ago.
    /// `force` always delivers and must be used for the last event of a run, otherwise
    /// the final counts can be the ones that get dropped.
    func send(_ value: Value, force: Bool = false) {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastFire >= interval else {
            lock.unlock()
            return
        }
        lastFire = now
        issued += 1
        let sequence = issued
        lock.unlock()

        let action = self.action
        Task { @MainActor in
            // Hops can land out of order; an older snapshot must never overwrite a
            // newer one, or the counters visibly run backwards.
            guard self.claim(sequence) else { return }
            action(value)
        }
    }

    private func claim(_ sequence: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard sequence > applied else { return false }
        applied = sequence
        return true
    }
}
