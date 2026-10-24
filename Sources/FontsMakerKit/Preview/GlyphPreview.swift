import CoreGraphics
import Foundation

/// One character as the built font will show it.
public struct PreviewGlyph: Equatable, Sendable {
    /// The glyph the built font's cmap gives the character; 0 (.notdef) when it has none.
    public var glyphID: Int
    public var advanceWidth: Int
    /// Font units, y up. Composites are flattened, so it can be drawn as is.
    public var outline: SimpleOutline

    public var path: CGPath { outline.cgPath }
}

/// What a reader would see for a few characters after a recipe's steps,
/// computed without building the font (product spec §4.6, design §9).
public struct GlyphPreview: Sendable {
    public var unitsPerEm: Int
    /// The built font's hhea line metrics, read after the steps because
    /// pseudoVertical extends the descender (design §5.3). Ascender −
    /// descender + lineGap is the natural line height CoreText gives the
    /// font, so a page preview lays its lines out by these.
    public var hhea: HheaFields
    /// Keyed by code point; every requested code point is present.
    public var glyphs: [UInt32: PreviewGlyph]
    /// Glyphs the steps ran on. A full build runs on every glyph of the font;
    /// the preview's cost grows with the text, not the font.
    public var processedGlyphs: Int
}

public enum PreviewError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    /// A character ended on a glyph the preview did not process; drawing it
    /// would show a blank where the built font has an outline.
    case glyphOutsideSubset(codePoint: UInt32, glyphID: Int)
    /// The steps have a replace step, and its font (this file) was not given.
    case replacementFontMissing(file: String)

    public var description: String {
        switch self {
        case .glyphOutsideSubset(let codePoint, let glyphID):
            return "Preview error: U+\(hex(codePoint)) ends on glyph \(glyphID), which the preview did not process."
        case .replacementFontMissing(let file):
            return "Preview error: the replace step's font \(file) was not given."
        }
    }

    public var errorDescription: String? { description }
}

extension Font {
    /// Runs `steps` exactly as `RecipeBuilder` does, but on a copy of this
    /// (source) font in which only the glyphs that can end up under
    /// `codePoints` keep their outlines; every other glyph is emptied.
    ///
    /// Why this gives the full build's outlines: embolden and the turn of
    /// pseudoVertical work glyph by glyph, so an emptied glyph cannot change
    /// another; s2t and the placement decisions of pseudoVertical (in place or
    /// cloned, clone IDs) read only the cmap and GSUB, which stay complete.
    /// Glyph IDs therefore match the built font too. A replace step copies
    /// glyph by glyph as well, from a subset of its second font made the same way.
    ///
    /// - Parameter replacements: the replace steps' fonts, keyed by the
    ///   sha256 each step names, loaded with the face and instance it names;
    ///   needed exactly when `steps` has replace steps.
    public func preview(
        of codePoints: some Sequence<UInt32>, steps: [Recipe.Step], replacements: [String: Font] = [:]
    ) throws -> GlyphPreview {
        try steps.checkReplacedOnce()
        // On the whole font, as the build does: a composite left in the
        // subset must find the redrawn glyph it uses (é → e).
        if let outlines = try steps.leadingOutlines() {
            var edited = self
            _ = try edited.applyOutlines(outlines)
            return try edited.preview(of: codePoints, steps: Array(steps.dropFirst()), replacements: replacements)
        }
        let wanted = Set(codePoints)
        let needed = try previewSourceGlyphs(for: wanted, steps: steps)
        var subset = try subset(keeping: needed)
        // By step index, as the build keeps them.
        var replacementSubsets: [Int: Font] = [:]
        for (index, step) in steps.enumerated() {
            guard case .replace(let step) = step else { continue }
            guard let replacement = replacements[step.font.sha256] else {
                throw PreviewError.replacementFontMissing(file: step.font.file)
            }
            // The match reference too: the scale is measured from it.
            let characters = wanted.union(step.match.reference.map { [$0] } ?? [])
            replacementSubsets[index] = try replacement.subset(
                keeping: Set(characters.compactMap { replacement.characterMap.mappings[$0] }.map(Int.init)))
        }

        for (index, step) in steps.enumerated() {
            switch step {
            case .outlines:
                break  // applied above, to the whole font
            case .embolden(let embolden):
                _ = try subset.embolden(try embolden.resolve(in: subset))
            case .tracking(let options):
                _ = try subset.applyTracking(options)
            case .lineHeight(let options):
                _ = try subset.applyLineHeight(options)
            case .s2t(let options):
                _ = try subset.convertSimplifiedToTraditional(options)
            case .pseudoVertical(let options):
                _ = try subset.applyPseudoVertical(options)
            case .replace(let step):
                _ = try subset.replaceGlyphs(step, from: replacementSubsets[index]!)
            }
        }

        var result: [UInt32: PreviewGlyph] = [:]
        for codePoint in wanted {
            let glyphID = Int(subset.characterMap.mappings[codePoint] ?? 0)
            // IDs past the source's are clones pseudoVertical made from needed glyphs.
            guard glyphID >= self.glyphs.count || needed.contains(glyphID),
                case .simple(let outline) = subset.glyphs[glyphID].outline
            else { throw PreviewError.glyphOutsideSubset(codePoint: codePoint, glyphID: glyphID) }
            result[codePoint] = PreviewGlyph(
                glyphID: glyphID, advanceWidth: Int(subset.horizontalMetrics[glyphID].advanceWidth), outline: outline)
        }
        return GlyphPreview(
            unitsPerEm: Int(unitsPerEm), hhea: subset.hhea, glyphs: result, processedGlyphs: needed.count)
    }

