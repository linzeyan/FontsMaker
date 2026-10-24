import Foundation

/// Pseudo-vertical layout (technical design §5.3): glyphs are turned 90°
/// counter-clockwise so that text set horizontally reads as vertical text
/// once the reader turns the page 90° clockwise. For readers without real
/// vertical layout support.
public struct PseudoVerticalOptions: Equatable, Sendable {
    public var punctuation: PunctuationMode

    public init(punctuation: PunctuationMode = .centered) {
        self.punctuation = punctuation
    }
}

/// Handling of Tu punctuation (、。，．！？ and the small forms).
public enum PunctuationMode: String, CaseIterable, Sendable {
    /// Taiwan convention: the horizontal glyph moved to the centre of the em box.
    case centered
    /// The font's own vertical alternate (GSUB `vert`/`vrt2`), as in Japanese layout.
    case verticalForms
}

/// Unicode Vertical_Orientation (UAX #50).
public enum VerticalOrientation: String, CaseIterable, Sendable {
    /// Upright in vertical text (CJK ideographs, kana).
    case upright = "U"
    /// Sideways in vertical text (Latin, most symbols).
    case rotated = "R"
    /// Needs a vertical form; falls back to upright (、。，).
    case transformedUpright = "Tu"
    /// Needs a vertical form; falls back to sideways (brackets, quotes, ー).
    case transformedRotated = "Tr"
}

/// The bundled `VerticalOrientation.txt` (Resources/Unicode, Unicode License).
public struct VerticalOrientationTable: Sendable {
    struct Range: Sendable {
        var lower: UInt32
        var upper: UInt32
        var value: VerticalOrientation
    }

    let ranges: [Range]

    /// Parsed once per process. Loading fails loudly, never silently empty.
    public static func bundled() throws -> VerticalOrientationTable {
        try cached.get()
    }

    private static let cached = Result<VerticalOrientationTable, any Error> { try parseBundled() }

    private static func parseBundled() throws -> VerticalOrientationTable {
        let name = "Unicode/VerticalOrientation.txt"
        guard
            let url = Bundle.module.url(
                forResource: "VerticalOrientation", withExtension: "txt", subdirectory: "Unicode")
        else { throw ResourceError.missing(name) }
        var ranges: [Range] = []
        let text = try String(contentsOf: url, encoding: .utf8)
        for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let data = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            if data.allSatisfy(\.isWhitespace) { continue }
            let fields = data.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            let bounds = fields.first?.split(separator: ".", omittingEmptySubsequences: true) ?? []
            guard fields.count == 2, (1...2).contains(bounds.count),
                let lower = UInt32(bounds[0], radix: 16), let upper = UInt32(bounds[bounds.count - 1], radix: 16),
                let value = VerticalOrientation(rawValue: fields[1])
            else { throw ResourceError.malformed("\(name) line \(number + 1)") }
            ranges.append(Range(lower: lower, upper: upper, value: value))
        }
        ranges.sort { $0.lower < $1.lower }
        return VerticalOrientationTable(ranges: ranges)
    }

    /// Code points the file does not list are R (its `@missing` line).
    public func orientation(of codePoint: UInt32) -> VerticalOrientation {
        var low = 0
        var high = ranges.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let range = ranges[middle]
            if codePoint < range.lower {
                high = middle - 1
            } else if codePoint > range.upper {
                low = middle + 1
            } else {
                return range.value
            }
        }
        return .rotated
    }
}

