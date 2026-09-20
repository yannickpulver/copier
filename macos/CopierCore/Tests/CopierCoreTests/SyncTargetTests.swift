import Testing
@testable import CopierCore

/// Ported from `src/lib/syncTarget.test.ts`.
@Suite("SyncTarget.resolve")
struct SyncTargetTests {
    @Test("empty target stays empty")
    func emptyTarget() {
        #expect(SyncTarget.resolve(sourcePath: "/src/2024-trip", targetPath: "", appendSourceName: true) == "")
        #expect(SyncTarget.resolve(sourcePath: "/src/2024-trip", targetPath: "", appendSourceName: false) == "")
    }

    @Test("target as-is when append is off")
    func appendOff() {
        #expect(
            SyncTarget.resolve(sourcePath: "/src/2024-trip", targetPath: "/Volumes/NAS/Photos", appendSourceName: false)
                == "/Volumes/NAS/Photos"
        )
    }

    @Test("appends source basename when append is on")
    func appendOn() {
        #expect(
            SyncTarget.resolve(sourcePath: "/src/2024-trip", targetPath: "/Volumes/NAS/Photos", appendSourceName: true)
                == "/Volumes/NAS/Photos/2024-trip"
        )
    }

    @Test("appends even when target basename matches source basename")
    func appendsDuplicate() {
        #expect(
            SyncTarget.resolve(sourcePath: "/src/2024-trip", targetPath: "/Volumes/SSD/2024-trip", appendSourceName: true)
                == "/Volumes/SSD/2024-trip/2024-trip"
        )
    }

    @Test("strips trailing slashes before appending")
    func stripsSlashes() {
        #expect(
            SyncTarget.resolve(sourcePath: "/src/2024-trip/", targetPath: "/Volumes/NAS/Photos/", appendSourceName: true)
                == "/Volumes/NAS/Photos/2024-trip"
        )
    }

    @Test("target as-is when source is empty")
    func emptySource() {
        #expect(SyncTarget.resolve(sourcePath: "", targetPath: "/Volumes/NAS/Photos", appendSourceName: true) == "/Volumes/NAS/Photos")
    }
}
