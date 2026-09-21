import CopierCore
import Foundation
import Testing

@Suite("TimeClustering")
struct TimeClusteringTests {
    private func file(_ name: String, minutes: Int?, size: Int64 = 10) -> ReviewFile {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        return ReviewFile(
            file: MediaFile(
                name: name,
                url: URL(fileURLWithPath: "/card/\(name)"),
                relativePath: name,
                size: size,
                captureDate: minutes.map { base.addingTimeInterval(TimeInterval($0 * 60)) },
                isMedia: true
            ),
            reason: .new
        )
    }

    @Test("a gap of 30 minutes or more starts a new cluster")
    func splitsOnGap() {
        let files = [
            file("a.jpg", minutes: 0),
            file("b.jpg", minutes: 12),
            file("c.jpg", minutes: 42), // 30 minutes after b — new cluster
            file("d.jpg", minutes: 50),
        ]
        let clusters = TimeClustering.cluster(files)
        #expect(clusters.count == 2)
        #expect(clusters[0].files.map(\.file.name) == ["a.jpg", "b.jpg"])
        #expect(clusters[1].files.map(\.file.name) == ["c.jpg", "d.jpg"])
        #expect(clusters[0].start == files[0].file.captureDate)
        #expect(clusters[0].end == files[1].file.captureDate)
    }

    @Test("a tight burst stays one cluster")
    func keepsBurstTogether() {
        let files = (0..<20).map { file("f\($0).jpg", minutes: $0) }
        #expect(TimeClustering.cluster(files).count == 1)
    }

    @Test("undated files land in one trailing cluster")
    func undatedGoLast() {
        let files = [file("a.jpg", minutes: 0), file("x.xml", minutes: nil)]
        let clusters = TimeClustering.cluster(files)
        #expect(clusters.count == 2)
        #expect(clusters.last?.start == nil)
        #expect(clusters.last?.files.map(\.file.name) == ["x.xml"])
    }

    @Test("no files, no clusters")
    func empty() {
        #expect(TimeClustering.cluster([]).isEmpty)
    }

    @Test("kind counts are colour-coded groups in a stable order")
    func kindCounts() {
        let files = [
            file("a.ARW", minutes: 0),
            file("b.JPG", minutes: 1),
            file("c.MP4", minutes: 2),
            file("d.XML", minutes: 3),
            file("e.JPG", minutes: 4),
        ]
        let counts = TimeClustering.kindCounts(files)
        #expect(counts.map(\.kind) == [.photo, .raw, .video, .other])
        #expect(counts.map(\.count) == [2, 1, 1, 1])
    }
}