    /// This font with every glyph outside `glyphIDs` emptied. The kept ones
    /// are flattened whether or not a step changes outlines: without one the
    /// built font keeps the composite, which renders the same, and its
    /// components may have been emptied here.
    private func subset(keeping glyphIDs: Set<Int>) throws -> Font {
        var subset = self
        var glyphs = [Glyph](repeating: .empty, count: self.glyphs.count)
        for glyphID in glyphIDs {
            glyphs[glyphID] =
                self.glyphs[glyphID].isComposite
                ? Glyph(outline: .simple(try flattenedOutline(of: glyphID).rounded())) : self.glyphs[glyphID]
        }
        subset.glyphs = glyphs
        return subset
    }

    /// Every source glyph a step can route one of `codePoints` to: its own
    /// glyph, the glyphs of all its OpenCC candidates and their Taiwan
    /// variants (s2t), and the vertical alternates of all of those
    /// (pseudoVertical), plus .notdef for unmapped characters. A superset is
    /// harmless (it only costs time); a missing glyph is caught by `preview`.
    func previewSourceGlyphs(for codePoints: Set<UInt32>, steps: [Recipe.Step]) throws -> Set<Int> {
        var reachable = codePoints
        // replace measures its scale from the target's x or H.
        for case .replace(let step) in steps { reachable.formUnion(step.match.reference.map { [$0] } ?? []) }
        for case .s2t(let options) in steps {
            let tables = try OpenCCTables.bundled()
            for codePoint in codePoints {
                let targets = [codePoint] + (tables.simplifiedToTraditional[codePoint] ?? [])
                reachable.formUnion(targets)
                if options.taiwanVariants {
                    reachable.formUnion(targets.compactMap { tables.taiwanVariants[$0]?.first })
                }
            }
        }
        var glyphs = Set(reachable.compactMap { characterMap.mappings[$0] })
        if steps.contains(where: { if case .pseudoVertical = $0 { true } else { false } }) {
            glyphs.formUnion(glyphs.compactMap { verticalSubstitutions[$0] })
        }
        return Set(glyphs.map(Int.init)).union([0])
    }

    /// A glyph's outline for drawing (risk review cells), composites flattened.
    public func path(ofGlyph glyphID: Int) throws -> CGPath {
        switch glyphs[glyphID].outline {
        case .simple(let outline): return outline.cgPath
        case .composite: return try flattenedOutline(of: glyphID).rounded().cgPath
        }
    }
}
