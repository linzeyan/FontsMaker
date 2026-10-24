import CoreGraphics
import Foundation
import Testing

struct PageLayoutTests {
    /// Full-width glyphs, 1000 units per em and a 1000-unit line; at 10 pt
    /// every character is 10 pt wide and the natural line is 10 pt.
    private let glyphs = Dictionary(
        uniqueKeysWithValues: "一二三四五六七".unicodeScalars.map {
            ($0.value, RenderGlyph(path: CGMutablePath(), advance: 1000))
        })

    private func page(
        _ text: String, glyphs: [UInt32: RenderGlyph]? = nil, ascender: CGFloat = 880, descender: CGFloat = -120,
        lineGap: CGFloat = 0
    ) -> PageText {
        let glyphs = glyphs ?? self.glyphs
        return PageText(
            unitsPerEm: 1000, ascender: ascender, descender: descender, lineGap: lineGap,
            positions: text.unicodeScalars.map { PageText.Position(scalar: $0, glyph: glyphs[$0.value]) })
    }

    private func lines(_ page: PageText, _ placements: [PageLayout.Placement]) -> [String] {
        Dictionary(grouping: placements, by: { $0.origin.y }).sorted { $0.key < $1.key }.map {
            String(String.UnicodeScalarView($0.value.map { page.positions[$0.index].scalar }))
        }
    }

    /// CJK lines break at any character once the next one would overflow,
    /// newlines start a line, and lines past the page depth are dropped.
    @Test func wrapsLikeAReader() {
        let text = page("一二三四五\n六七")
        let placements = PageLayout.layout(text, fontSize: 10, lineSpacing: 1.5, lineLength: 30, pageDepth: 45)
        #expect(lines(text, placements) == ["一二三", "四五", "六七"])
        #expect(placements.first?.origin.x == 0 && placements[1].origin.x == 10)
        // 1.5 × the 10 pt line: the extra 5 pt is split around it, so the
        // baseline is at 2.5 + the 8.8 pt ascender.
        #expect(abs(placements[0].origin.y - 11.3) < 1e-9)

        let short = PageLayout.layout(text, fontSize: 10, lineSpacing: 1.5, lineLength: 30, pageDepth: 30)
        #expect(short.count == 5, "the third line does not fit in 30 pt")
    }

    /// Placements point at positions, not characters: the same character
    /// can be drawn with different glyphs (s2t phrase rules), and each
    /// position keeps its own.
    @Test func placementsAreByPosition() {
        let wide = RenderGlyph(path: CGMutablePath(), advance: 1000)
        let narrow = RenderGlyph(path: CGMutablePath(), advance: 500)
        let text = PageText(
            unitsPerEm: 1000, ascender: 880, descender: -120, lineGap: 0,
            positions: [
                PageText.Position(scalar: "里", glyph: wide), PageText.Position(scalar: "里", glyph: narrow),
                PageText.Position(scalar: "里", glyph: wide),
            ])
        let placements = PageLayout.layout(text, fontSize: 10, lineSpacing: 1, lineLength: 100, pageDepth: 100)
        #expect(placements.map(\.index) == [0, 1, 2])
        #expect(placements.map(\.origin.x) == [0, 10, 15], "each position advances by its own glyph")
    }

    /// The pitch is the font's own line (hhea ascender − descender + lineGap)
    /// times the multiplier, not a multiple of the font size: a
    /// pseudo-vertical font's 2.224 em line is the column pitch readers show
    /// (design §5.3). At 1× the baseline sits the ascender below the top, as
    /// in CoreText, so the extended descender opens the gap after a column
    /// rather than before the first one.
    @Test func linePitchIsTheFontsOwnLine() {
        let turned = page("一\n二", ascender: 1102, descender: -1122)
        func baselines(_ page: PageText, spacing: CGFloat) -> [CGFloat] {
            PageLayout.layout(page, fontSize: 10, lineSpacing: spacing, lineLength: 30, pageDepth: 100).map(\.origin.y)
        }
        let natural = baselines(turned, spacing: 1)
        #expect(abs(natural[0] - 11.02) < 1e-9 && abs(natural[1] - natural[0] - 22.24) < 1e-9)
        let loose = baselines(turned, spacing: 1.5)
        #expect(abs(loose[1] - loose[0] - 33.36) < 1e-9 && abs(loose[0] - (11.02 + 11.12 / 2)) < 1e-9)

        var gapped = turned
        gapped.lineGap = 200
        #expect(abs(PageLayout.lineHeight(of: gapped, fontSize: 10, lineSpacing: 1) - 24.24) < 1e-9)
    }

    /// Mixed text: a Latin word that would overflow moves to the next line
    /// whole, as readers break Latin at spaces; a word longer than a line
    /// still breaks inside it rather than overflowing.
    @Test func keepsLatinWordsWhole() {
        var glyphs = self.glyphs
        for scalar in "ABCDEFGHIJ ,“".unicodeScalars {
            glyphs[scalar.value] = RenderGlyph(path: CGMutablePath(), advance: 500)
        }
        func lines(_ text: String, depth: CGFloat = 100) -> [String] {
            let mixed = page(text, glyphs: glyphs)
            return self.lines(
                mixed, PageLayout.layout(mixed, fontSize: 10, lineSpacing: 1.5, lineLength: 30, pageDepth: depth))
        }
        #expect(lines("一二 ABC") == ["一二 ", "ABC"])
        #expect(lines("ABCDEFGHIJ") == ["ABCDEF", "GHIJ"])
        #expect(lines("一ABCDEFGHIJ") == ["一", "ABCDEF", "GHIJ"])
        #expect(lines("一二 ABC", depth: 15) == ["一二 "], "the moved word does not fit on the page")
        // English text (Phase 4c): punctuation goes with its word, and the
        // space at a break hangs at the end of the line it ends.
        #expect(lines("ABC DE,") == ["ABC ", "DE,"], "a comma does not start a line")
        #expect(lines("AB “CDE") == ["AB ", "“CDE"], "an opening quote stays with its word")
        #expect(lines("ABCDEF GH") == ["ABCDEF ", "GH"], "the next line does not start with a space")
    }

    /// The pseudo-vertical page is the landscape layout turned a quarter
    /// clockwise: the first line becomes the right-most column, read top down.
    @Test func readerRotationPutsTheFirstLineOnTheRight() {
        let page = CGSize(width: 300, height: 400)
        let rotation = PageLayout.readerRotation(pageSize: page)
        let firstLineStart = CGPoint(x: 0, y: 10).applying(rotation)
        let firstLineLater = CGPoint(x: 100, y: 10).applying(rotation)
        let secondLineStart = CGPoint(x: 0, y: 40).applying(rotation)
        #expect(firstLineStart == CGPoint(x: 290, y: 0))
        #expect(firstLineLater == CGPoint(x: 290, y: 100))
        #expect(secondLineStart.x < firstLineStart.x)
    }
}
