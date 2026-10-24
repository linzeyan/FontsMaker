import CoreText
import Foundation
import Testing

@testable import FontsMakerKit

/// Measured facts about the reference fonts (technical design §2).
struct ReferenceFact: Sendable, CustomTestStringConvertible {
    let file: String
    let glyphs: Int
    let characters: Int
    let composites: Int
    let sharedGlyphs: Int
    let hasHintingPrep: Bool

    var testDescription: String { file }

    static let all = [
        ReferenceFact(
            file: "GuanKiapTsingKhai.ttf", glyphs: 25098, characters: 22551, composites: 133, sharedGlyphs: 275,
            hasHintingPrep: false),
        ReferenceFact(
            file: "LXGWWenKaiTC-Regular.ttf", glyphs: 25764, characters: 25598, composites: 292, sharedGlyphs: 248,
            hasHintingPrep: true),
    ]
}

/// Integration tests on the real fonts. They fail (not skip) when the
/// download cache is missing; see ReferenceFonts.bytes.
struct ReferenceFontTests {
    @Test(arguments: ReferenceFact.all)
    func readsMeasuredFacts(fact: ReferenceFact) throws {
        let font = try Font(bytes: try ReferenceFonts.bytes(fact.file))
        #expect(font.glyphs.count == fact.glyphs)
        #expect(font.characterMap.mappings.count == fact.characters)
        #expect(font.glyphs.filter(\.isComposite).count == fact.composites)
        var uses: [UInt16: Int] = [:]
        for glyph in font.characterMap.mappings.values { uses[glyph, default: 0] += 1 }
        #expect(uses.values.filter { $0 > 1 }.count == fact.sharedGlyphs)
        #expect(!font.verticalSubstitutions.isEmpty, "vert forms present")
        #expect(font.os2?.typoAscender == 880)
        #expect(font.os2?.typoDescender == -120)
        #expect(font.licenseStatus == .openFontLicense)
        #expect(font.reservedFontNames.isEmpty, "§2: no RFN declared inside the file")
        #expect((font.tables["prep"] != nil) == fact.hasHintingPrep)
    }

    @Test(arguments: ReferenceFact.all)
    func roundTripPreservesFontAndIsDeterministic(fact: ReferenceFact) throws {
        let source = try Font(bytes: try ReferenceFonts.bytes(fact.file))
        let output = try source.serialize(options: WriteOptions())
        #expect(try source.serialize(options: WriteOptions()) == output, "same input, same bytes")

        let reread = try Font(bytes: output)
        #expect(firstDifference(reread.glyphs, source.glyphs) == nil, "first differing glyph")
        #expect(reread.horizontalMetrics == source.horizontalMetrics)
        #expect(reread.characterMap == source.characterMap)
        #expect(Set(reread.names) == Set(source.names))
        #expect(reread.names.count == source.names.count)
        #expect(reread.verticalSubstitutions == source.verticalSubstitutions)
        for (tag, data) in source.tables where !regeneratedTables.contains(tag) && tag != "DSIG" {
            #expect(reread.tables[tag] == data, "table \(tag) copied verbatim")
        }
        #expect(reread.tables["maxp"] == source.tables["maxp"], "recomputed maxp matches the source")
        #expect(reread.tables["hhea"] == source.tables["hhea"], "recomputed hhea matches the source")
        #expect(reread.tables["OS/2"] == source.tables["OS/2"])
    }

    @Test(arguments: ReferenceFact.all)
    func coreTextLoadsOutputWithSameGlyphMapping(fact: ReferenceFact) throws {
        let sourceBytes = try ReferenceFonts.bytes(fact.file)
        let model = try Font(bytes: sourceBytes)
        let output = try model.serialize(options: WriteOptions())

        let sourceFont = try coreTextFont(sourceBytes)
        let outputFont = try coreTextFont(output)
        // Prove CoreText is rendering our bytes and not a same-named installed font.
        let head = try #require(CTFontCopyTable(outputFont, CTFontTableTag(kCTFontTableHead), []) as Data?)
        #expect([UInt8](head) == table("head", in: output))
        #expect(CTFontGetGlyphCount(outputFont) == model.glyphs.count)

        var mismatches: [String] = []
        for (codePoint, glyph) in model.characterMap.mappings.sorted(by: { $0.key < $1.key }) {
            let fromSource = coreTextGlyph(sourceFont, codePoint)
            let fromOutput = coreTextGlyph(outputFont, codePoint)
            if fromOutput != fromSource || fromOutput != glyph {
                mismatches.append("U+\(hex(codePoint)): model \(glyph) source \(fromSource) output \(fromOutput)")
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) code points differ, e.g. \(mismatches.prefix(5))")
    }

    @Test(arguments: ReferenceFact.all)
    func decomposedOutputHasNoCompositesAndSameOutlines(fact: ReferenceFact) throws {
        let source = try Font(bytes: try ReferenceFonts.bytes(fact.file))
        var decomposed = source
        try decomposed.decomposeComposites()
        let reread = try Font(bytes: try decomposed.serialize(options: WriteOptions(stripHinting: true)))
        #expect(reread.glyphs.allSatisfy { !$0.isComposite })
        for glyphID in source.glyphs.indices where source.glyphs[glyphID].isComposite {
            let expected = try source.flattenedOutline(of: glyphID).rounded()
            #expect(reread.glyphs[glyphID].outline == .simple(expected), "glyph \(glyphID)")
        }
        #expect(reread.tables["prep"] == nil)
        #expect(reread.characterMap == source.characterMap)
    }

    private func coreTextFont(_ bytes: [UInt8]) throws -> CTFont {
        let descriptors = CTFontManagerCreateFontDescriptorsFromData(Data(bytes) as CFData) as? [CTFontDescriptor]
        let descriptor = try #require(descriptors?.first, "CoreText could not load the font data")
        return CTFontCreateWithFontDescriptor(descriptor, 1000, nil)
    }

    private func coreTextGlyph(_ font: CTFont, _ codePoint: UInt32) -> CGGlyph {
        guard let scalar = Unicode.Scalar(codePoint) else { return 0 }
        var units = Array(String(Character(scalar)).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
        return glyphs[0]
    }
}
