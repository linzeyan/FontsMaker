import Foundation
import Testing

@testable import FontsMakerKit

/// Character-level simplified → traditional (technical design §5.4) with the
/// bundled OpenCC tables, on ops.ttf's simplified/traditional pairs.
struct S2TTests {
    @Test func bundledOpenCCTablesLoad() throws {
        let tables = try OpenCCTables.bundled()
        // The pinned STCharacters.txt: 4012 entries, 276 with several candidates.
        #expect(tables.simplifiedToTraditional.count == 4012)
        #expect(tables.simplifiedToTraditional.values.filter { $0.count > 1 }.count == 276)
        #expect(tables.simplifiedToTraditional[0x53D1] == [0x767C, 0x9AEE], "发 → 發 髮, most common first")
        #expect(tables.taiwanVariants[0x7232] == [0x70BA], "爲 → 為")
        #expect(tables.taiwanVariants.count == 41)
    }

    private func converted(_ options: S2TOptions) throws -> (OpsFixture, Font, S2TReport) {
        let ops = try OpsFixture()
        var font = ops.font
        let report = try font.convertSimplifiedToTraditional(options)
        return (ops, font, report)
    }

    private func glyph(_ font: Font, _ character: Character) -> UInt16? {
        font.characterMap.mappings[character.unicodeScalars.first!.value]
    }

    @Test func singleTakesTheFirstCandidate() throws {
        let (ops, font, report) = try converted(S2TOptions(mode: .single))
        #expect(glyph(font, "汉") == ops.glyph("uni6F22"))
        #expect(glyph(font, "发") == ops.glyph("uni767C"), "one-to-many: 發, not 髮")
        #expect(glyph(font, "后") == ops.glyph("uni5F8C"))
        #expect(glyph(font, "为") == ops.glyph("uni7232"), "爲 without Taiwan variants")
        #expect(glyph(font, "里") == ops.glyph("uni88CF"))
        #expect(glyph(font, "们") == ops.glyph("uni4EEC"), "們 is missing: stays simplified")
        #expect(report.missingTraditional == [.init(simplified: 0x4EEC, traditional: 0x5011)])
        #expect(report.remapped == 5)
        #expect(report.fallbacks.isEmpty, "every first candidate the fixture names is present")

        // Traditional characters, outlines and everything but the cmap stay as they were.
        #expect(glyph(font, "髮") == ops.glyph("uni9AEE"))
        #expect(glyph(font, "爲") == ops.glyph("uni7232"))
        #expect(font.glyphs == ops.font.glyphs)
        #expect(font.horizontalMetrics == ops.font.horizontalMetrics)
        #expect(font.names == ops.font.names)
    }

    /// Design §5.4: when the font lacks OpenCC's first candidate, a later one
    /// it has still shows a traditional form; the fallback is reported apart
    /// from plain conversions so a reviewer can check it.
    @Test func singleFallsBackToTheNextCandidateTheFontHas() throws {
        let ops = try OpsFixture()
        var font = ops.font
        font.characterMap.mappings[0x767C] = nil  // the font loses 發 and keeps 髮
        let report = try font.convertSimplifiedToTraditional(S2TOptions(mode: .single))
        #expect(glyph(font, "发") == ops.glyph("uni9AEE"))
        #expect(report.fallbacks == [.init(simplified: 0x53D1, preferred: 0x767C, used: 0x9AEE)])
        #expect(
            report.missingTraditional == [.init(simplified: 0x4EEC, traditional: 0x5011)], "們 has no later candidate")
        #expect(report.remapped == 5)

        // skipAmbiguous never converts one-to-many characters, so it never falls back.
        var skipping = ops.font
        skipping.characterMap.mappings[0x767C] = nil
        let skipReport = try skipping.convertSimplifiedToTraditional(S2TOptions(mode: .skipAmbiguous))
        #expect(skipReport.fallbacks.isEmpty)
        #expect(glyph(skipping, "发") == ops.glyph("uni53D1"))
    }

    @Test func skipAmbiguousLeavesOneToManyAlone() throws {
        let (ops, font, report) = try converted(S2TOptions(mode: .skipAmbiguous))
        #expect(glyph(font, "汉") == ops.glyph("uni6F22"))
        #expect(glyph(font, "为") == ops.glyph("uni7232"))
        #expect(glyph(font, "发") == ops.glyph("uni53D1"))
        #expect(glyph(font, "后") == ops.glyph("uni540E"))
        #expect(glyph(font, "里") == ops.glyph("uni91CC"))
        // 发, 后, 里 and 回 (回 → 回 迴): ambiguous even though 回 is its own first candidate.
        #expect(report.skippedAmbiguous == 4)
        #expect(report.remapped == 2)
    }

    /// Like OpenCC s2tw: the Taiwan table applies after s2t and to text that
    /// was already traditional, and lookups never chain through the new cmap.
    @Test func taiwanVariantsFollowTheSimplifiedTable() throws {
        let (ops, font, report) = try converted(S2TOptions(mode: .single, taiwanVariants: true))
        #expect(glyph(font, "为") == ops.glyph("uni70BA"), "为 → 爲 → 為")
        #expect(glyph(font, "爲") == ops.glyph("uni70BA"), "traditional input gets the Taiwan form too")
        #expect(glyph(font, "里") == ops.glyph("uni88E1"), "里 → 裏 → 裡")
        #expect(glyph(font, "裏") == ops.glyph("uni88E1"))
        #expect(glyph(font, "后") == ops.glyph("uni5F8C"))
        #expect(report.remapped == 7)
    }

    /// A traditional-only font has 漢 but not 汉: without the added code point,
    /// simplified text shows a missing glyph however the cmap is converted.
    @Test func addsSimplifiedCodePointsTheFontLacks() throws {
        let ops = try OpsFixture()
        var font = ops.font
        for removed: UInt32 in [0x6C49, 0x53D1, 0x4EEC] { font.characterMap.mappings[removed] = nil }  // 汉 发 们
        let stripped = font
        let report = try font.convertSimplifiedToTraditional(S2TOptions(mode: .single))
        #expect(glyph(font, "汉") == ops.glyph("uni6F22"))
        #expect(glyph(font, "发") == ops.glyph("uni767C"))
        #expect(glyph(font, "们") == nil, "們 is missing too: nothing could show it")
        #expect(report.missingTraditional.isEmpty, "a character the font never had is not reported missing")
        let added = Set(font.characterMap.mappings.keys).subtracting(stripped.characterMap.mappings.keys)
        #expect(added.isSuperset(of: [0x6C49, 0x53D1]))
        #expect(report.added == added.count)
        // Every added code point shows a traditional glyph the font already had.
        let tables = try OpenCCTables.bundled()
        for codePoint in added {
            let candidates = try #require(tables.simplifiedToTraditional[codePoint])
            #expect(candidates.contains { ops.font.characterMap.mappings[$0] == font.characterMap.mappings[codePoint] })
        }
    }

    @Test func conversionIsIdempotent() throws {
        let (_, once, _) = try converted(S2TOptions(mode: .single, taiwanVariants: true))
        var twice = once
        let report = try twice.convertSimplifiedToTraditional(S2TOptions(mode: .single, taiwanVariants: true))
        #expect(twice.characterMap == once.characterMap)
        #expect(report.remapped == 0)
    }
}
