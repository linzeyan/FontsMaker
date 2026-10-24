import CoreGraphics
import FontsMakerKit
import Foundation

/// A glyph ready to draw: outline in font units (y up) and its advance.
struct RenderGlyph: @unchecked Sendable {
    // CGPath is immutable once built; CoreGraphics does not mark it Sendable.
    var path: CGPath
    var advance: CGFloat
}

/// A text as one font shows it, ready to lay out: the font's line metrics
/// and, for every Unicode scalar of the text, the glyph drawn there. Per
/// position rather than per character, because a shaper's phrase rules (s2t
/// `phrases`, design §5.4) show one character differently in different words.
struct PageText: Sendable {
    struct Position: Sendable {
        var scalar: Unicode.Scalar
        /// nil for a newline, which is not drawn.
        var glyph: RenderGlyph?
    }

    var unitsPerEm: CGFloat
    /// Line metrics in font units (hhea; descender negative), as CoreText
    /// reads them: the font's natural line is ascender − descender + lineGap.
    var ascender: CGFloat
    var descender: CGFloat
    var lineGap: CGFloat
    var positions: [Position]

    /// `text` drawn with the engine preview's glyphs, which are keyed by character.
    init(_ text: String, preview: GlyphPreview) {
        unitsPerEm = CGFloat(preview.unitsPerEm)
        ascender = CGFloat(preview.hhea.ascender)
        descender = CGFloat(preview.hhea.descender)
        lineGap = CGFloat(preview.hhea.lineGap)
        positions = text.unicodeScalars.map { scalar in
            let glyph = scalar == "\n" ? nil : preview.glyphs[scalar.value]
            return Position(
                scalar: scalar, glyph: glyph.map { RenderGlyph(path: $0.path, advance: CGFloat($0.advanceWidth)) })
        }
    }

    init(unitsPerEm: CGFloat, ascender: CGFloat, descender: CGFloat, lineGap: CGFloat, positions: [Position]) {
        self.unitsPerEm = unitsPerEm
        self.ascender = ascender
        self.descender = descender
        self.lineGap = lineGap
        self.positions = positions
    }

    /// The characters the page shows.
    var text: String { String(String.UnicodeScalarView(positions.map(\.scalar))) }

    /// Font units. For a pseudo-vertical font this is the column pitch (design §5.3).
    var lineHeight: CGFloat { ascender - descender + lineGap }

    /// `text` as a font built from `font` with `steps` shows it, computed by
    /// the engine preview without building the font (design §9). The preview
    /// draws a glyph per character and shapes nothing, so an s2t step is
    /// replaced by `converter`: the text is converted the way the built font
    /// shows it, phrase rules included, and the converted text goes through
    /// the other steps. In the app's step order those only replace Latin
    /// glyphs (characters OpenCC never converts), embolden (before
    /// s2t, by the source's characters), borrow risky CJK glyphs (before s2t,
    /// which points a simplified character at its traditional form's glyph,
    /// borrowed or not, as the converted text does) or turn glyphs (after
    /// it, by vertical orientation, which every OpenCC conversion keeps), so
    /// each position gets the outline the built font shows there.
    ///
    /// - Parameter converter: the s2t step's (`S2TTextConverter` for the
    ///   source font and its options); required exactly when `steps` has one.
    /// - Parameter replacements: the replace steps' second fonts, by sha256.
    static func preview(
        of text: String, steps: [Recipe.Step], font: Font, converter: S2TTextConverter?,
        replacements: [String: Font] = [:]
    ) throws -> (page: PageText, preview: GlyphPreview) {
        let otherSteps = steps.filter { if case .s2t = $0 { false } else { true } }
        precondition(
            (otherSteps.count < steps.count) == (converter != nil), "a converter stands for the s2t step, and only for it")
        let shown = converter?.convert(text) ?? text
        let preview = try font.preview(
            of: shown.unicodeScalars.map(\.value).filter { $0 != 0x0A }, steps: otherSteps, replacements: replacements)
        return (PageText(shown, preview: preview), preview)
    }
}

/// How a page is shown: as laid out, or turned the way a pseudo-vertical font is read.
enum PageOrientation: CaseIterable, Identifiable {
    case horizontal
    case readerRotated

    var id: Self { self }

    var title: String {
        switch self {
        case .horizontal: "橫排"
        case .readerRotated: "偽直排（轉 90° 閱讀）"
        }
    }

