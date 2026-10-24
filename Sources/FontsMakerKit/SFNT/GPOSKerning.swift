/// What replace did with the second font's kerning (design §5.7).
public struct KerningCopyReport: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        case gpos = "GPOS kern feature"
        case kernTable = "kern table"
    }

    /// Where the second font's kerning came from; nil when it has none.
    public var source: Source?
    /// Pairs between two copied glyphs written into the output's GPOS.
    public var pairs: Int
    /// Pairs of the target's own `kern` table also written into GPOS, so a
    /// shaper that now finds a GPOS `kern` feature, and therefore skips the
    /// `kern` table, still kerns the target's glyphs.
    public var targetKernTablePairs: Int

    public init(source: Source? = nil, pairs: Int = 0, targetKernTablePairs: Int = 0) {
        self.source = source
        self.pairs = pairs
        self.targetKernTablePairs = targetKernTablePairs
    }
}

extension Font {
    /// Kerning between the glyphs replace copied from `donor` (donor glyph →
    /// the copy's ID here), scaled as the copies were, added to this font's
    /// GPOS as one new pair lookup on the `kern` feature of every script and
    /// language system. The copies are new glyph IDs, so the target's own
    /// kerning never reaches them and this lookup reaches nothing else.
    ///
    /// The second font's GPOS `kern` feature is used when it has one, else
    /// its `kern` table, as HarfBuzz and CoreText choose. Pairs with one
    /// copied glyph and one target glyph get nothing: the target's glyphs
    /// were never spaced against the second font's.
    mutating func copyKerning(from donor: Font, copies: [UInt16: UInt16], scale: Double) throws
        -> KerningCopyReport
    {
        let donorGlyphs = Set(copies.keys)
        var report = KerningCopyReport()
        var donorPairs: [GPOS.GlyphPair: GPOS.PairAdjustment] = [:]
        if let gpos = donor.tables["GPOS"], let pairs = try GPOS.kerning(gpos, among: donorGlyphs) {
            report.source = .gpos
            donorPairs = pairs
        } else if let kern = donor.tables["kern"] {
            report.source = .kernTable
            for (pair, value) in try GPOS.legacyKerning(kern, among: donorGlyphs) {
                donorPairs[pair] = GPOS.PairAdjustment(first: GPOS.Value(xAdvance: value))
            }
        }

        var pairs: [GPOS.GlyphPair: GPOS.PairAdjustment] = [:]
        for (pair, adjustment) in donorPairs {
            let scaled = GPOS.PairAdjustment(first: adjustment.first.scaled(scale), second: adjustment.second.scaled(scale))
            guard !scaled.isZero else { continue }
            pairs[GPOS.GlyphPair(left: copies[pair.left]!, right: copies[pair.right]!)] = scaled
        }
        report.pairs = pairs.count
        guard !pairs.isEmpty else { return report }

        let layout = try tables["GPOS"].map { try GSUBLayout(parsing: $0, tag: "GPOS") }
        // A shaper that finds a GPOS kern feature no longer reads the kern
        // table (HarfBuzz; CoreText likewise): the target's own pairs there
        // move into the new lookup, or adding kerning would remove them.
        if let kern = tables["kern"], layout.flatMap(GPOS.kernLookups) == nil {
            let own = try GPOS.legacyKerning(kern, among: nil)
            for (pair, value) in own { pairs[pair] = GPOS.PairAdjustment(first: GPOS.Value(xAdvance: value)) }
            report.targetKernTablePairs = own.count
        }
        var rebuilt =
            layout
            ?? GSUBLayout(scripts: GSUBLayout.withoutGSUB.scripts, features: [], lookups: [], source: [], tag: "GPOS")
        rebuilt.register(feature: "kern", lookups: [UInt16(rebuilt.lookups.count)])
        tables["GPOS"] = try rebuilt.encoded(
            adding: [GSUBLayout.NewLookup(type: 2, subtables: try GPOS.pairSubtables(pairs))])
        return report
    }
}
