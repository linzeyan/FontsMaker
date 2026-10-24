import Foundation
import Testing

@testable import FontsMakerKit

/// The live preview (product spec §4.6) processes only the glyphs of the
/// sample text. It is only worth showing if it is what the export will
/// contain, so every case compares it with a full build of the same steps.
struct PreviewTests {
    private let output = #"{"familyName": "Preview Check"}"#

    /// Asserts that, for every character of `text`, the preview names the
    /// same glyph as the built font's cmap, with the same advance and outline.
    @discardableResult
    private func expectPreviewMatchesBuild(
        source: [UInt8], fileName: String, steps: String, text: String
    ) throws -> GlyphPreview {
        let recipe = try Recipe(
            json: recipeJSON(sourceFile: fileName, sha256: sha256Hex(source), output: output, steps: steps))
        let built = try Font(
            data: try RecipeBuilder.build(recipe, sourceData: Data(source), options: BuildOptions()).fontData)
        let preview = try Font(bytes: source).preview(of: text.unicodeScalars.map(\.value), steps: recipe.steps)

        var compared = 0
        for scalar in Set(text.unicodeScalars) {
            let glyph = try #require(preview.glyphs[scalar.value], "no preview for U+\(hex(scalar.value))")
            let builtID = Int(built.characterMap.mappings[scalar.value] ?? 0)
            #expect(glyph.glyphID == builtID, "glyph of \(scalar) (U+\(hex(scalar.value)))")
            #expect(
                glyph.advanceWidth == Int(built.horizontalMetrics[builtID].advanceWidth),
                "advance of \(scalar) (U+\(hex(scalar.value)))")
            let builtOutline = try built.flattenedOutline(of: builtID).rounded()
            #expect(
                glyph.outline.points == builtOutline.points && glyph.outline.endPoints == builtOutline.endPoints,
                "outline of \(scalar) (U+\(hex(scalar.value))), glyph \(builtID)")
            compared += 1
        }
        #expect(compared == Set(text.unicodeScalars).count)
        return preview
    }

    /// ops.ttf maps every case the operations distinguish (shared glyphs, a
    /// composite, s2t one-to-many and Taiwan variants, vertical alternates
    /// shared with a direct mapping, R/U/Tu/Tr). Every mapped character plus
    /// one the font lacks, under each step order a recipe can give.
    @Test(arguments: [
        #"[{"op": "embolden", "weight": 12, "skip": ["口"], "perCharacter": {"一": {"weight": 6}}}, {"op": "s2t", "taiwanVariants": true}, {"op": "pseudoVertical"}]"#,
        #"[{"op": "pseudoVertical", "punctuation": "verticalForms"}, {"op": "s2t", "mode": "skipAmbiguous"}, {"op": "embolden", "weight": 20}]"#,
        #"[{"op": "s2t", "taiwanVariants": true}, {"op": "embolden", "weight": 8}]"#,
        #"[{"op": "s2t"}]"#,
        "[]",
    ])
    func opsFixtureMatchesBuild(steps: String) throws {
        let fixture = try OpsFixture()
        let mapped = fixture.font.characterMap.mappings.keys.sorted()
        let text = String(String.UnicodeScalarView(mapped.compactMap(Unicode.Scalar.init))) + "字"
        try expectPreviewMatchesBuild(
            source: try OpsFixture.bytes, fileName: OpsFixture.fileName, steps: steps, text: text)
    }

    /// The real font and the app's heaviest preset path: embolden with
    /// review decisions, s2t with Taiwan variants, pseudoVertical. The text
    /// mixes simplified characters, the glyphs Bailu Kai had to fix by hand,
    /// brackets and punctuation with vertical forms, Latin and digits.
    @Test func guanKiapMatchesBuild() throws {
        let source = try ReferenceFonts.bytes("GuanKiapTsingKhai.ttf")
        let steps = #"""
            [{"op": "embolden", "weight": 12, "skip": ["繁"], "perCharacter": {"鬢": {"weight": 6}}},
             {"op": "s2t", "mode": "single", "taiwanVariants": true},
             {"op": "pseudoVertical", "punctuation": "centered"}]
            """#
        let text = "「这个国家的发展，为后来里程碑。」傳導帳熱繁聯育鬢（括號）『引號』——ABC abc 123！？…、裥"
        let preview = try expectPreviewMatchesBuild(
            source: source, fileName: "GuanKiapTsingKhai.ttf", steps: steps, text: text)
        // The point of the preview: a few dozen glyphs, not 25,098.
        #expect(preview.processedGlyphs < 200, "processed \(preview.processedGlyphs) glyphs")
    }
}
