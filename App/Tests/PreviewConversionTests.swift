import FontsMakerKit
import Foundation
import Testing

struct PreviewConversionTests {
    /// The preview of a recipe with s2t now converts the text with
    /// `S2TTextConverter` and previews it without the s2t step
    /// (`PageText.preview`), because phrase rules cannot be shown per
    /// character. Without phrases the engine could already run the s2t step
    /// itself, and the package tests hold that path to the built font; this
    /// pins that taking the converter's path for those recipes too changed no
    /// outline or advance, for every character s2t can convert in
    /// GuanKiapTsingKhai, under each kind of s2t step the app's form can give.
    @Test(arguments: [
        [Recipe.Step.s2t(S2TOptions(taiwanVariants: true))],
        [.s2t(S2TOptions(mode: .skipAmbiguous, taiwanVariants: true))],
        [.s2t(S2TOptions(taiwanVariants: false)), .pseudoVertical(PseudoVerticalOptions(punctuation: .centered))],
        [
            .embolden(EmboldenStep(weight: 12)), .s2t(S2TOptions(taiwanVariants: true)),
            .pseudoVertical(PseudoVerticalOptions(punctuation: .centered)),
        ],
    ])
    func characterLevelPreviewIsUnchanged(steps: [Recipe.Step]) throws {
        let font = try Font(data: Data(contentsOf: try TestFonts.reference("GuanKiapTsingKhai.ttf")))
        let tables = try OpenCCTables.bundled()
        let codePoints = font.characterMap.mappings.keys.filter {
            tables.simplifiedToTraditional[$0] != nil || tables.taiwanVariants[$0] != nil
        }.sorted()
        try #require(codePoints.count > 2000)
        let text = String(String.UnicodeScalarView(codePoints.compactMap(Unicode.Scalar.init)))
        let direct = try font.preview(of: codePoints, steps: steps)
        let options = try #require(steps.lazy.compactMap { if case .s2t(let options) = $0 { options } else { nil } }.first)
        let page = try PageText.preview(
            of: text, steps: steps, font: font, converter: S2TTextConverter(font: font, options: options)
        ).page

        var differing: [String] = []
        for (position, scalar) in zip(page.positions, text.unicodeScalars) {
            let old = try #require(direct.glyphs[scalar.value])
            if position.glyph?.path != old.path || position.glyph?.advance != CGFloat(old.advanceWidth) {
                differing.append(String(scalar))
            }
        }
        #expect(differing.isEmpty, "\(differing.count) characters: \(differing.prefix(20).joined())")
        #expect(page.text != text, "the converter did convert")
    }
}
