import Foundation

/// Review priority of an emboldened glyph (technical design §5.2); A first.
public enum EmboldenGrade: String, CaseIterable, Comparable, Sendable {
    case a = "A"
    case b = "B"
    case c = "C"
    case d = "D"

    public static func < (lhs: EmboldenGrade, rhs: EmboldenGrade) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Thresholds calibrated by eye on GuanKiapTsingKhai in Phase 0; the first
    /// matching rule wins. Glyphs without counters skip the counter rules.
    static func grade(
        minHoleRatio: Double?, holeVanished: Bool, holeSplit: Bool, pinhole: Bool, bboxGrowth: Double
    ) -> EmboldenGrade {
        let ratio = minHoleRatio ?? .infinity
        if holeVanished || ratio < 0.40 { return .a }
        if ratio < 0.55 || pinhole || bboxGrowth > 2 { return .b }
        // A split is usually a stroke end that nearly touched now making
        // contact; it looked fine on the Phase 0 sheets, so only C.
        if ratio < 0.70 || holeSplit { return .c }
        return .d
    }
}

/// Risk metrics of one emboldened glyph.
public struct EmboldenGlyphReport: Equatable, Sendable {
    public var glyphID: Int
    /// Every code point mapped to the glyph, ascending; empty for unencoded glyphs.
    public var codePoints: [UInt32]
    public var weight: Double
    /// Counters in the source: enclosed holes of at least 400 units².
    public var counters: Int
    /// Smallest share of a counter's area left after emboldening; nil without counters.
    public var minHoleRatio: Double?
    public var holeVanished: Bool
    /// A counter was pinched into several holes.
    public var holeSplit: Bool
    /// A new hole under 100 units² appeared where strokes meet.
    public var pinhole: Bool
    /// Actual bounding-box growth ÷ expected (the weight); ~1 normally.
    public var bboxGrowth: Double
    public var grade: EmboldenGrade

    init(glyphID: Int, codePoints: [UInt32], weight: Double, measurement: EmboldenMeasurement) {
        self.glyphID = glyphID
        self.codePoints = codePoints
        self.weight = weight
        counters = measurement.counters
        minHoleRatio = measurement.minHoleRatio
        holeVanished = measurement.holeVanished
        holeSplit = measurement.holeSplit
        pinhole = measurement.pinhole
        bboxGrowth = measurement.bboxGrowth
        grade = EmboldenGrade.grade(
            minHoleRatio: minHoleRatio, holeVanished: holeVanished, holeSplit: holeSplit, pinhole: pinhole,
            bboxGrowth: bboxGrowth)
    }

    /// The characters for display, leaving out controls and whitespace.
    public var text: String {
        String(
            String.UnicodeScalarView(
                codePoints.compactMap(Unicode.Scalar.init).filter {
                    !$0.properties.isWhitespace && $0.properties.generalCategory != .control
                        && $0.properties.generalCategory != .format
                }))
    }
}

public struct EmboldenReport: Equatable, Sendable {
    /// One entry per emboldened glyph, ascending glyph ID. Skipped glyphs and
    /// glyphs without an outline are not listed.
    public var glyphs: [EmboldenGlyphReport]
    /// Set when widen kept a monospaced font monospaced (design §5.6).
    public var monospace: MonospaceWiden?
    /// Glyphs whose GPOS anchors moved with their widened outline.
    public var anchorsMoved: Int

    public init(glyphs: [EmboldenGlyphReport], monospace: MonospaceWiden? = nil, anchorsMoved: Int = 0) {
        self.glyphs = glyphs
        self.monospace = monospace
        self.anchorsMoved = anchorsMoved
    }

    public func count(of grade: EmboldenGrade) -> Int { glyphs.count { $0.grade == grade } }

    /// RFC 4180 CSV, one row per glyph in glyph ID order.
    public func csv() -> String {
        var lines = [
            "glyph_id,code_points,text,weight,grade,counters,min_hole_ratio,hole_vanished,hole_split,pinhole,bbox_growth"
        ]
        for glyph in glyphs {
            let fields = [
                String(glyph.glyphID),
                glyph.codePoints.map { String(format: "U+%04X", $0) }.joined(separator: " "),
                csvField(glyph.text),
                String(format: "%g", glyph.weight),
                glyph.grade.rawValue,
                String(glyph.counters),
                glyph.minHoleRatio.map { String(format: "%.4f", $0) } ?? "",
                glyph.holeVanished ? "1" : "0",
                glyph.holeSplit ? "1" : "0",
                glyph.pinhole ? "1" : "0",
                String(format: "%.4f", glyph.bboxGrowth),
            ]
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
