import CoreText
import Foundation
import Testing

@testable import FontsMakerKit

/// English reading tuning (Phase 4c, technical design §5.1, §5.6): embolden
/// that widens, tracking and line height, on Crimson Text, a static, hinted
/// and kerned Latin text face (UPM 1024, hhea line 972 − (−359) = 1331).
struct SpacingTests {
    private static let source = "CrimsonText-Regular.ttf"
    private let output = #"{"familyName": "Reading Serif"}"#

    private func build(_ steps: String) throws -> (BuildResult, Font) {
        let bytes = try ReferenceFonts.bytes(SpacingTests.source)
        let json = recipeJSON(
            sourceFile: SpacingTests.source, sha256: sha256Hex(bytes), output: output, steps: steps)
        let result = try RecipeBuilder.build(try Recipe(json: json), sourceData: Data(bytes), options: BuildOptions())
        return (result, try Font(data: result.fontData))
    }

    /// The letters a reader sets text in; side bearings are what space them.
    private func letters(_ font: Font) -> [(Character, Int)] {
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".map { character in
            (character, Int(font.characterMap.mappings[character.unicodeScalars.first!.value]!))
        }
    }

    /// (left side bearing, right side bearing) of a glyph as written: lsb is
    /// the outline's xMin, rsb what is left of the advance after xMax.
    private func sideBearings(_ font: Font, _ glyphID: Int) throws -> (Int32, Int32) {
        let box = try #require(BoundingBox(try font.flattenedOutline(of: glyphID).rounded().points))
        return (box.xMin, Int32(font.horizontalMetrics[glyphID].advanceWidth) - box.xMax)
    }

    /// Bold without widen keeps every advance, so each letter's ink eats
    /// into the space beside it and Latin text crowds (design §5.1). With
    /// widen, the space between any two letters, rsb of the first plus lsb of
    /// the second, is exactly the source's, and the letters got wider instead.
    @Test func emboldenWidenKeepsTheSpaceBetweenLetters() throws {
        let source = try Font(bytes: try ReferenceFonts.bytes(SpacingTests.source))
        let (_, plain) = try build(#"[{"op": "embolden", "weight": 30}]"#)
        let (result, widened) = try build(#"[{"op": "embolden", "weight": 30, "widen": true}]"#)
        #expect(result.reports.contains { $0.summary.contains("advances widened") })

        var crowded = 0
        for (character, glyphID) in letters(source) {
            let before = try sideBearings(source, glyphID)
            let after = try sideBearings(widened, glyphID)
            #expect(after.0 == before.0 && after.1 == before.1, "\(character): \(before) → \(after)")
            #expect(
                widened.horizontalMetrics[glyphID].advanceWidth >= source.horizontalMetrics[glyphID].advanceWidth + 28,
                "\(character) is wider by about the weight (control points round to integers)")
            let squeezed = try sideBearings(plain, glyphID)
            #expect(plain.horizontalMetrics[glyphID].advanceWidth == source.horizontalMetrics[glyphID].advanceWidth)
            if squeezed.0 + squeezed.1 < before.0 + before.1 { crowded += 1 }
        }
        #expect(crowded == letters(source).count, "without widen every letter loses spacing")
        // Glyphs left alone keep their advance: the space has no outline.
        let space = Int(source.characterMap.mappings[0x20]!)
        #expect(widened.horizontalMetrics[space] == source.horizontalMetrics[space])
        #expect(widened.os2?.xAvgCharWidth != source.os2?.xAvgCharWidth, "advances changed, so xAvgCharWidth did")
    }

    /// A skipped character is not emboldened, so nothing to widen: its advance
    /// stays; a character with its own weight widens by that weight.
    @Test func widenFollowsTheGlyphsOwnWeight() throws {
        let source = try Font(bytes: try ReferenceFonts.bytes(SpacingTests.source))
        let (_, font) = try build(
            #"[{"op": "embolden", "weight": 30, "widen": true, "skip": ["o"], "perCharacter": {"n": {"weight": 10}}}]"#)
        let o = Int(source.characterMap.mappings[0x6F]!)
        let n = Int(source.characterMap.mappings[0x6E]!)
        let m = Int(source.characterMap.mappings[0x6D]!)
        #expect(font.horizontalMetrics[o].advanceWidth == source.horizontalMetrics[o].advanceWidth)
        let nGrowth = Int(font.horizontalMetrics[n].advanceWidth) - Int(source.horizontalMetrics[n].advanceWidth)
        let mGrowth = Int(font.horizontalMetrics[m].advanceWidth) - Int(source.horizontalMetrics[m].advanceWidth)
        #expect((10...14).contains(nGrowth) && (30...40).contains(mGrowth), "n +\(nGrowth), m +\(mGrowth)")
    }

    /// Tracking adds the same units after every glyph, so CoreText, kerning
    /// included, sets a word exactly (letters × units) wider. It moves no
    /// outline: glyf is byte for byte the source's and the hinting stays,
    /// where an outline operation would strip it (design D5).
    @Test func trackingWidensTextByExactlyTheUnits() throws {
        let (plain, plainFont) = try build("[]")
        let (tracked, trackedFont) = try build(#"[{"op": "tracking", "units": 40}]"#)
        #expect(table("glyf", in: [UInt8](tracked.fontData)) == table("glyf", in: [UInt8](plain.fontData)))
        #expect(table("fpgm", in: [UInt8](tracked.fontData)) != nil)
        for (index, metric) in plainFont.horizontalMetrics.enumerated() {
            let expected = metric.advanceWidth == 0 ? 0 : metric.advanceWidth + 40
            #expect(trackedFont.horizontalMetrics[index].advanceWidth == expected)
        }

        let word = "Hamburgefonstiv"
        func width(_ data: Data) throws -> Double {
            let font = try coreTextFont(data, size: 1024)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: word, attributes: [kCTFontAttributeName as NSAttributedString.Key: font]))
            return CTLineGetTypographicBounds(line, nil, nil, nil)
        }
        let added = try width(tracked.fontData) - width(plain.fontData)
        #expect(abs(added - Double(40 * word.count)) < 0.01, "added \(added)")

        let error = #expect(throws: RecipeError.self) {
            try Recipe(
                json: recipeJSON(
                    sourceFile: "a.ttf", sha256: String(repeating: "0", count: 64),
                    output: output, steps: #"[{"op": "tracking", "units": 0}]"#))
        }
        #expect(error?.description.contains("steps[0].units") == true)
        #expect(throws: SpacingError.self) { try build(#"[{"op": "tracking", "units": -2000}]"#) }
    }

    /// CoreText reads hhea, KOReader typo (USE_TYPO_METRICS), Windows win:
    /// after lineHeight all three give the line that was asked for, and
    /// CoreText measures exactly it. The change is split above and below the
    /// baseline, like CSS half-leading.
    @Test func lineHeightIsWhatEveryReaderMeasures() throws {
        let (result, font) = try build(#"[{"op": "lineHeight", "units": 1536}]"#)
        // 1331 → 1536: +205, 102 below the baseline and 103 above.
        #expect(font.hhea == HheaFields(ascender: 1075, descender: -461, lineGap: 0))
        #expect(font.os2?.typoAscender == 1075 && font.os2?.typoDescender == -461 && font.os2?.typoLineGap == 0)
        #expect(font.os2?.winAscent == 1075 && font.os2?.winDescent == 461)
        let coreText = try coreTextFont(result.fontData, size: 1024)
        #expect(abs(CTFontGetAscent(coreText) + CTFontGetDescent(coreText) + CTFontGetLeading(coreText) - 1536) < 0.001)
        #expect(
            result.reports.contains { $0.summary.contains("were hhea 972/-359/0, typo 972/-359/0, win 1106/-297/0") })

        let (_, tighter) = try build(#"[{"op": "lineHeight", "units": 1024}]"#)
        #expect(tighter.hhea == HheaFields(ascender: 819, descender: -205, lineGap: 0))
        #expect(throws: SpacingError.self) { try build(#"[{"op": "lineHeight", "units": 100}]"#) }
    }

    /// pseudoVertical turns glyphs about the typo em box and sets the column
    /// pitch itself; lineHeight would move both, so a recipe cannot have both.
    @Test func lineHeightAndPseudoVerticalAreRefusedTogether() throws {
        let error = #expect(throws: RecipeError.self) {
            try Recipe(
                json: recipeJSON(
                    sourceFile: "a.ttf", sha256: String(repeating: "0", count: 64),
                    output: output, steps: #"[{"op": "lineHeight", "units": 1200}, {"op": "pseudoVertical"}]"#))
        }
        #expect(error?.description.contains("cannot be combined") == true)
    }

    /// The new keys are written only when used, as faceIndex, variation and
    /// phrases are: a recipe from before Phase 4c encodes to the same bytes,
    /// hence the same hash in name ID 5 and the same font.
    @Test func recipesWithoutTheNewStepsEncodeAsBefore() throws {
        let json = recipeJSON(
            sourceFile: "a.ttf", sha256: String(repeating: "0", count: 64), output: output,
            steps: #"[{"op": "embolden", "weight": 12}]"#)
        let canonical = String(decoding: try Recipe(json: json).canonicalJSON(), as: UTF8.self)
        #expect(canonical.contains(#"{"op":"embolden","perCharacter":{},"skip":[],"weight":12}"#))

        let all = recipeJSON(
            sourceFile: "a.ttf", sha256: String(repeating: "0", count: 64), output: output,
            steps:
                #"[{"op": "embolden", "weight": 12, "widen": true}, {"op": "tracking", "units": -8}, {"op": "lineHeight", "units": 1300}]"#
        )
        let recipe = try Recipe(json: all)
        #expect(
            recipe.steps == [
                .embolden(EmboldenStep(weight: 12, widen: true)), .tracking(TrackingOptions(units: -8)),
                .lineHeight(LineHeightOptions(units: 1300)),
            ])
        #expect(try Recipe(json: recipe.canonicalJSON()) == recipe)
    }

    /// The live preview runs the same steps on a few glyphs: its advances and
    /// line metrics are the built font's, so the page lays out as a reader would.
    @Test func previewMatchesTheBuild() throws {
        let steps =
            #"[{"op": "embolden", "weight": 20, "widen": true}, {"op": "tracking", "units": 25}, {"op": "lineHeight", "units": 1400}]"#
        let (result, built) = try build(steps)
        let source = try Font(bytes: try ReferenceFonts.bytes(SpacingTests.source))
        let recipe = try Recipe(
            json: recipeJSON(
                sourceFile: "a.ttf", sha256: String(repeating: "0", count: 64), output: output, steps: steps))
        let text = "Reading, at last."
        let preview = try source.preview(of: text.unicodeScalars.map(\.value), steps: recipe.steps)
        #expect(preview.hhea == built.hhea)
        for scalar in text.unicodeScalars {
            let glyph = try #require(preview.glyphs[scalar.value])
            let builtID = Int(built.characterMap.mappings[scalar.value]!)
            #expect(glyph.advanceWidth == Int(built.horizontalMetrics[builtID].advanceWidth), "\(scalar)")
            #expect(glyph.outline.points == (try built.flattenedOutline(of: builtID).rounded().points), "\(scalar)")
        }
    }
}