public struct PseudoVerticalReport: Equatable, Sendable {
    /// Mapped code points per Vertical_Orientation class.
    public var codePoints: [VerticalOrientation: Int] = [:]
    /// Code points the reader sees upright (glyph turned).
    public var turned = 0
    /// ... of which through the font's vertical alternate.
    public var viaVerticalForms = 0
    /// ... of which Tu punctuation moved to the em-box centre first.
    public var centered = 0
    /// R code points, and Tr ones without a vertical alternate: left as they are.
    public var leftSideways = 0
    /// Glyphs transformed in place.
    public var transformedGlyphs = 0
    /// Glyphs appended because the same glyph was also needed untransformed or
    /// transformed differently (cmap split, design §4.2).
    public var clonedGlyphs = 0
    /// Extended so the line is `Font.pseudoVerticalLineHeight` em tall; nil
    /// when the line already was (or, for win, the OS/2 table has no win metrics).
    public var hheaDescender: MetricChange?
    public var winDescent: MetricChange?
}

public struct MetricChange: Equatable, Sendable {
    public var before: Int
    public var after: Int
}

extension Font {
    /// Rotates the glyphs of upright code points 90° counter-clockwise.
    ///
    /// Each code point gets a (glyph, placement) target from its Unicode
    /// Vertical_Orientation; each distinct target is materialized once, in
    /// place when no code point still needs the glyph as it was, otherwise as
    /// an appended clone, and the cmap is pointed at the result. A glyph
    /// shared by several code points is therefore never transformed twice.
    ///
    /// Geometry, all integer (TrueType points are integers, a quarter turn
    /// keeps them so): with A/D the typo ascender/descender and `adv` the
    /// glyph's horizontal advance, a point maps as
    ///     x' = A − y,    y' = x + ⌊(A + D − adv) / 2⌋
    /// That is a quarter turn about the em-box centre (adv/2, (A+D)/2): the
    /// turned em box spans x = 0…A − D, and A − D, the em-box height, becomes
    /// the advance of every turned glyph. Not vmtx (design §5.3):
    /// GuanKiapTsingKhai's vertical advances mix 1120 and 1000, which would
    /// space a column loosely and unevenly. For full-width glyphs
    /// (adv = A − D) it is exactly the rotation about the centre; a
    /// proportional glyph keeps its position along the column, as in real
    /// vertical layout, and is centred across it. The floor only matters for
    /// odd sums and shifts by half a unit at most.
    ///
    /// Zero-width glyphs (combining marks: U+3099, U+309A, U+302A–302D) keep
    /// advance 0 and turn as if full-width (adv = A − D), as in
    /// GuanKiapTsingKhai-90; see `turnedOutline`.
    public mutating func applyPseudoVertical(_ options: PseudoVerticalOptions) throws -> PseudoVerticalReport {
        let orientations = try VerticalOrientationTable.bundled()
        // A composite whose component is turned in place would be turned twice.
        if glyphs.contains(where: \.isComposite) { try decomposeComposites() }

        func target(_ codePoint: UInt32, showing glyph: UInt16) -> Target {
            let alternate = verticalSubstitutions[glyph]
            switch orientations.orientation(of: codePoint) {
            case .rotated:
                return Target(glyph: glyph, placement: nil)
            case .transformedRotated:
                // Without a vertical form the sideways glyph is already the
                // right shape once the page is turned (「 turned is ﹁).
                return Target(glyph: alternate ?? glyph, placement: alternate == nil ? nil : .turned)
            case .transformedUpright where options.punctuation == .centered && Font.isPunctuation(codePoint):
                return Target(glyph: glyph, placement: .centeredTurned)
            case .upright, .transformedUpright:
                return Target(glyph: alternate ?? glyph, placement: .turned)
            }
        }

        var report = PseudoVerticalReport()
        var targets: [UInt32: Target] = [:]
        for (codePoint, glyph) in characterMap.mappings.sorted(by: { $0.key < $1.key }) {
            report.codePoints[orientations.orientation(of: codePoint), default: 0] += 1
            let target = target(codePoint, showing: glyph)
            targets[codePoint] = target
            switch target.placement {
            case nil: report.leftSideways += 1
            case .turned:
                report.turned += 1
                if target.glyph != glyph { report.viaVerticalForms += 1 }
            case .centeredTurned:
                report.turned += 1
                report.centered += 1
            }
        }

        // s2t phrases (design §5.4): the phrase rules substitute glyphs that
        // may show no code point (后's own glyph once 后 shows 後, for 皇后),
        // so each turns as the character it shows would, like one more code point.
        var phraseTargets: [UInt32: Target] = [:]
        for (character, glyph) in phrasePlan?.targetGlyphs ?? [:] {
            phraseTargets[character] = target(character, showing: glyph)
        }

        var placementsByGlyph: [UInt16: Set<Placement?>] = [:]
        for target in Array(targets.values) + phraseTargets.values {
            placementsByGlyph[target.glyph, default: []].insert(target.placement)
        }

        let source = self
        let (ascender, descender) = emBoxVerticalExtent()
        guard let turnedAdvance = UInt16(exactly: ascender - descender), turnedAdvance > 0 else {
            throw FontWriteError.unencodable(
                "em box from ascender \(ascender) to descender \(descender) cannot be a glyph advance")
        }
        var resolved: [Target: UInt16] = [:]
        for (glyph, placements) in placementsByGlyph.sorted(by: { $0.key < $1.key }) {
            // The original slot stays untouched while any code point needs it
            // as it is: GSUB/GPOS references to it then keep their meaning.
            var slotFree = !placements.contains(nil)
            for placement in placements.compactMap({ $0 }).sorted() {
                let index = Int(glyph)
                let outline = try source.turnedOutline(
                    of: index, centered: placement == .centeredTurned, ascender: ascender, descender: descender)
                // A combining mark given the em-box height would take a full em
                // of the column after its base character (design §5.3).
                let sourceAdvance = source.horizontalMetrics[index].advanceWidth
                let metric = HorizontalMetric(
                    advanceWidth: sourceAdvance == 0 ? 0 : turnedAdvance,
                    leftSideBearing: source.horizontalMetrics[index].leftSideBearing)
                let turned = Glyph(outline: .simple(outline))
                let target = Target(glyph: glyph, placement: placement)
                if slotFree {
                    glyphs[index] = turned
                    horizontalMetrics[index] = metric
                    resolved[target] = glyph
                    slotFree = false
                    report.transformedGlyphs += 1
                } else {
                    resolved[target] = try appendGlyph(
                        turned, horizontal: metric, vertical: source.verticalMetrics?[index])
                    report.clonedGlyphs += 1
                }
            }
        }
        for (codePoint, target) in targets where target.placement != nil {
            characterMap.mappings[codePoint] = resolved[target]
        }
        for (character, target) in phraseTargets where target.placement != nil {
            phrasePlan?.targetGlyphs[character] = resolved[target]
        }

        // Design §4.3: an operation that changes advances owns xAvgCharWidth.
        if horizontalMetrics.map(\.advanceWidth) != source.horizontalMetrics.map(\.advanceWidth), var os2 {
            os2.xAvgCharWidth = averageAdvanceWidth()
            self.os2 = os2
        }
        try extendLineHeight(&report)
        return report
    }

