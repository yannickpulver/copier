import Foundation
import Testing
@testable import CopierCore

/// A copy streams: memory stays flat no matter how big the file is.
@Suite struct CopyMemoryTests {
    @Test func copyingABigFileKeepsMemoryFlat() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("copy-memory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("big.bin")
        let size: UInt64 = 512 * 1024 * 1024
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: size) // sparse, reads back as zeros
        try handle.close()

        let before = Self.footprint()
        let peak = PeakBox()
        try await Task.detached {
            try await TransferService.copyOne(
                from: source,
                to: folder.appendingPathComponent("copy.bin"),
                onBytes: { _ in peak.update(Self.footprint()) }
            )
        }.value

        let grown = peak.value - before
        // Process-wide: tests running in parallel add noise, so only a file-sized jump fails.
        #expect(grown < 256 * 1024 * 1024, "memory grew by \(grown / 1_048_576) MB while copying 512 MB")
    }

    static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
}

private final class PeakBox: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Int64 = 0
    var value: Int64 { lock.lock(); defer { lock.unlock() }; return peak }
    func update(_ bytes: Int64) { lock.lock(); peak = max(peak, bytes); lock.unlock() }
}
