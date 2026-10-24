/// The OS/2 `USE_TYPO_METRICS` bit (fsSelection bit 7) after lineHeight.
public enum TypoMetricsFlag: Equatable, Sendable {
    /// The source font already set it.
    case alreadySet
    case set
    /// OS/2 version 2 or 3, whose layout is version 4's: the version was
    /// raised to 4, the first to define the bit.
    case setRaisingVersion(from: UInt16)
    /// OS/2 version 0 or 1, where bit 7 is reserved and the table lacks
    /// version 2's fields: not set, so readers that honour the bit read win.
    case unavailable(version: UInt16)
}

extension Font {
    /// lineHeight's second half (design §5.6). Windows GDI clips every glyph
    /// to usWinAscent/usWinDescent, so win now covers the outlines of all
    /// glyphs as well as the line; and USE_TYPO_METRICS tells the readers
    /// that honour it (DirectWrite, which reads win without it; KOReader,
    /// reader-findings.md) to space lines by typo, which keeps the line asked
    /// for. Only GDI, which reads win for the line too, gets a taller line,
    /// when glyphs reach past it.
    ///
    /// All glyphs rather than the ones a cmap reaches: GSUB alternates,
    /// small caps and the like are drawn too, and are clipped the same way.
    /// The writer covers the glyphs again (`winCoversGlyphs`), in case a
    /// later step makes them taller.
    mutating func coverGlyphsWithWin(_ report: inout LineHeightReport) throws {
        guard var os2 else { return }
        if os2.winAscent != nil {
            os2.cover(try verticalGlyphExtent())
            report.winResult = LineMetrics(
                ascender: Int(os2.winAscent!), descender: -Int(os2.winDescent!), lineGap: 0)
            winCoversGlyphs = true
        }
        if os2.fsSelection & 0x80 != 0 {
            report.typoMetrics = .alreadySet
        } else if os2.typoAscender == nil || os2.version < 2 {
            report.typoMetrics = .unavailable(version: os2.version)
        } else {
            report.typoMetrics = os2.version < 4 ? .setRaisingVersion(from: os2.version) : .set
            os2.fsSelection |= 0x80
            os2.version = max(os2.version, 4)
        }
        self.os2 = os2
    }

    /// Highest and lowest outline point over every glyph, composites flattened.
    func verticalGlyphExtent() throws -> (yMax: Int32, yMin: Int32)? {
        var extent: (yMax: Int32, yMin: Int32)?
        for glyphID in glyphs.indices {
            let box: BoundingBox?
            switch glyphs[glyphID].outline {
            case .simple(let outline): box = BoundingBox(outline.points)
            case .composite: box = BoundingBox(try flattenedOutline(of: glyphID).rounded().points)
            }
            guard let box else { continue }
            extent = (max(extent?.yMax ?? box.yMax, box.yMax), min(extent?.yMin ?? box.yMin, box.yMin))
        }
        return extent
    }
}

extension OS2Fields {
    /// win raised, never lowered, to reach from `extent.yMin` to `extent.yMax`.
    mutating func cover(_ extent: (yMax: Int32, yMin: Int32)?) {
        guard let extent, let ascent = winAscent, let descent = winDescent else { return }
        winAscent = UInt16(clamping: max(Int32(ascent), extent.yMax))
        winDescent = UInt16(clamping: max(Int32(descent), -extent.yMin))
    }
}
