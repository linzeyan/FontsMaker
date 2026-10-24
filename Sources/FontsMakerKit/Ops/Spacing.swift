import Foundation

/// Letter spacing (technical design §5.6): font units added to every advance.
public struct TrackingOptions: Equatable, Sendable {
    /// Added after each glyph that has an advance; negative tightens.
    public var units: Int

    public init(units: Int) {
        self.units = units
    }
}

public struct TrackingReport: Equatable, Sendable {
    /// Glyphs whose advance changed: every glyph with a non-zero advance.
    public var glyphs: Int
}

/// Line height (technical design §5.6): the distance between baselines,
/// written the same into hhea and OS/2 typo, and into OS/2 win as far as
/// every glyph still fits (`coverGlyphsWithWin`).
public struct LineHeightOptions: Equatable, Sendable {
    /// Ascender − descender, in font units; the line gaps become 0.
    public var units: Int

    public init(units: Int) {
        self.units = units
    }
}

/// Ascender, descender (negative below the baseline) and line gap, in font units.
public struct LineMetrics: Equatable, Sendable {
    public var ascender: Int
    public var descender: Int
    public var lineGap: Int

    public var height: Int { ascender - descender + lineGap }
}

public struct LineHeightReport: Equatable, Sendable {
    /// Each table's metrics before the step; nil where the OS/2 table has none.
    public var hhea: LineMetrics
    public var typo: LineMetrics?
    public var win: LineMetrics?
    /// What hhea and typo hold now.
    public var result: LineMetrics
    /// What win holds now: `result`, or taller where glyphs reach further.
    public var winResult: LineMetrics? = nil
    /// nil without an OS/2 table.
    public var typoMetrics: TypoMetricsFlag? = nil
}

public enum SpacingError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    case advanceOutOfRange(glyphID: Int, advance: Int, units: Int)
    case lineHeightOutOfRange(units: Int, ascender: Int, descender: Int)

    public var description: String {
        switch self {
        case .advanceOutOfRange(let glyphID, let advance, let units):
            return "tracking \(units): glyph \(glyphID)'s advance \(advance) would become \(advance + units), "
                + "outside 0…65535"
        case .lineHeightOutOfRange(let units, let ascender, let descender):
            return "lineHeight \(units) gives ascender \(ascender) and descender \(descender); the ascender must "
                + "be above the baseline, the descender at or below it, and both fit 16 bits"
        }
    }

    public var errorDescription: String? { description }
}

extension Font {
    /// Adds `units` to every non-zero advance. All of it goes after the glyph,
    /// as CSS letter-spacing does, so outlines do not move: hinting and
    /// composites stay valid and the step is not an outline operation. GPOS
    /// and kern pairs keep working, on top of the new spacing. Zero-width
    /// glyphs (combining marks) keep advance 0, or they would push their
    /// base character's neighbour away.
    public mutating func applyTracking(_ options: TrackingOptions) throws -> TrackingReport {
        var metrics = horizontalMetrics
        var changed = 0
        for glyphID in metrics.indices where metrics[glyphID].advanceWidth > 0 {
            let advance = Int(metrics[glyphID].advanceWidth)
            guard let narrow = UInt16(exactly: advance + options.units) else {
                throw SpacingError.advanceOutOfRange(glyphID: glyphID, advance: advance, units: options.units)
            }
            metrics[glyphID].advanceWidth = narrow
            changed += 1
        }
        horizontalMetrics = metrics
        // Design §4.3: an operation that changes advances owns xAvgCharWidth.
        let average = averageAdvanceWidth()
        os2?.xAvgCharWidth = average
        // hdmx caches every advance per pixel size; kept, it would contradict hmtx.
        tables["hdmx"] = nil
        return TrackingReport(glyphs: changed)
    }

    /// Sets the line to `units`: hhea, OS/2 typo and OS/2 win get the same
    /// ascender and descender and no line gap. Readers pick different tables
    /// (CoreText hhea; KOReader typo when the font sets USE_TYPO_METRICS,
    /// reader-findings.md; Windows win), and some ignore line gaps, so only identical values give
    /// every reader the same line. win then grows where glyphs reach past
    /// the line, and USE_TYPO_METRICS is set, so Windows GDI clips no glyph
    /// (`coverGlyphsWithWin`). The change from hhea's ascender − descender
    /// is split between above and below the baseline, as CSS half-leading
    /// does, so text keeps its place within the line.
    ///
    /// Not combined with pseudoVertical (the recipe refuses it): that step
    /// takes its rotation centre from the typo metrics and sets the column
    /// pitch itself (design §5.3).
    public mutating func applyLineHeight(_ options: LineHeightOptions) throws -> LineHeightReport {
        let hheaBefore = LineMetrics(
            ascender: Int(hhea.ascender), descender: Int(hhea.descender), lineGap: Int(hhea.lineGap))
        let change = options.units - (hheaBefore.ascender - hheaBefore.descender)
        let below = Int((Double(change) / 2).rounded(.down))
        let ascender = hheaBefore.ascender + change - below
        let descender = hheaBefore.descender - below
        guard ascender > 0, descender <= 0, let ascender16 = Int16(exactly: ascender),
            let descender16 = Int16(exactly: descender)
        else {
            throw SpacingError.lineHeightOutOfRange(units: options.units, ascender: ascender, descender: descender)
        }
        var report = LineHeightReport(
            hhea: hheaBefore, result: LineMetrics(ascender: ascender, descender: descender, lineGap: 0))
        hhea = HheaFields(ascender: ascender16, descender: descender16, lineGap: 0)
        if var os2 {
            if let typoAscender = os2.typoAscender, let typoDescender = os2.typoDescender,
                let typoLineGap = os2.typoLineGap
            {
                report.typo = LineMetrics(
                    ascender: Int(typoAscender), descender: Int(typoDescender), lineGap: Int(typoLineGap))
                os2.typoAscender = ascender16
                os2.typoDescender = descender16
                os2.typoLineGap = 0
            }
            if let winAscent = os2.winAscent, let winDescent = os2.winDescent {
                report.win = LineMetrics(ascender: Int(winAscent), descender: -Int(winDescent), lineGap: 0)
                os2.winAscent = UInt16(ascender)
                os2.winDescent = UInt16(-descender)
            }
            self.os2 = os2
        }
        try coverGlyphsWithWin(&report)
        return report
    }
}
