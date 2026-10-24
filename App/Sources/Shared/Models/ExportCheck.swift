import CoreGraphics
import CoreText
import FontsMakerKit
import Foundation

/// The exported font file read back through CoreText (product spec §4.6):
/// proves the system can load the file itself, and lays the sample text out
/// with CoreText, shaping included, so the page shows what a reader that
/// shapes with CoreText shows: s2t phrase rules applied, not only the cmap.
struct ExportCheck: Sendable {
    var fontURL: URL
    var recipeURL: URL
    /// The source's license text written beside them; nil when the library
    /// has none for the source (a font imported from a file).
    var licenseURL: URL? = nil
    var sha256: String
    /// The recipe written next to the font.
    var recipe: Recipe
    /// CoreText's full name of the loaded font.
    var fullName: String
    /// The sample text with CoreText's glyphs, per position. A position whose
    /// glyph is not the one the preview drew has U+FFFD as its character:
    /// which character it shows is not known.
    var page: PageText
    /// Positions (into `page.positions`) whose glyph differs from the preview's.
    var mismatches: [Int]
    /// Positions compared: all but newlines.
    var checkedGlyphs: Int

    var matchingGlyphs: Int { checkedGlyphs - mismatches.count }

    enum Failure: Error, LocalizedError {
        case notLoadable(URL)

        var errorDescription: String? {
            switch self {
            case .notLoadable(let url): return "CoreText 無法載入匯出的字型檔 \(url.path)。"
            }
        }
    }

    /// A position matches when CoreText shows exactly one glyph of the file
    /// there, and that glyph has the preview's outline and advance there.
    /// Outlines, not glyph IDs: the preview of s2t-converted text runs on a
    /// font without the s2t step, where pseudoVertical may clone glyphs under
    /// other IDs than in the build (`PageText.preview`). The outline is the
    /// file's as the engine reads the same bytes, so CoreText decides which
    /// glyph a position shows and the file decides what that glyph is.
    ///
    /// - Parameters:
    ///   - text: the sample text, as a reader is given it.
    ///   - expected: the preview of `text` with `recipe` (`PageText.preview`).
    static func run(
        fontURL: URL, recipeURL: URL, sha256: String, recipe: Recipe, text: String, expected: PageText
    ) throws -> ExportCheck {
        let data = try Data(contentsOf: fontURL)
        // CoreText reads these bytes without keeping them alive (see
        // CoreTextOutlines.instanceFont); an optimized build may otherwise
        // release them after their last use below.
        defer { withExtendedLifetime(data) {} }
        guard
            let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
            let descriptor = descriptors.first
        else { throw Failure.notLoadable(fontURL) }
        let file = try Font(data: data)
        let unitsPerEm = CGFloat(file.unitsPerEm)
        // At a size of one em per unit, CoreText paths and advances are in font units.
        let font = CTFontCreateWithFontDescriptor(descriptor, unitsPerEm, nil)

        let scalars = Array(text.unicodeScalars)
        precondition(expected.positions.count == scalars.count, "the preview must be of the same text")
        let shaped = shape(text, with: font)
        var positions: [PageText.Position] = []
        var mismatches: [Int] = []
        for (index, scalar) in scalars.enumerated() {
            if scalar == "\n" {
                positions.append(PageText.Position(scalar: scalar, glyph: nil))
                continue
            }
            let glyphs = shaped[index]
            var advances = [CGSize](repeating: .zero, count: glyphs.count)
            CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
            // A ligature leaves the positions after its first with no glyph;
            // a decomposed character has several.
            let path = CGMutablePath()
            var x: CGFloat = 0
            for (glyph, advance) in zip(glyphs, advances) {
                if let outline = CTFontCreatePathForGlyph(font, glyph, nil) {
                    path.addPath(outline, transform: CGAffineTransform(translationX: x, y: 0))
                }
                x += advance.width
            }
            var matches = false
            if glyphs.count == 1, let wanted = expected.positions[index].glyph, Int(glyphs[0]) < file.glyphs.count {
                let glyph = Int(glyphs[0])
                matches =
                    try file.path(ofGlyph: glyph) == wanted.path
                    && CGFloat(file.horizontalMetrics[glyph].advanceWidth) == wanted.advance
            }
            if !matches { mismatches.append(index) }
            positions.append(
                PageText.Position(
                    scalar: matches ? expected.positions[index].scalar : "\u{FFFD}",
                    glyph: RenderGlyph(path: path, advance: x)))
        }
        // The line too is the file's as CoreText reads it, not the preview's.
        let page = PageText(
            unitsPerEm: unitsPerEm, ascender: CTFontGetAscent(font), descender: -CTFontGetDescent(font),
            lineGap: CTFontGetLeading(font), positions: positions)
        return ExportCheck(
            fontURL: fontURL, recipeURL: recipeURL, sha256: sha256, recipe: recipe,
            fullName: CTFontCopyFullName(font) as String, page: page, mismatches: mismatches,
            checkedGlyphs: scalars.count { $0 != "\n" })
    }

    /// CoreText's glyphs for each Unicode scalar of `text` (none for a
    /// newline), line by line with the default features, as a reader lays
    /// text out. A glyph CoreText takes from a fallback font becomes .notdef:
    /// the exported font cannot show that character, and drawing the other
    /// font's glyph would hide it.
    private static func shape(_ text: String, with font: CTFont) -> [[CGGlyph]] {
        let name = CTFontCopyPostScriptName(font) as String
        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        var result: [[CGGlyph]] = []
        for line in text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            if !result.isEmpty { result.append([]) }
            // CoreText indexes the line in UTF-16 code units.
            var scalarAt: [Int] = []
            for (index, scalar) in line.enumerated() {
                scalarAt += repeatElement(index, count: scalar.utf16.count)
            }
            var glyphs = [[CGGlyph]](repeating: [], count: line.count)
            let string = String(String.UnicodeScalarView(line))
            let laidOut = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
            for case let run as CTRun in CTLineGetGlyphRuns(laidOut) as NSArray {
                let count = CTRunGetGlyphCount(run)
                var ids = [CGGlyph](repeating: 0, count: count)
                var indices = [CFIndex](repeating: 0, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &ids)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let runFont = attributes[kCTFontAttributeName as String].map { $0 as! CTFont }
                let ours = runFont.map { CTFontCopyPostScriptName($0) as String == name } ?? false
                for (glyph, index) in zip(ids, indices) {
                    glyphs[scalarAt[index]].append(ours ? glyph : 0)
                }
            }
            result += glyphs
        }
        return result
    }
}
