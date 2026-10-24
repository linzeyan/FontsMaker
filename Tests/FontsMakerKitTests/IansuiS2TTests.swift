import CoreText
import Foundation
import Testing

@testable import FontsMakerKit

/// s2t on a traditional-only font (Iansui 芫荽, from the catalog): the plan's
/// 4b finding was that it kept showing simplified text as missing glyphs,
/// because only code points the source maps were converted.
struct IansuiS2TTests {
    static let source = "Iansui-Regular.ttf"
    static let sentence = "简体测试：这个国家的发展"
    /// `opencc -c s2tw.json` of the sentence.
    static let traditional = "簡體測試：這個國家的發展"

    private func build(_ steps: String) throws -> (source: Font, built: Data) {
        let bytes = try ReferenceFonts.bytes(IansuiS2TTests.source)
        let recipe = try Recipe(
            json: recipeJSON(
                sourceFile: IansuiS2TTests.source, sha256: sha256Hex(bytes),
                output: #"{"familyName": "Example Hand"}"#, steps: steps))
        let result = try RecipeBuilder.build(recipe, sourceData: Data(bytes), options: BuildOptions())
        return (try Font(bytes: bytes), result.fontData)
    }

    /// Glyphs and fonts CoreText lays out, so fallback to a system font shows up.
    private func layout(_ font: CTFont, _ text: String) -> (glyphs: [CGGlyph], fonts: Set<String>) {
        let attributed = NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font])
        var glyphs: [CGGlyph] = []
        var fonts: Set<String> = []
        for run in CTLineGetGlyphRuns(CTLineCreateWithAttributedString(attributed)) as? [CTRun] ?? [] {
            var runGlyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &runGlyphs)
            glyphs += runGlyphs
            let attributes = CTRunGetAttributes(run) as NSDictionary
            if let runFont = attributes[kCTFontAttributeName as String] {
                fonts.insert(CTFontCopyPostScriptName(runFont as! CTFont) as String)
            }
        }
        return (glyphs, fonts)
    }

    @Test(arguments: [false, true])
    func simplifiedTextShowsTraditionalGlyphs(phrases: Bool) throws {
        let (source, built) = try build(#"[{"op": "s2t", "taiwanVariants": true, "phrases": \#(phrases)}]"#)
        let sourceMap = source.characterMap.mappings
        // The premise: Iansui lacks these simplified characters, so the test
        // fails if a later version of the fixture gains them.
        for missing in "简这发测试".unicodeScalars { #expect(sourceMap[missing.value] == nil, "\(missing)") }

        let expected = IansuiS2TTests.traditional.unicodeScalars.map { try! #require(sourceMap[$0.value]) }
        let output = try Font(data: built)
        let mapped = IansuiS2TTests.sentence.unicodeScalars.map { output.characterMap.mappings[$0.value] }
        #expect(mapped == expected, "every simplified character maps to its traditional character's glyph")

        let coreText = try coreTextFont(built)
        let laidOut = layout(coreText, IansuiS2TTests.sentence)
        #expect(laidOut.fonts == [CTFontCopyPostScriptName(coreText) as String], "no fallback font")
        #expect(laidOut.glyphs == expected)
    }

    /// The phrase rules match the added code points too: 头 and 发 are both
    /// missing from Iansui, and 头发 must read 頭髮, not the character-level 頭發.
    @Test func phraseRulesApplyToAddedCodePoints() throws {
        let (source, built) = try build(#"[{"op": "s2t", "taiwanVariants": true, "phrases": true}]"#)
        let sourceMap = source.characterMap.mappings
        #expect(sourceMap[0x5934] == nil && sourceMap[0x53D1] == nil, "头 and 发 are missing from the source")
        let coreText = try coreTextFont(built)
        func glyphs(_ text: String) -> [CGGlyph] { text.unicodeScalars.map { sourceMap[$0.value] ?? 0 } }
        #expect(layout(coreText, "头发").glyphs == glyphs("頭髮"))
        #expect(layout(coreText, "发展").glyphs == glyphs("發展"))
    }
}
