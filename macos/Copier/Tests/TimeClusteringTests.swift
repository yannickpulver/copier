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

    @Test("a folder inside a camera folder is the card folder title")
    func cardFolderTitle() {
        func title(_ path: String) -> String? {
            MediaFile(name: "x", url: URL(fileURLWithPath: "/card/\(path)"), relativePath: path, size: 1, isMedia: true)
                .cardFolderTitle
        }
        #expect(title("DCIM/100CANON/Isa & Spencer/IMG_0001.CR3") == "Isa & Spencer")
        #expect(title("DCIM/100_FUJI/Day 2/Detail/DSCF0001.RAF") == "Day 2")
        #expect(title("DCIM/100CANON/IMG_0001.CR3") == nil)
        #expect(title("DCIM/PANORAMA/100_0001/DJI_0001.JPG") == nil)
        #expect(title("PRIVATE/M4ROOT/CLIP/C0001.MP4") == nil)
    }

    @Test("files from a card folder form one cluster, whatever the gaps")
    func cardFolderCluster() {
        func sorted(_ name: String, minutes: Int) -> ReviewFile {
            var review = file(name, minutes: minutes)
            review.file.relativePath = "DCIM/100CANON/Isa & Spencer/\(name)"
            return review
        }
        let clusters = TimeClustering.cluster([
            file("a.jpg", minutes: 0),
            sorted("b.jpg", minutes: 5),
            file("c.jpg", minutes: 10),
            sorted("d.jpg", minutes: 120),
        ])
        #expect(clusters.map(\.title) == [nil, "Isa & Spencer"])
        #expect(clusters.map { $0.files.map(\.file.name) } == [["a.jpg", "c.jpg"], ["b.jpg", "d.jpg"]])
    }

    @Test("the preview is the middle photo, or the middle video without photos")
    func previewFile() {
        let mixed = TimeClustering.cluster([
            file("a.MP4", minutes: 0),
            file("b.ARW", minutes: 1),
            file("c.XML", minutes: 2),
            file("d.JPG", minutes: 3),
            file("e.ARW", minutes: 4),
        ])
        #expect(mixed[0].previewFile?.name == "d.JPG")

        let videos = TimeClustering.cluster([file("a.MP4", minutes: 0), file("b.MP4", minutes: 1)])
        #expect(videos[0].previewFile?.name == "b.MP4")

        let sidecars = TimeClustering.cluster([file("a.XML", minutes: 0)])
        #expect(sidecars[0].previewFile == nil)
    }
}
