import Foundation
import Testing

@testable import FontsMakerKit

/// Reader and writer against synthetic.ttf, with fontTools' view of the same
/// file (synthetic-expected.json) as the oracle.
struct SyntheticFontTests {
    @Test func readsWhatFontToolsReads() throws {
        let font = try Fixtures.font("synthetic.ttf")
        let expected = try Fixtures.expectation()

        #expect(font.glyphs.count == expected.numGlyphs)
        #expect(font.unitsPerEm == 1000)
        let expectedCmap = Dictionary(uniqueKeysWithValues: expected.cmap.map { (UInt32($0.key)!, $0.value) })
        #expect(font.characterMap.mappings == expectedCmap)
        #expect(font.glyphs.indices.filter { font.glyphs[$0].isComposite } == expected.composites)
        let expectedVert = Dictionary(uniqueKeysWithValues: expected.vert.map { (UInt16($0.key)!, $0.value) })
        #expect(font.verticalSubstitutions == expectedVert)
        #expect(Set(font.names) == Set(expected.names.map(\.record)))
        #expect(font.names.count == expected.names.count)
        #expect(font.horizontalMetrics.map(\.advanceWidth) == expected.advances)
        #expect(font.horizontalMetrics.map(\.leftSideBearing) == expected.leftSideBearings)
        for (glyphID, glyph) in font.glyphs.enumerated() {
            let hex = glyph.instructions.map { String(format: "%02x", $0) }.joined()
            #expect(hex == (expected.instructions[String(glyphID)] ?? ""), "instructions of glyph \(glyphID)")
        }
        #expect(font.os2?.typoAscender == 880)
        #expect(font.os2?.typoDescender == -120)
    }

    /// One glyph mapped from several code points must stay one glyph (design §4.2).
    @Test func sharedGlyphIsOneGlyph() throws {
        let font = try Fixtures.font("synthetic.ttf")
        let shared = [0x4E00, 0x2F00, 0x31D0].map { font.characterMap.mappings[UInt32($0)] }
        #expect(Set(shared).count == 1)
        #expect(shared[0] != nil)
        #expect(font.characterMap.mappings[0x20000] != nil, "non-BMP code point read from format 12")
        #expect(font.characterMap.variationSequences != nil)
    }

    @Test func roundTripKeepsModelAndPassthroughTables() throws {
        let sourceBytes = try Fixtures.bytes("synthetic.ttf")
        let source = try Font(bytes: sourceBytes)
        let output = try source.serialize(options: WriteOptions())
        let reread = try Font(bytes: output)

        #expect(firstDifference(reread.glyphs, source.glyphs) == nil)
        #expect(reread.horizontalMetrics == source.horizontalMetrics)
        #expect(reread.characterMap == source.characterMap)
        #expect(
            reread.names
                == source.names.sorted {
                    ($0.platformID, $0.encodingID, $0.languageID, $0.nameID) < (
                        $1.platformID, $1.encodingID, $1.languageID, $1.nameID
                    )
                })
        #expect(reread.verticalSubstitutions == source.verticalSubstitutions)

        // Everything not regenerated is copied verbatim, hinting included.
        // DSIG is the exception: it signs the source bytes, which no longer exist.
        for (tag, data) in source.tables where !regeneratedTables.contains(tag) && tag != "DSIG" {
            #expect(reread.tables[tag] == data, "table \(tag)")
        }
        #expect(reread.tables["DSIG"] == nil)

