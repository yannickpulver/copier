import Foundation

/// Raw tags read out of an ISOBMFF (`mp4`/`mov`/`m4v`/`crm`) container.
public struct VideoTags: Sendable, Hashable {
    /// Model name from an `ilst` `…model` / `©mod` key, a Canon `modl` atom or a Fuji `©inf`.
    public var model: String?
    /// iTunes-style encoder tag (`©too`) — DJI puts the drone name here.
    public var encoder: String?
    /// Creation date string (`creationdate`, `…date`, `©day`).
    public var dateString: String?

    public init(model: String? = nil, encoder: String? = nil, dateString: String? = nil) {
        self.model = model
        self.encoder = encoder
        self.dateString = dateString
    }

    public var isEmpty: Bool { model == nil && encoder == nil && dateString == nil }
}

/// Hand-written atom walker for ISOBMFF video, ported from `metadata.ts`.
/// ImageIO does not surface these tags, so the boxes are read directly.
public enum ISOBMFFParser {
    struct AtomLocation {
        var dataStart: Int64
        var dataEnd: Int64
    }

    /// Parse an in-memory container. Used by tests with synthetic buffers.
    public static func parse(data: Data) -> VideoTags {
        parse(reader: DataByteReader(data: data))
    }

    /// Parse a file on disk.
    public static func parse(url: URL) -> VideoTags {
        guard let reader = FileByteReader(url: url) else { return VideoTags() }
        return parse(reader: reader)
    }

    static func parse(reader: ByteReader) -> VideoTags {
        guard let moov = findAtom(reader, type: "moov", start: 0, end: reader.length) else {
            return VideoTags()
        }

        // A file may carry both an (often empty) moov/meta and a moov/udta/meta holding the
        // real tags — DJI videos do. Parse every meta and merge, first value wins.
        var metas: [AtomLocation] = []
        if let meta = findAtom(reader, type: "meta", start: moov.dataStart, end: moov.dataEnd) {
            metas.append(meta)
        }
        let udta = findAtom(reader, type: "udta", start: moov.dataStart, end: moov.dataEnd)
        if let udta, let meta = findAtom(reader, type: "meta", start: udta.dataStart, end: udta.dataEnd) {
            metas.append(meta)
        }

        var tags = VideoTags()
        for meta in metas {
            // `meta` is a full box: skip the 4-byte version/flags before its children.
            let parsed = parseIlst(reader, metaStart: meta.dataStart + 4, metaEnd: meta.dataEnd)
            tags.model = tags.model ?? parsed.model
            tags.encoder = tags.encoder ?? parsed.encoder
            tags.dateString = tags.dateString ?? parsed.dateString
        }

        // Only fall back to the classic user-data atoms when the modern tags gave
        // neither a usable model (a DJI `©too` counts) nor a date.
        let hasUsableModel = tags.model != nil || (tags.encoder.map(isDJIEncoder) ?? false)
        if !hasUsableModel, tags.dateString == nil, let udta {
            tags = parseClassicUdta(reader, udta: udta)
        }
        return tags
    }