    /// Minimum hhea and win line height in em (design §5.3, 欄距). Once the
    /// page is turned, the horizontal line height is the pitch between
    /// columns. GuanKiapTsingKhai-90 and BailuKai-Medium-90, the community
    /// pseudo-vertical fonts, take it from their sources' 1.406 em (1102 + 304
    /// units) to 2.224 em by extending only the descender (−304 → −1122), so
    /// that column spacing is what readers of pseudo-vertical fonts know.
    static let pseudoVerticalLineHeight = 2.224

    /// Grows the hhea descender and usWinDescent, each independently, until
    /// its line reaches `pseudoVerticalLineHeight`, as the references do: the
    /// added space falls between columns, the first line keeps its distance
    /// from the top of the frame. A taller line is never shrunk. Typo metrics
    /// stay as they are: the rotation centre is derived from them.
    mutating func extendLineHeight(_ report: inout PseudoVerticalReport) throws {
        let minimum = Int((Font.pseudoVerticalLineHeight * Double(unitsPerEm)).rounded())
        let hheaHeight = Int(hhea.ascender) - Int(hhea.descender) + Int(hhea.lineGap)
        if hheaHeight < minimum {
            let descender = Int(hhea.descender) - (minimum - hheaHeight)
            guard let narrow = Int16(exactly: descender) else {
                throw FontWriteError.unencodable("hhea descender \(descender) for a \(minimum)-unit line")
            }
            report.hheaDescender = MetricChange(before: Int(hhea.descender), after: descender)
            hhea.descender = narrow
        }
        if var os2, let ascent = os2.winAscent, let descent = os2.winDescent, Int(ascent) + Int(descent) < minimum {
            let extended = minimum - Int(ascent)
            guard let narrow = UInt16(exactly: extended) else {
                throw FontWriteError.unencodable("usWinDescent \(extended) for a \(minimum)-unit line")
            }
            report.winDescent = MetricChange(before: Int(descent), after: extended)
            os2.winDescent = narrow
            self.os2 = os2
        }
    }

