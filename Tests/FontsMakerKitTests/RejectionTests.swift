import Testing

@testable import FontsMakerKit

/// Product spec §4.1: unsupported formats are refused with a reason the user can act on.
struct RejectionTests {
    /// CFF, variable fonts and collections are read since Phase 4a
    /// (NormalizeTests); web fonts still are not.
    @Test(arguments: [
        ("reject-woff.woff", FontLoadError.woff, "WOFF web fonts"),
        ("reject-woff2.woff2", FontLoadError.woff2, "WOFF2"),
    ])
    func rejectsUnsupportedFormat(file: String, expected: FontLoadError, mentions: String) throws {
        let bytes = try Fixtures.bytes(file)
        let error = #expect(throws: FontLoadError.self) { try Font(bytes: bytes) }
        #expect(error == expected)
        #expect(error?.description.contains(mentions) == true, "message names the format")
        #expect(error?.description.contains("not supported") == true, "message says it is a format limit, not damage")
    }

    @Test func rejectsNonFontData() {
        let text = Array("This is a text file, not a font.".utf8)
        #expect(throws: FontLoadError.notAFont) { try Font(bytes: text) }
    }

    @Test func rejectsTruncatedFont() throws {
        let bytes = try Fixtures.bytes("synthetic.ttf")
        #expect(throws: FontLoadError.self) { try Font(bytes: Array(bytes.prefix(200))) }
    }

    /// A TrueType-flavored file whose outlines are not in glyf (e.g. bitmap-only).
    @Test func rejectsFontWithoutGlyf() throws {
        let source = try Fixtures.bytes("minimal.ttf")
        var tables: [String: [UInt8]] = [:]
        for record in tableRecords(source) where record.tag != "glyf" && record.tag != "loca" {
            tables[record.tag] = Array(source[record.offset..<record.offset + record.length])
        }
        let stripped = Font.assemble(tables, sfntVersion: 0x0001_0000)
        #expect(throws: FontLoadError.missingTable("glyf")) { try Font(bytes: stripped) }
    }
}
