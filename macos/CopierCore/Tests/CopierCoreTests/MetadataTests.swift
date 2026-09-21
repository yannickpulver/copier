import Foundation
import Testing
@testable import CopierCore

/// Builds synthetic ISOBMFF buffers for the atom-walker tests.
enum AtomBuilder {
    /// `[size][type][payload]`
    static func box(_ type: String, _ payload: Data) -> Data {
        var data = Data()
        let size = UInt32(8 + payload.count)
        data.append(contentsOf: [
            UInt8((size >> 24) & 0xFF), UInt8((size >> 16) & 0xFF),
            UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF),
        ])
        data.append(contentsOf: type.unicodeScalars.map { UInt8($0.value & 0xFF) })
        data.append(payload)
        return data
    }

    static func be32(_ value: Int) -> Data {
        let v = UInt32(value)
        return Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    static func be16(_ value: Int) -> Data {
        let v = UInt16(value)
        return Data([UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    /// Canon `modl`: [4-byte version/flags][2-byte language][text]
    static func canonModl(_ model: String) -> Data {
        var payload = Data([0, 0, 0, 0])
        payload.append(be16(0))
        payload.append(Data(model.utf8))
        payload.append(0)
        return box("modl", payload)
    }

    /// Classic `©xxx` atom: [2-byte text length][2-byte language][text]
    static func classicText(_ type: String, _ text: String) -> Data {
        let bytes = Data(text.utf8)
        var payload = be16(bytes.count)
        payload.append(be16(0))
        payload.append(bytes)
        return box(type, payload)
    }

    /// iTunes-style ilst entry: [size][key][data box].
    static func ilstEntry(key: String, value: String) -> Data {
        var dataBox = be32(16 + value.utf8.count)
        dataBox.append(Data("data".utf8))
        dataBox.append(be32(1))     // well-known type: UTF-8
        dataBox.append(be32(0))     // locale
        dataBox.append(Data(value.utf8))
        return box(key, dataBox)
    }

    /// `meta` is a full box: 4 bytes of version/flags before its children.
    static func meta(_ children: Data) -> Data {
        var payload = Data([0, 0, 0, 0])
        payload.append(children)
        return box("meta", payload)
    }
}

@Suite("ISOBMFF atom walker")
struct ISOBMFFParserTests {
    @Test("reads a Canon modl atom from moov/udta")
    func canonModl() {
        let udta = AtomBuilder.box("udta", AtomBuilder.canonModl("Canon EOS R5"))
        let moov = AtomBuilder.box("moov", udta)
        var file = AtomBuilder.box("ftyp", Data("qt  ".utf8))
        file.append(moov)

        let tags = ISOBMFFParser.parse(data: file)
        #expect(tags.model == "Canon EOS R5")
        #expect(MetadataExtractor.cleanCameraName(tags.model) == "Canon EOS R5")
    }

    @Test("reads ©mod and ©day from classic user data")
    func classicUdta() {
        var children = AtomBuilder.classicText("©mod", "HERO12 Black")
        children.append(AtomBuilder.classicText("©day", "2026-09-18T10:11:12+0000"))
        let moov = AtomBuilder.box("moov", AtomBuilder.box("udta", children))

        let tags = ISOBMFFParser.parse(data: moov)
        #expect(tags.model == "HERO12 Black")
        #expect(tags.dateString == "2026-09-18T10:11:12+0000")
        #expect(DateParsing.parseFlexible(tags.dateString!) == Date(timeIntervalSince1970: 1_789_726_272))
    }

    @Test("strips the Fujifilm prefix from ©inf")
    func fujiInf() {
        let moov = AtomBuilder.box("moov", AtomBuilder.box("udta", AtomBuilder.classicText("©inf", "FUJIFILM DIGITAL CAMERA X-T5")))
        #expect(ISOBMFFParser.parse(data: moov).model == "X-T5")

        let generic = AtomBuilder.box("moov", AtomBuilder.box("udta", AtomBuilder.classicText("©inf", "DIGITAL CAMERA")))
        #expect(ISOBMFFParser.parse(data: generic).model == nil)
    }

    @Test("reads the DJI ©too encoder tag from moov/udta/meta/ilst")
    func djiEncoder() {
        var ilstChildren = AtomBuilder.ilstEntry(key: "©too", value: "DJI Mavic3Pro")
        ilstChildren.append(AtomBuilder.ilstEntry(key: "©day", value: "2026-09-18T10:11:12Z"))
        let ilst = AtomBuilder.box("ilst", ilstChildren)
        let udta = AtomBuilder.box("udta", AtomBuilder.meta(ilst))
        let moov = AtomBuilder.box("moov", udta)

        let tags = ISOBMFFParser.parse(data: moov)
        #expect(tags.encoder == "DJI Mavic3Pro")
        #expect(tags.model == nil)
        #expect(tags.dateString == "2026-09-18T10:11:12Z")
        #expect(ISOBMFFParser.isDJIEncoder(tags.encoder!))
        #expect(MetadataExtractor.cleanCameraName(tags.encoder) == "DJI Mavic 3 Pro")
    }

    @Test("a file without moov yields nothing")
    func noMoov() {
        #expect(ISOBMFFParser.parse(data: AtomBuilder.box("ftyp", Data("isom".utf8))).isEmpty)
    }
}

@Suite("Camera names")
struct CameraNameTests {
    @Test("maps DJI model codes", arguments: [
        ("FC3582", "DJI Mini 3 Pro"),
        ("L2D-20c", "DJI Mavic 3"),
        ("OW001", "DJI Osmo Nano"),
        ("PP-101", "DJI Osmo Pocket 3"),
        ("RZ001", "Ryze Tello"),
    ])
    func modelCodes(code: String, expected: String) {
        #expect(MetadataExtractor.cleanCameraName(code) == expected)
    }

    @Test("normalizes compact DJI video names", arguments: [
        ("DJI Mavic3Pro", "DJI Mavic 3 Pro"),
        ("DJI Air3S", "DJI Air 3S"),
        ("DJI Mini4Pro", "DJI Mini 4 Pro"),
    ])
    func compactNames(raw: String, expected: String) {
        #expect(MetadataExtractor.cleanCameraName(raw) == expected)
    }

    @Test("keeps ordinary model names and takes the first comma component")
    func plainNames() {
        #expect(MetadataExtractor.cleanCameraName("Canon EOS R5") == "Canon EOS R5")
        #expect(MetadataExtractor.cleanCameraName("ILCE-7M4, something") == "ILCE-7M4")
        #expect(MetadataExtractor.cleanCameraName("  ") == nil)
        #expect(MetadataExtractor.cleanCameraName(nil) == nil)
    }

    @Test("ambiguous Mavic 3 files are upgraded when a Pro is in the batch")
    func ambiguityResolution() {
        func file(_ name: String, camera: String?) -> MediaFile {
            MediaFile(
                name: name,
                url: URL(fileURLWithPath: "/card/\(name)"),
                relativePath: name,
                size: 1,
                camera: camera,
                isMedia: true
            )
        }
        var files = [file("a.jpg", camera: "DJI Mavic 3"), file("b.mp4", camera: "DJI Mavic 3 Pro"), file("c.jpg", camera: "Canon EOS R5")]
        MetadataExtractor.resolveAmbiguousCameras(&files)
        #expect(files.map(\.camera) == ["DJI Mavic 3 Pro", "DJI Mavic 3 Pro", "Canon EOS R5"])

        var alone = [file("a.jpg", camera: "DJI Mavic 3")]
        MetadataExtractor.resolveAmbiguousCameras(&alone)
        #expect(alone[0].camera == "DJI Mavic 3")
    }
}

@Suite("Date parsing")
struct DateParsingTests {
    @Test("EXIF dates use colons and local time")
    func exif() throws {
        let date = try #require(DateParsing.parseExif("2026:09:18 14:03:11"))
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour], from: date)
        #expect(components.year == 2026)
        #expect(components.month == 9)
        #expect(components.day == 18)
        #expect(components.hour == 14)
    }

    @Test("ISO 8601 with zone")
    func iso() {
        #expect(DateParsing.parseFlexible("2026-09-18T10:11:12Z") == Date(timeIntervalSince1970: 1_789_726_272))
    }

    @Test("garbage yields nil")
    func garbage() {
        #expect(DateParsing.parseFlexible("not a date") == nil)
        #expect(DateParsing.parseFlexible("") == nil)
    }
}
