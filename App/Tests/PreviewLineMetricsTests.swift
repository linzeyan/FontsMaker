import FontsMakerKit
import Foundation
import Testing

struct PreviewLineMetricsTests {
    /// The page preview must space lines as the built font will: for a
    /// pseudo-vertical font that line is the column pitch a reader shows
    /// (2.224 em, design §5.3), which the 3a preview hid behind a font-size
    /// multiple. For each combination of effects, the subset preview's line
    /// metrics are the hhea of the full build of the same recipe, and the
    /// page lays its lines out at exactly that pitch.
    @Test(arguments: [
        [Recipe.Step.embolden(EmboldenStep(weight: RecipeDraft.defaultWeight))],
        [.pseudoVertical(PseudoVerticalOptions())],
        [.s2t(RecipeDraft.defaultS2T)],
        [.embolden(EmboldenStep(weight: RecipeDraft.defaultWeight)), .pseudoVertical(PseudoVerticalOptions())],
    ])
    func previewLineIsTheBuiltLine(steps: [Recipe.Step]) throws {
        let data = try Data(contentsOf: try TestFonts.reference("GuanKiapTsingKhai.ttf"))
        let source = try Font(data: data)
        let recipe = Recipe(
            source: Recipe.Source(file: "GuanKiapTsingKhai.ttf", sha256: sha256Hex(data)),
            output: Recipe.Output(familyName: "Line Test", styleName: "Regular"),
            steps: steps)
        let built = try Font(data: try RecipeBuilder.build(recipe, sourceData: data, options: BuildOptions()).fontData)

        let preview = try source.preview(of: "天地。「」A".unicodeScalars.map(\.value), steps: recipe.steps)
        #expect(preview.hhea == built.hhea)

        let page = PageText("天\n地", preview: preview)
        let placements = PageLayout.layout(page, fontSize: 10, lineSpacing: 1, lineLength: 100, pageDepth: 100)
        try #require(placements.count == 2)
        let builtLine = Int(built.hhea.ascender) - Int(built.hhea.descender) + Int(built.hhea.lineGap)
        let pitch = placements[1].origin.y - placements[0].origin.y
        #expect(abs(pitch - CGFloat(builtLine) * 10 / CGFloat(built.unitsPerEm)) < 1e-9)

        // What the user should see: pseudo-vertical fonts give the
        // reference fonts' column pitch, the others keep the source's line.
        let isPseudoVertical = recipe.steps.contains { $0.op == "pseudoVertical" }
        let sourceLine = Int(source.hhea.ascender) - Int(source.hhea.descender) + Int(source.hhea.lineGap)
        #expect(builtLine == (isPseudoVertical ? 2224 : sourceLine))
        #expect(isPseudoVertical || sourceLine == 1406)
    }
}