        // Derived tables recomputed from the glyphs must agree with fontTools' values.
        #expect(reread.tables["maxp"] == source.tables["maxp"])
        #expect(reread.tables["hhea"] == source.tables["hhea"])
        #expect(reread.tables["OS/2"] == source.tables["OS/2"])
        var sourceHead = source.tables["head"]!
        var outputHead = reread.tables["head"]!
        sourceHead.writeU32(0, at: 8)
        outputHead.writeU32(0, at: 8)
        #expect(outputHead == sourceHead, "head may differ only in checkSumAdjustment")
    }

    @Test func writingIsDeterministicAndIdempotent() throws {
        let font = try Fixtures.font("synthetic.ttf")
        let first = try font.serialize(options: WriteOptions())
        let second = try font.serialize(options: WriteOptions())
        #expect(first == second)
        let regenerated = try Font(bytes: first).serialize(options: WriteOptions())
        #expect(regenerated == first, "reading our own output and writing it again changes nothing")
    }

    @Test func containerIsWellFormed() throws {
        let output = try Fixtures.font("synthetic.ttf").serialize(options: WriteOptions())
        let records = tableRecords(output)
        #expect(records.map(\.tag) == records.map(\.tag).sorted(by: tagPrecedes))
        for record in records {
            #expect(record.offset % 4 == 0, "\(record.tag) is 4-byte aligned")
            var data = Array(output[record.offset..<record.offset + record.length])
            if record.tag == "head" { data.writeU32(0, at: 8) }
            #expect(tableChecksum(data) == record.checksum, "\(record.tag) checksum")
        }
        #expect(tableChecksum(output) == 0xB1B0_AFBA, "checkSumAdjustment balances the file")
        let head = try #require(table("head", in: output))
        #expect(head.readI16(at: 50) == 0, "small glyf uses short loca")
        let source = try Fixtures.bytes("synthetic.ttf")
        let sourceHead = try #require(table("head", in: source))
        #expect(head[20..<36] == sourceHead[20..<36], "created/modified come from the source, not the clock")
    }

    @Test func cmapSubtablesAreSharedAndFormat14Preserved() throws {
        let output = try Fixtures.font("synthetic.ttf").serialize(options: WriteOptions())
        let cmap = try #require(table("cmap", in: output))
        let count = Int(cmap.readU16(at: 2))
        var records: [String: Int] = [:]
        var formats: [String: UInt16] = [:]
        for index in 0..<count {
            let base = 4 + 8 * index
            let key = "\(cmap.readU16(at: base)),\(cmap.readU16(at: base + 2))"
            let offset = Int(cmap.readU16(at: base + 4)) << 16 | Int(cmap.readU16(at: base + 6))
            records[key] = offset
            formats[key] = cmap.readU16(at: offset)
        }
        #expect(formats == ["0,3": 4, "0,4": 12, "0,5": 14, "3,1": 4, "3,10": 12])
        #expect(records["0,3"] == records["3,1"])
        #expect(records["0,4"] == records["3,10"])
        let source = try Fixtures.font("synthetic.ttf")
        let start = try #require(records["0,5"])
        #expect(
            Array(cmap[start..<start + source.characterMap.variationSequences!.count])
                == source.characterMap.variationSequences!)
    }

    @Test func bmpOnlyFontGetsOnlyFormat4() throws {
        let output = try Fixtures.font("minimal.ttf").serialize(options: WriteOptions())
        let cmap = try #require(table("cmap", in: output))
        #expect(cmap.readU16(at: 2) == 2)
        #expect(try Font(bytes: output).characterMap.mappings == [0x41: 1])
    }

    @Test func stripHintingRemovesEveryHintingArtifact() throws {
        let source = try Fixtures.font("synthetic.ttf")
        #expect(source.glyphs.contains { !$0.instructions.isEmpty }, "fixture must carry instructions")
        let output = try Font(bytes: try source.serialize(options: WriteOptions(stripHinting: true)))

        for tag in ["fpgm", "prep", "cvt ", "hdmx", "LTSH", "VDMX", "DSIG"] {
            #expect(output.tables[tag] == nil, "\(tag) dropped")
        }
        #expect(output.glyphs.allSatisfy { $0.instructions.isEmpty })
        #expect(output.glyphs.map(\.outline) == source.glyphs.map(\.outline), "outlines untouched")
        let maxp = try #require(output.tables["maxp"])
        #expect((14...26).filter { $0 % 2 == 0 }.map { maxp.readU16(at: $0) } == [1, 0, 0, 0, 0, 0, 0])
        #expect(output.tables["gasp"] == source.tables["gasp"])
    }

    @Test func decomposeMatchesFontToolsFlattening() throws {
        var font = try Fixtures.font("synthetic.ttf")
        let expected = try Fixtures.expectation()
        let before = font.glyphs
        try font.decomposeComposites()

        #expect(!font.glyphs.contains { $0.isComposite })
        for (key, outline) in expected.decomposed {
            let glyphID = Int(key)!
            #expect(font.glyphs[glyphID].outline == .simple(outline.simpleOutline), "glyph \(glyphID)")
        }
        for glyphID in font.glyphs.indices where !before[glyphID].isComposite {
            #expect(font.glyphs[glyphID] == before[glyphID], "simple glyph \(glyphID) unchanged")
        }

        let reread = try Font(bytes: try font.serialize(options: WriteOptions()))
        #expect(reread.glyphs == font.glyphs)
        let maxp = try #require(reread.tables["maxp"])
        #expect(maxp.readU16(at: 10) == 0, "maxCompositePoints")
        #expect(maxp.readU16(at: 28) == 0, "maxComponentElements")
        #expect(maxp.readU16(at: 30) == 0, "maxComponentDepth")
        #expect(Int(maxp.readU16(at: 6)) == expected.maxp["maxCompositePoints"], "largest glyph is now simple")
    }
}
