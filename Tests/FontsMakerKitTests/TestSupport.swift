import Foundation
import Testing

@testable import FontsMakerKit

/// Committed synthetic fonts produced by scripts/make-test-fonts.py.
enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    static func bytes(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: directory.appendingPathComponent(name)))
    }

    static func font(_ name: String) throws -> Font {
        try Font(bytes: try bytes(name))
    }

    /// Facts about synthetic.ttf as computed by fontTools when the fixture was generated.
    static func expectation() throws -> SyntheticExpectation {
        let data = try Data(contentsOf: directory.appendingPathComponent("synthetic-expected.json"))
        return try JSONDecoder().decode(SyntheticExpectation.self, from: data)
    }
}

struct SyntheticExpectation: Decodable {
    struct Outline: Decodable {
        let endPoints: [Int]
        let x: [Int32]
        let y: [Int32]
        let onCurve: [Bool]

        var simpleOutline: SimpleOutline {
            SimpleOutline(
                endPoints: endPoints,
                points: x.indices.map { GlyphPoint(x: x[$0], y: y[$0], onCurve: onCurve[$0]) })
        }
    }

    struct Name: Decodable {
        let platformID: UInt16
        let encodingID: UInt16
        let languageID: UInt16
        let nameID: UInt16
        let hex: String

        var record: NameRecord {
            var bytes: [UInt8] = []
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                bytes.append(UInt8(hex[index..<next], radix: 16)!)
                index = next
            }
            return NameRecord(
                platformID: platformID, encodingID: encodingID, languageID: languageID, nameID: nameID, bytes: bytes)
        }
    }

    let numGlyphs: Int
    let glyphOrder: [String]
    let cmap: [String: UInt16]
    let composites: [Int]
    let decomposed: [String: Outline]
    let vert: [String: UInt16]
    let names: [Name]
    let instructions: [String: String]
    let advances: [UInt16]
    let leftSideBearings: [Int16]
    let tables: [String]
    let maxp: [String: Int]

    func glyphID(_ name: String) -> Int { glyphOrder.firstIndex(of: name)! }
}

/// Real reference fonts in the shared download cache (technical design D7).
enum ReferenceFonts {
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["FONTSMAKER_FIXTURES"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/FontsMaker/fixtures")
    }

    /// A missing cache fails the test instead of skipping it: a silently
    /// skipped integration test would make the suite look greener than it is.
    static func bytes(_ name: String) throws -> [UInt8] {
        let url = directory.appendingPathComponent(name)
        try #require(
            FileManager.default.fileExists(atPath: url.path),
            "Reference font \(name) is missing from \(directory.path). Run `bash scripts/fetch-fixtures.sh` first.")
        return [UInt8](try Data(contentsOf: url))
    }
}

/// Index of the first differing element; keeps failure output readable when
/// comparing tens of thousands of glyphs.
func firstDifference<T: Equatable>(_ lhs: [T], _ rhs: [T]) -> Int? {
    if lhs.count != rhs.count { return min(lhs.count, rhs.count) }
    return lhs.indices.first { lhs[$0] != rhs[$0] }
}

/// Table records of a serialized font, for checking the container itself.
struct TableRecord {
    let tag: String
    let checksum: UInt32
    let offset: Int
    let length: Int
}

func tableRecords(_ font: [UInt8]) -> [TableRecord] {
    let count = Int(font.readU16(at: 4))
    return (0..<count).map { index in
        let base = 12 + 16 * index
        func u32(_ at: Int) -> UInt32 {
            UInt32(font[at]) << 24 | UInt32(font[at + 1]) << 16 | UInt32(font[at + 2]) << 8 | UInt32(font[at + 3])
        }
        return TableRecord(
            tag: String(decoding: font[base..<base + 4], as: UTF8.self),
            checksum: u32(base + 4), offset: Int(u32(base + 8)), length: Int(u32(base + 12)))
    }
}

func table(_ tag: String, in font: [UInt8]) -> [UInt8]? {
    tableRecords(font).first { $0.tag == tag }.map { Array(font[$0.offset..<$0.offset + $0.length]) }
}

/// Passthrough tables must come out byte for byte; these are the ones the writer may change.
let regeneratedTables: Set<String> = ["head", "hhea", "maxp", "OS/2", "hmtx", "loca", "glyf", "cmap", "name"]
