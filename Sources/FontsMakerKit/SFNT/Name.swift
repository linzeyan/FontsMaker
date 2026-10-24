import Foundation

public struct NameRecord: Equatable, Hashable, Sendable {
    public var platformID: UInt16
    public var encodingID: UInt16
    public var languageID: UInt16
    public var nameID: UInt16
    /// Encoded string exactly as stored in the font.
    public var bytes: [UInt8]

    public init(platformID: UInt16, encodingID: UInt16, languageID: UInt16, nameID: UInt16, bytes: [UInt8]) {
        self.platformID = platformID
        self.encodingID = encodingID
        self.languageID = languageID
        self.nameID = nameID
        self.bytes = bytes
    }

    /// Windows (3,1) UTF-16BE record, the form every modern renderer reads.
    public init(windowsLanguage languageID: UInt16, nameID: UInt16, string: String) {
        var bytes: [UInt8] = []
        for unit in string.utf16 {
            bytes.append(UInt8(unit >> 8))
            bytes.append(UInt8(unit & 0xFF))
        }
        self.init(platformID: 3, encodingID: 1, languageID: languageID, nameID: nameID, bytes: bytes)
    }

    /// Decoded text, or nil for encodings we do not interpret (legacy Mac
    /// script codes other than Roman, Windows legacy CJK code pages).
    public var string: String? {
        switch (platformID, encodingID) {
        case (0, _), (3, 0), (3, 1), (3, 10):
            guard bytes.count % 2 == 0 else { return nil }
            var units: [UInt16] = []
            units.reserveCapacity(bytes.count / 2)
            for index in stride(from: 0, to: bytes.count, by: 2) {
                units.append(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
            }
            return String(decoding: units, as: UTF16.self)
        case (1, 0):
            return String(bytes: bytes, encoding: .macOSRoman)
        default:
            return nil
        }
    }
}

/// The name table: all records of every platform and language, plus the
/// language-tag strings of format 1 tables.
struct NameTable {
    var records: [NameRecord]
    var languageTags: [[UInt8]]

    static func parse(_ table: [UInt8]) throws -> NameTable {
        var reader = ByteReader(table, context: "name")
        let format = try reader.u16()
        let count = Int(try reader.u16())
        let storage = Int(try reader.u16())
        var records: [NameRecord] = []
        records.reserveCapacity(count)
        var locations: [(Int, Int)] = []
        for _ in 0..<count {
            let platform = try reader.u16()
            let encoding = try reader.u16()
            let language = try reader.u16()
            let nameID = try reader.u16()
            let length = Int(try reader.u16())
            let offset = Int(try reader.u16())
            records.append(
                NameRecord(platformID: platform, encodingID: encoding, languageID: language, nameID: nameID, bytes: []))
            locations.append((offset, length))
        }
        var tagLocations: [(Int, Int)] = []
        if format == 1 {
            let tagCount = Int(try reader.u16())
            for _ in 0..<tagCount {
                let length = Int(try reader.u16())
                let offset = Int(try reader.u16())
                tagLocations.append((offset, length))
            }
        }
        func string(_ location: (Int, Int)) throws -> [UInt8] {
            var sub = ByteReader(table, from: storage + location.0, context: "name")
            return try sub.read(location.1)
        }
        for index in records.indices {
            records[index].bytes = try string(locations[index])
        }
        return NameTable(records: records, languageTags: try tagLocations.map(string))
    }

    /// Records are sorted as the spec requires; identical strings share storage.
    func encoded() throws -> [UInt8] {
        let sorted = records.sorted {
            ($0.platformID, $0.encodingID, $0.languageID, $0.nameID)
                < ($1.platformID, $1.encodingID, $1.languageID, $1.nameID)
        }
        var storage: [UInt8] = []
        var stored: [[UInt8]: Int] = [:]
        func place(_ bytes: [UInt8]) throws -> (UInt16, UInt16) {
            guard bytes.count <= Int(UInt16.max) else {
                throw FontWriteError.unencodable("name string longer than 65535 bytes")
            }
            if let offset = stored[bytes] { return (UInt16(bytes.count), UInt16(offset)) }
            let offset = storage.count
            guard offset <= Int(UInt16.max) else {
                throw FontWriteError.unencodable("name table storage exceeds 65535 bytes")
            }
            stored[bytes] = offset
            storage.append(contentsOf: bytes)
            return (UInt16(bytes.count), UInt16(offset))
        }

        let format: UInt16 = languageTags.isEmpty ? 0 : 1
        let headerSize = 6 + 12 * sorted.count + (format == 1 ? 2 + 4 * languageTags.count : 0)
        var writer = ByteWriter()
        writer.u16(format)
        writer.u16(UInt16(sorted.count))
        writer.u16(UInt16(headerSize))
        for record in sorted {
            let (length, offset) = try place(record.bytes)
            writer.u16(record.platformID)
            writer.u16(record.encodingID)
            writer.u16(record.languageID)
            writer.u16(record.nameID)
            writer.u16(length)
            writer.u16(offset)
        }
        if format == 1 {
            writer.u16(UInt16(languageTags.count))
            for tag in languageTags {
                let (length, offset) = try place(tag)
                writer.u16(length)
                writer.u16(offset)
            }
        }
        writer.append(storage)
        return writer.bytes
    }
}