    /// DJI stores the drone model in the iTunes-style `©too` (encoder) tag, e.g. "DJI Mavic3Pro".
    public static func isDJIEncoder(_ value: String) -> Bool {
        value.range(of: "^DJI\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Boxes

    static func findAtom(_ reader: ByteReader, type: String, start: Int64, end: Int64) -> AtomLocation? {
        var pos = start
        while pos + 8 <= end {
            let header = reader.read(at: pos, count: 16)
            guard header.count >= 8, var size = header.beUInt32(at: 0).map(Int64.init) else { return nil }
            let atomType = header.latin1(at: 4, count: 4)
            var headerSize: Int64 = 8
            if size == 1 {
                guard header.count >= 16,
                      let high = header.beUInt32(at: 8),
                      let low = header.beUInt32(at: 12)
                else { return nil }
                size = Int64(high) * 0x1_0000_0000 + Int64(low)
                headerSize = 16
            } else if size == 0 {
                size = end - pos
            }
            if size < headerSize { return nil }
            if atomType == type { return AtomLocation(dataStart: pos + headerSize, dataEnd: pos + size) }
            pos += size
        }
        return nil
    }

    private static let readCap = 4 * 1024 * 1024

    private static func readRange(_ reader: ByteReader, _ start: Int64, _ end: Int64) -> Data {
        let length = Int(min(end - start, Int64(readCap)))
        guard length > 0 else { return Data() }
        return reader.read(at: start, count: length)
    }

    /// Parse the `ilst` inside a `meta` box. `metaStart`/`metaEnd` span its children.
    static func parseIlst(_ reader: ByteReader, metaStart: Int64, metaEnd: Int64) -> VideoTags {
        let keys = findAtom(reader, type: "keys", start: metaStart, end: metaEnd)
        guard let ilst = findAtom(reader, type: "ilst", start: metaStart, end: metaEnd) else {
            return VideoTags()
        }

        var keyList: [String] = []
        if let keys {
            let buffer = readRange(reader, keys.dataStart + 4, keys.dataEnd)
            if let count = buffer.beUInt32(at: 0) {
                var offset = 4
                for _ in 0..<Int(count) {
                    guard offset + 8 <= buffer.count, let size = buffer.beUInt32(at: offset).map(Int.init) else { break }
                    if size < 8 || offset + size > buffer.count { break }
                    keyList.append(String(decoding: buffer[buffer.startIndex.advanced(by: offset + 8)..<buffer.startIndex.advanced(by: offset + size)], as: UTF8.self))
                    offset += size
                }
            }
        }

        let buffer = readRange(reader, ilst.dataStart, ilst.dataEnd)
        var tags = VideoTags()
        var offset = 0
        while offset + 8 <= buffer.count {
            guard let size = buffer.beUInt32(at: offset).map(Int.init), size >= 8, offset + size <= buffer.count else { break }
            let index = buffer.beUInt32(at: offset + 4).map(Int.init) ?? 0
            let typeAscii = buffer.latin1(at: offset + 4, count: 4)
            let key = (index >= 1 && index <= keyList.count) ? keyList[index - 1] : typeAscii

            if offset + 16 <= offset + size,
               let dataSize = buffer.beUInt32(at: offset + 8).map(Int.init) {
                let dataType = buffer.latin1(at: offset + 12, count: 4)
                if dataType == "data", dataSize >= 16, offset + 8 + dataSize <= offset + size {
                    let payload = buffer.utf8Text(from: offset + 24, to: offset + 8 + dataSize)
                    if isModelKey(key) {
                        if tags.model == nil { tags.model = payload }
                    } else if key == "©too" {
                        if tags.encoder == nil { tags.encoder = payload }
                    } else if isDateKey(key) {
                        if tags.dateString == nil { tags.dateString = payload }
                    }
                }
            }
            offset += size
        }
        return tags
    }

    /// Matches `/(^|\.)model$/i` and the classic `©mod`.
    private static func isModelKey(_ key: String) -> Bool {
        if key == "©mod" { return true }
        let lower = key.lowercased()
        return lower == "model" || lower.hasSuffix(".model")
    }

    /// Matches `/(creationdate|date$)/i` and the classic `©day`.
    private static func isDateKey(_ key: String) -> Bool {
        if key == "©day" { return true }
        let lower = key.lowercased()
        return lower.contains("creationdate") || lower.hasSuffix("date")
    }

    /// Classic QuickTime user-data atoms: `©mod`, `©day`, `©inf`, and Canon's `modl`.
    static func parseClassicUdta(_ reader: ByteReader, udta: AtomLocation) -> VideoTags {
        let buffer = readRange(reader, udta.dataStart, udta.dataEnd)
        var tags = VideoTags()
        var offset = 0
        while offset + 8 <= buffer.count {
            guard let size = buffer.beUInt32(at: offset).map(Int.init), size >= 8, offset + size <= buffer.count else { break }
            let type = buffer.latin1(at: offset + 4, count: 4)
            let firstByte = buffer[buffer.startIndex.advanced(by: offset + 4)]

            if firstByte == 0xA9, offset + 12 <= offset + size {
                // Payload: [2-byte text length][2-byte language][text]
                let textLength = Int(buffer.beUInt16(at: offset + 8) ?? 0)
                let start = offset + 12
                if textLength > 0, start + textLength <= offset + size {
                    let payload = buffer.utf8Text(from: start, to: start + textLength)
                    switch type {
                    case "©mod", "©make":
                        if tags.model == nil { tags.model = payload }
                    case "©inf":
                        let cleaned = stripFujiPrefix(payload)
                        if !cleaned.isEmpty, cleaned.lowercased() != "digital camera", tags.model == nil {
                            tags.model = cleaned
                        }
                    case "©day":
                        if tags.dateString == nil { tags.dateString = payload }
                    default:
                        break
                    }
                }
            } else if type == "modl", offset + 14 <= offset + size {
                // Canon MP4/MOV: [4-byte version/flags][2-byte language][NUL-terminated text]
                let payload = buffer.utf8Text(from: offset + 14, to: offset + size)
                if !payload.isEmpty, tags.model == nil { tags.model = payload }
            }
            offset += size
        }
        return tags
    }

    /// Fuji writes `©inf` as "FUJIFILM DIGITAL CAMERA X-T5".
    static func stripFujiPrefix(_ value: String) -> String {
        let pattern = "^FUJIFILM\\s+DIGITAL\\s+CAMERA\\s+"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        let stripped = regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
