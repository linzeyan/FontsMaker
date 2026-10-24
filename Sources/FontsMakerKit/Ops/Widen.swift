import Foundation

/// How embolden widen spaced a monospaced font (technical design §5.6).
public struct MonospaceWiden: Equatable, Sendable {
    /// The advance every glyph with a width had, and has now.
    public var advanceBefore: Int
    public var advanceAfter: Int
    /// `post.isFixedPitch`; nil without a post table. The advances decide
    /// whether the font is monospaced: the flag is reported when it disagrees.
    public var fixedPitchFlag: Bool?
    /// Glyphs whose outline grew wider than the cell did (miter tips of V,
    /// *, ^ …): they reach into their neighbours' side bearings by up to half
    /// of `maxOverflow` on each side.
    public var overflowing: Int
    public var maxOverflow: Int
}

/// Advances and outline moves for embolden widen, computed before anything
/// is written so a failure leaves the font as it was.
struct WidenPlan {
    var metrics: [HorizontalMetric]
    /// Glyph → units its outline moves right; only non-zero moves.
    var shifts: [Int: Int32]
    var monospace: MonospaceWiden?
}

extension Font {
    /// The advance every glyph with a width shares, or nil when two differ:
    /// a monospaced font. Glyphs of width 0 (combining marks) do not count.
    public var monospacedAdvance: UInt16? {
        var shared: UInt16?
        for metric in horizontalMetrics where metric.advanceWidth > 0 {
            if shared == nil {
                shared = metric.advanceWidth
            } else if shared != metric.advanceWidth {
                return nil
            }
        }
        return shared
    }

    /// `post.isFixedPitch`; nil without a post table.
    var isFixedPitch: Bool? {
        guard let post = tables["post"], post.count >= 16 else { return nil }
        return post.readU16(at: 12) != 0 || post.readU16(at: 14) != 0
    }

    /// Proportional fonts: each emboldened glyph with an advance grows by what
    /// its bounding box gained and moves right by what it gained on the left,
    /// so both side bearings stay the source's (design §5.6).
    ///
    /// Monospaced fonts (`monospacedAdvance`) stay monospaced: every glyph
    /// with an advance, emboldened or not, grows by the same `cell` units, the
    /// largest weight the step uses, rounded. The weight is what a straight
    /// stem or a round bowl gains (half on each side); taking the largest
    /// bounding-box gain instead would let one glyph's miter spike (JetBrains
    /// Mono at weight 30: most glyphs +30, the ` +63, ⋆ +96) set the width of
    /// all. Each glyph then keeps its place in its cell: it moves by what
    /// keeps its left bearing, plus half of what the cell grew beyond the
    /// glyph, so the extra space is split evenly on both sides. A glyph that
    /// grew more than the cell overflows evenly on both sides instead.
    /// Centring rather than keeping the left bearing: monospaced glyphs are
    /// drawn centred in their cells, and narrow ones (i, l, .) would drift
    /// left and leave uneven gaps. Box-drawing strokes that touch both cell
    /// edges grow by exactly the weight, so they still join.
    func widenPlan(_ emboldened: [(glyphID: Int, before: SimpleOutline, after: SimpleOutline)], options: EmboldenOptions)
        throws -> WidenPlan
    {
        var metrics = horizontalMetrics
        var shifts: [Int: Int32] = [:]
        func widen(_ glyphID: Int, by growth: Int32) throws {
            let advance = Int32(metrics[glyphID].advanceWidth) + growth
            guard let narrow = UInt16(exactly: advance) else {
                throw EmboldenError.invalidOption("glyph \(glyphID): widened advance \(advance) is out of range")
            }
            metrics[glyphID].advanceWidth = narrow
        }

        guard let advance = monospacedAdvance else {
            for job in emboldened where metrics[job.glyphID].advanceWidth > 0 {
                guard let before = BoundingBox(job.before.points), let after = BoundingBox(job.after.points)
                else { continue }
                try widen(job.glyphID, by: (after.xMax - after.xMin) - (before.xMax - before.xMin))
                if before.xMin != after.xMin { shifts[job.glyphID] = before.xMin - after.xMin }
            }
            return WidenPlan(metrics: metrics, shifts: shifts, monospace: nil)
        }

        let largest = ([options.weight] + options.perGlyphWeight.values).max()!
        let cell = Int32((largest + 0.5).rounded(.down))
        func half(_ value: Int32) -> Int32 { Int32((Double(value) / 2).rounded(.down)) }
        var report = MonospaceWiden(
            advanceBefore: Int(advance), advanceAfter: Int(advance) + Int(cell), fixedPitchFlag: isFixedPitch,
            overflowing: 0, maxOverflow: 0)
        var emboldenedIDs = Set<Int>()
        for job in emboldened where metrics[job.glyphID].advanceWidth > 0 {
            emboldenedIDs.insert(job.glyphID)
            guard let before = BoundingBox(job.before.points), let after = BoundingBox(job.after.points)
            else { continue }
            let growth = (after.xMax - after.xMin) - (before.xMax - before.xMin)
            if growth > cell {
                report.overflowing += 1
                report.maxOverflow = max(report.maxOverflow, Int(growth - cell))
            }
            let shift = before.xMin - after.xMin + half(cell - growth)
            if shift != 0 { shifts[job.glyphID] = shift }
        }
        for glyphID in metrics.indices where metrics[glyphID].advanceWidth > 0 {
            try widen(glyphID, by: cell)
            // Glyphs left as they are (skipped) move to the middle of the wider cell too.
            if !emboldenedIDs.contains(glyphID), case .simple(let outline) = glyphs[glyphID].outline,
                !outline.isEmpty, half(cell) != 0
            {
                shifts[glyphID] = half(cell)
            }
        }
        return WidenPlan(metrics: metrics, shifts: shifts, monospace: report)
    }
}

extension SimpleOutline {
    func shifted(by dx: Int32) -> SimpleOutline {
        guard dx != 0 else { return self }
        var result = self
        for index in result.points.indices { result.points[index].x += dx }
        return result
    }
}