    /// How a reader shows a font built with `steps`: turned when they
    /// include pseudoVertical (design §5.3).
    init(steps: [Recipe.Step]) {
        self = steps.contains { if case .pseudoVertical = $0 { true } else { false } } ? .readerRotated : .horizontal
    }
}

/// Lays text out the way a reader app does with a plain font: horizontal
/// lines, any character may start a line (CJK), newlines respected.
enum PageLayout {
    struct Placement: Equatable {
        /// Index into `PageText.positions`.
        var index: Int
        /// Left end of the glyph's baseline, in points; y grows down the page.
        var origin: CGPoint
    }

    /// The distance between baselines in points: the font's own line height
    /// at this size, times `lineSpacing`.
    static func lineHeight(of page: PageText, fontSize: CGFloat, lineSpacing: CGFloat) -> CGFloat {
        page.lineHeight * fontSize / page.unitsPerEm * lineSpacing
    }

    /// - Parameters:
    ///   - lineSpacing: multiple of the font's own line height; 1 is the
    ///     font's natural line, as CoreText sets it.
    ///   - lineLength: usable width of a line in points.
    ///   - pageDepth: usable height in points; lines that would not fit are dropped.
    static func layout(
        _ page: PageText, fontSize: CGFloat, lineSpacing: CGFloat, lineLength: CGFloat, pageDepth: CGFloat
    ) -> [Placement] {
        let scale = fontSize / page.unitsPerEm
        let lineHeight = PageLayout.lineHeight(of: page, fontSize: fontSize, lineSpacing: lineSpacing)
        // At 1× the baseline sits the ascender below the top of the line, as
        // CoreText places it: a pseudo-vertical font's extended descender then
        // falls between columns, not before the first one. Spacing added
        // beyond the font's line is split above and below it, like CSS
        // half-leading.
        let firstBaseline = page.ascender * scale + (lineHeight - page.lineHeight * scale) / 2
        var placements: [Placement] = []
        var line = 0
        var x: CGFloat = 0
        var lineStart = 0
        /// Where the current run of Latin letters and digits began.
        var wordStart: Int?
        func lineFits(_ line: Int) -> Bool { CGFloat(line + 1) * lineHeight <= pageDepth + 0.5 }
        for (index, position) in page.positions.enumerated() {
            let scalar = position.scalar
            if scalar == "\n" {
                line += 1
                x = 0
                lineStart = placements.count
                wordStart = nil
                continue
            }
            // Latin text breaks only at spaces, so punctuation stays with its
            // word ("vow!”", "0,"); CJK breaks between any two characters.
            let isWhitespace = scalar.properties.isWhitespace
            let isWordCharacter = scalar.value < 0x2E80 && !isWhitespace
            if !isWordCharacter {
                wordStart = nil
            } else if wordStart == nil {
                wordStart = placements.count
            }
            let advance = (position.glyph?.advance ?? 0) * scale
            // A space at the end of a line hangs past it, as readers set it,
            // rather than starting the next line indented.
            if x > 0 && x + advance > lineLength && !isWhitespace {
                line += 1
                // A Latin word moves to the next line whole, as readers break
                // it at spaces; unless it fills the line on its own.
                if let start = wordStart, start > lineStart, start < placements.count {
                    let shift = placements[start].origin.x
                    for index in start..<placements.count {
                        placements[index].origin.x -= shift
                        placements[index].origin.y += lineHeight
                    }
                    x -= shift
                    lineStart = start
                } else {
                    x = 0
                    lineStart = placements.count
                }
                if !lineFits(line) { placements.removeSubrange(lineStart...) }
            }
            guard lineFits(line) else { break }
            placements.append(
                Placement(index: index, origin: CGPoint(x: x, y: firstBaseline + CGFloat(line) * lineHeight)))
            x += advance
        }
        return placements
    }

    /// The transform from glyph space (font units, y up) to page points for a glyph at `origin`.
    static func glyphTransform(origin: CGPoint, fontSize: CGFloat, unitsPerEm: CGFloat) -> CGAffineTransform {
        let scale = fontSize / unitsPerEm
        return CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: origin.x, ty: origin.y)
    }

    /// A pseudo-vertical font is read on a reader set to landscape and held
    /// in portrait: the lines laid out along the long side become columns,
    /// first line on the right. This maps that landscape layout (lines of
    /// length `pageSize.height`) onto the portrait page the reader sees.
    static func readerRotation(pageSize: CGSize) -> CGAffineTransform {
        // (u, v) → (width − v, u): a quarter turn clockwise, y down.
        CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: pageSize.width, ty: 0)
    }
}