    enum Placement: Int, Comparable, Hashable {
        case turned = 1
        case centeredTurned = 2

        static func < (lhs: Placement, rhs: Placement) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// What a code point should show: `glyph` as it is (placement nil) or transformed.
    struct Target: Hashable {
        var glyph: UInt16
        var placement: Placement?
    }

    static func isPunctuation(_ codePoint: UInt32) -> Bool {
        guard let scalar = Unicode.Scalar(codePoint) else { return false }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
            .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    /// Typo ascender/descender define the em box (design §5.3); hhea is the
    /// fallback for an OS/2 table too old to carry them.
    func emBoxVerticalExtent() -> (Int32, Int32) {
        if let ascender = os2?.typoAscender, let descender = os2?.typoDescender {
            return (Int32(ascender), Int32(descender))
        }
        return (Int32(hhea.ascender), Int32(hhea.descender))
    }

    func turnedOutline(of glyphID: Int, centered: Bool, ascender: Int32, descender: Int32) throws -> SimpleOutline {
        guard case .simple(var outline) = glyphs[glyphID].outline else {
            throw FontWriteError.unencodable("glyph \(glyphID): composite glyphs must be decomposed before turning")
        }
        guard let box = BoundingBox(outline.points) else { return outline }
        // A zero-width mark has no box of its own to be centred across, so it
        // takes the full-width turn about ((A − D)/2, (A + D)/2), which is what
        // GuanKiapTsingKhai-90 applies to its marks (x' = 880 − y, y' = x − 120).
        // Centring on adv/2 = 0 instead would move it 500 units across the column.
        let sourceAdvance = Int32(horizontalMetrics[glyphID].advanceWidth)
        let advance = sourceAdvance == 0 ? ascender - descender : sourceAdvance
        var dx: Int32 = 0
        var dy: Int32 = 0
        if centered {
            // Move the outline's bbox centre onto the em-box centre (adv/2, (A+D)/2).
            dx = (advance - box.xMin - box.xMax) >> 1
            dy = (ascender + descender - box.yMin - box.yMax) >> 1
        }
        let crossShift = (ascender + descender - advance) >> 1
        for index in outline.points.indices {
            let x = outline.points[index].x + dx
            let y = outline.points[index].y + dy
            outline.points[index].x = ascender - y
            outline.points[index].y = x + crossShift
        }
        return outline
    }

    /// OS/2 v3+ definition (and fontTools' recalculation): the rounded mean of
    /// all non-zero advance widths.
    func averageAdvanceWidth() -> Int16 {
        let widths = horizontalMetrics.map { Int($0.advanceWidth) }.filter { $0 > 0 }
        guard !widths.isEmpty else { return 0 }
        let mean = Double(widths.reduce(0, +)) / Double(widths.count)
        return Int16(clamping: Int((mean + 0.5).rounded(.down)))
    }
}
