import FontsMakerKit
import Foundation
import Testing

/// The page's 原字: the sample text in the unmodified source font, shown in
/// place of 成品 (the recipe's steps applied) so a user sees exactly what the
/// steps change. It must be the source whatever the controls say, and cost
/// nothing when the controls move.
@MainActor
struct SourcePageTests {
    /// With every step on, 原字 still draws the typed text with the source's
    /// own glyphs and line: 汉 stays simplified (s2t would show 漢), outlines
    /// are not emboldened, CJK is not turned, and the line is the source's 1
    /// em, not pseudoVertical's 2.224 em column pitch. Turned on the reader's
    /// page, that is the sideways text pseudoVertical exists to fix.
    @Test func sourcePageHasNoSteps() async throws {
        let (_, editor, root) = try await makeEditor([TestFonts.fixture("ops.ttf")])
        defer { try? FileManager.default.removeItem(at: root) }
        let font = try #require(editor.sourceFont?.font)
        editor.sampleText = "汉漢A"
        editor.draft.emboldenWeight = 6
        editor.draft.s2t = S2TOptions(mode: .single, taiwanVariants: false)
        editor.draft.pseudoVertical = PseudoVerticalOptions()
        await editor.previewSettled()

        let source = try #require(editor.sourcePage)
        try #require(source.text == "汉漢A")
        for (position, scalar) in zip(source.positions, "汉漢A".unicodeScalars) {
            let glyphID = Int(try #require(font.characterMap.mappings[scalar.value]))
            #expect(position.glyph?.path == (try font.path(ofGlyph: glyphID)), "\(scalar) is the source's outline")
            #expect(position.glyph?.advance == CGFloat(font.horizontalMetrics[glyphID].advanceWidth))
        }
        #expect(source.ascender == CGFloat(font.hhea.ascender) && source.descender == CGFloat(font.hhea.descender))

        let result = try #require(editor.previewPage)
        try #require(result.text == "漢漢A")
        #expect(result.positions[1].glyph?.path != source.positions[1].glyph?.path)
        #expect(result.lineHeight > source.lineHeight, "成品 has the pseudo-vertical column pitch")
    }

    /// Changing the steps leaves 原字 as it was, not even recomputed: the
    /// very same path objects (a recomputation draws new ones). 成品 follows.
    @Test func sourcePageIgnoresStepChanges() async throws {
        let (_, editor, root) = try await makeEditor([TestFonts.fixture("ops.ttf")])
        defer { try? FileManager.default.removeItem(at: root) }
        editor.sampleText = "汉漢A"
        await editor.previewSettled()
        let before = try #require(editor.sourcePage)

        editor.draft.emboldenWeight = 6
        await editor.previewSettled()
        editor.draft.s2t = S2TOptions(mode: .single, taiwanVariants: false)
        await editor.previewSettled()
        editor.draft.pseudoVertical = PseudoVerticalOptions()
        await editor.previewSettled()

        #expect(editor.previewPage?.text == "漢漢A", "成品 followed the steps")
        let after = try #require(editor.sourcePage)
        #expect(after.text == before.text)
        try #require(after.positions.count == before.positions.count)
        for (now, then) in zip(after.positions, before.positions) {
            #expect(now.glyph?.path === then.glyph?.path, "\(now.scalar) was drawn again")
        }
    }

    /// A new sample text gives a new 原字, with steps on or off.
    @Test func sourcePageFollowsTheText() async throws {
        let (_, editor, root) = try await makeEditor([TestFonts.fixture("ops.ttf")])
        defer { try? FileManager.default.removeItem(at: root) }
        let font = try #require(editor.sourceFont?.font)
        editor.sampleText = "汉A"
        await editor.previewSettled()
        #expect(editor.sourcePage?.text == "汉A")

        editor.draft.s2t = S2TOptions(mode: .single, taiwanVariants: false)
        editor.sampleText = "A\n汉"
        await editor.previewSettled()
        let page = try #require(editor.sourcePage)
        try #require(page.text == "A\n汉")
        #expect(page.positions[1].glyph == nil, "a newline is not drawn")
        let han = Int(try #require(font.characterMap.mappings[0x6C49]))
        #expect(page.positions[2].glyph?.path == (try font.path(ofGlyph: han)), "汉, not s2t's 漢")
        #expect(editor.previewPage?.text == "A\n漢")
    }
}
