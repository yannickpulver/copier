import Foundation

/// Random-access byte source for the ISOBMFF atom walker. Backed by a file on disk
/// in production and by an in-memory `Data` in tests.
protocol ByteReader {
    var length: Int64 { get }
    /// Read up to `count` bytes at `offset`. May return fewer bytes at end of file.
    func read(at offset: Int64, count: Int) -> Data
}

struct DataByteReader: ByteReader {
    let data: Data

    var length: Int64 { Int64(data.count) }

    func read(at offset: Int64, count: Int) -> Data {
        guard offset >= 0, offset < Int64(data.count), count > 0 else { return Data() }
        let start = Int(offset)
        let end = min(data.count, start + count)
        return data.subdata(in: start..<end)
    }
}

/// `FileHandle`-backed reader. Not `Sendable` — keep it inside one function and
/// never capture it across tasks.
final class FileByteReader: ByteReader {
    private let handle: FileHandle
    let length: Int64

    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.int64Value
        self.handle = handle
        self.length = size ?? 0
    }

    deinit { try? handle.close() }

    func read(at offset: Int64, count: Int) -> Data {
        guard offset >= 0, count > 0 else { return Data() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count) ?? Data()
        } catch {
            return Data()
        }
    }
}

extension Data {
    /// Big-endian `UInt32` at `offset`, or `nil` when out of range.
    func beUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let bytes = self[startIndex.advanced(by: offset)..<startIndex.advanced(by: offset + 4)]
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    /// Big-endian `UInt16` at `offset`, or `nil` when out of range.
    func beUInt16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        let bytes = self[startIndex.advanced(by: offset)..<startIndex.advanced(by: offset + 2)]
        return bytes.reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    /// Latin-1 string of `count` bytes at `offset` (used for four-character atom types).
    func latin1(at offset: Int, count: Int) -> String {
        guard offset >= 0, offset + count <= self.count, count > 0 else { return "" }
        let bytes = self[startIndex.advanced(by: offset)..<startIndex.advanced(by: offset + count)]
        return String(bytes.map { Character(UnicodeScalar($0)) })
    }

    /// UTF-8 string in `range`, trailing NULs stripped and whitespace trimmed.
    func utf8Text(from start: Int, to end: Int) -> String {
        guard start >= 0, end <= count, start < end else { return "" }
        let bytes = self[startIndex.advanced(by: start)..<startIndex.advanced(by: end)]
        var text = String(decoding: bytes, as: UTF8.self)
        while text.hasSuffix("\0") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
