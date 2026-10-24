import Foundation

// Glyphs from a second font (technical design §5.7): the Latin letters of a
// CJK font taken from a Latin text face, or a few CJK characters from another
// CJK font (白鷺楷 took 傳, 導, 育 ... from 霞鶩文楷 instead of emboldening them).

/// Named ranges a replace step can take from the second font.
public enum ReplaceCharacterSet: String, CaseIterable, Sendable {
    /// A–Z, a–z.
    case latinLetters
    /// 0–9.
    case digits
    /// The rest of printable ASCII, the space included.
    case asciiPunctuation
    /// U+00A0–U+00FF: accented letters, «», ×, the no-break space.
    case latin1

    public var codePoints: [UInt32] {
        switch self {
        case .latinLetters: return Array(0x41...0x5A) + Array(0x61...0x7A)
        case .digits: return Array(0x30...0x39)
        case .asciiPunctuation:
            return (0x20...0x7E).filter { !(0x30...0x39).contains($0) && !(0x41...0x5A).contains($0) && !(0x61...0x7A).contains($0) }
        case .latin1: return Array(0xA0...0xFF)
        }
    }
}

/// What the second font's glyphs are scaled to match.
public enum ReplaceMatch: String, CaseIterable, Sendable {
    /// The ratio of the two units per em: the second font's own size.
    case unitsPerEm
    /// The top of its x lands on the top of the target's x.
    case xHeight
    /// The top of its H lands on the top of the target's H.
    case capHeight

    /// The character whose outline top is measured; nil for unitsPerEm.
    var reference: UInt32? {
        switch self {
        case .unitsPerEm: return nil
        case .xHeight: return 0x78
        case .capHeight: return 0x48
        }
    }
}

/// The replace step as written in a recipe (design §6).
public struct ReplaceStep: Equatable, Sendable {
    /// The second font, pinned by sha256 like the recipe's source; its file
    /// sits beside the recipe.
    public var font: Recipe.Source
    /// Sorted in declaration order, unique.
    public var sets: [ReplaceCharacterSet]
    /// Single Unicode scalars, sorted and unique. Unlike the sets, every one
    /// must be in the second font.
    public var characters: [String]
    public var match: ReplaceMatch
    /// Multiplies the matched scale: Latin next to CJK often reads small at
    /// the same x-height, and a little larger looks the same size.
    public var size: Double
    /// Font units of the target font added to every y: moves the second
    /// font's letters up (positive) or down against the CJK.
    public var baselineShift: Int

    public static let sizeRange = 0.25...4.0

    public init(
        font: Recipe.Source, sets: [ReplaceCharacterSet] = [], characters: [String] = [],
        match: ReplaceMatch = .unitsPerEm, size: Double = 1, baselineShift: Int = 0
    ) {
        self.font = font
        self.sets = ReplaceCharacterSet.allCases.filter(sets.contains)
        self.characters = Set(characters).sorted { $0.unicodeScalars.first!.value < $1.unicodeScalars.first!.value }
        self.match = match
        self.size = size
        self.baselineShift = baselineShift
    }

    /// Every code point the step asks for, ascending.
    public var codePoints: [UInt32] {
        var all = Set(sets.flatMap(\.codePoints))
        all.formUnion(characters.compactMap { $0.unicodeScalars.first?.value })
        return all.sorted()
    }
}

public struct ReplaceReport: Equatable, Sendable {
    /// The second font's family name (name ID 16, else 1).
    public var familyName: String
    /// Code points that now show the second font's glyph.
    public var replaced: Int
    /// ... of which the target font had no glyph for.
    public var added: Int
    /// Code points of the sets the second font lacks: they keep the target's glyph.
    public var notInReplacement: [UInt32]
    /// Glyphs appended: one per glyph of the second font, however many code points share it.
    public var glyphs: Int
    /// What every coordinate and advance of the second font was multiplied by.
    public var scale: Double
    /// The top of x in the target before and after the step, when both fonts have one.
    public var xHeight: (before: Int, after: Int)?
    /// The second font's kerning between the copied glyphs (`copyKerning`).
    public var kerning = KerningCopyReport()

    public static func == (lhs: ReplaceReport, rhs: ReplaceReport) -> Bool {
        lhs.familyName == rhs.familyName && lhs.replaced == rhs.replaced && lhs.added == rhs.added
            && lhs.notInReplacement == rhs.notInReplacement && lhs.glyphs == rhs.glyphs && lhs.scale == rhs.scale
            && lhs.xHeight?.before == rhs.xHeight?.before && lhs.xHeight?.after == rhs.xHeight?.after
            && lhs.kerning == rhs.kerning
    }
}

public enum ReplaceError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    /// `match` needs the character's outline in this font ("target" or "replacement").
    case cannotMeasure(font: String, character: String)
    case charactersNotInReplacement([String])

    public var description: String {
        switch self {
        case .cannotMeasure(let font, let character):
            return "replace: the \(font) font has no outline for '\(character)' to match the size by; "
                + "use match 'unitsPerEm' instead"
        case .charactersNotInReplacement(let characters):
            return "replace: the replacement font has no glyph for " + characters.joined(separator: ", ")
        }
    }

    public var errorDescription: String? { description }
}

extension Font {
    /// The top of `character`'s outline, composites resolved; nil without a
    /// glyph or with an empty one.
    func outlineTop(of character: UInt32) -> Double? {
        guard let glyph = characterMap.mappings[character] else { return nil }
        return (try? flattenedOutline(of: Int(glyph)))?.ys.max()
    }

    /// The scale `step` gives the second font's coordinates.
    func replaceScale(_ step: ReplaceStep, from donor: Font) throws -> Double {
        guard let reference = step.match.reference else {
            return Double(unitsPerEm) / Double(donor.unitsPerEm) * step.size
        }
        let name = String(Unicode.Scalar(reference)!)
        guard let target = outlineTop(of: reference), target > 0 else {
            throw ReplaceError.cannotMeasure(font: "target", character: name)
        }
        guard let measured = donor.outlineTop(of: reference), measured > 0 else {
            throw ReplaceError.cannotMeasure(font: "replacement", character: name)
        }
        return target / measured * step.size
    }

    /// Points the step's code points at copies of `donor`'s glyphs, scaled
    /// and shifted as the step says (design §5.7).
    ///
    /// The copies are appended rather than written over the target's own
    /// glyphs: those may be shared with code points the step leaves alone,
    /// used by composites, or named in GSUB and GPOS, whose rules and kerning
    /// were made for the target's design and must not reach the new letters.
    /// The second font's kerning between the copied glyphs comes along
    /// (`copyKerning`); its other GSUB and GPOS rules (ligatures, anchors) do not.
    public mutating func replaceGlyphs(_ step: ReplaceStep, from donor: Font) throws -> ReplaceReport {
        let missing = step.characters.filter { donor.characterMap.mappings[$0.unicodeScalars.first!.value] == nil }
        guard missing.isEmpty else { throw ReplaceError.charactersNotInReplacement(missing) }
        let scale = try replaceScale(step, from: donor)
        let xBefore = outlineTop(of: 0x78)
        let source = self

        var report = ReplaceReport(
            familyName: donor.familyName, replaced: 0, added: 0, notInReplacement: [], glyphs: 0, scale: scale)
        var copies: [UInt16: UInt16] = [:]
        for codePoint in step.codePoints {
            guard let donorGlyph = donor.characterMap.mappings[codePoint] else {
                report.notInReplacement.append(codePoint)
                continue
            }
            let previous = source.characterMap.mappings[codePoint]
            if let copy = copies[donorGlyph] {
                characterMap.mappings[codePoint] = copy
            } else {
                var flat = try donor.flattenedOutline(of: Int(donorGlyph))
                flat.xs = flat.xs.map { $0 * scale }
                flat.ys = flat.ys.map { $0 * scale + Double(step.baselineShift) }
                let outline = flat.rounded()
                let donorMetric = donor.horizontalMetrics[Int(donorGlyph)]
                guard let advance = UInt16(exactly: roundHalfUp(Double(donorMetric.advanceWidth) * scale)) else {
                    throw FontWriteError.unencodable(
                        "replace: U+\(hex(codePoint))'s advance scaled by \(scale) does not fit 16 bits")
                }
                let horizontal = HorizontalMetric(
                    advanceWidth: advance,
                    leftSideBearing: Int16(clamping: roundHalfUp(Double(donorMetric.leftSideBearing) * scale)))
                let top = BoundingBox(outline.points)?.yMax
                let copy = try appendGlyph(
                    Glyph(outline: .simple(outline)), horizontal: horizontal,
                    vertical: verticalMetrics == nil ? nil : source.replacedVerticalMetric(previous, newTop: top))
                copies[donorGlyph] = copy
                characterMap.mappings[codePoint] = copy
                report.glyphs += 1
            }
            report.replaced += 1
            if previous == nil { report.added += 1 }
        }
        report.kerning = try copyKerning(from: donor, copies: copies, scale: scale)
        // Design §4.3: an operation that changes advances owns xAvgCharWidth.
        let average = averageAdvanceWidth()
        os2?.xAvgCharWidth = average
        if let before = xBefore, let after = outlineTop(of: 0x78) {
            report.xHeight = (Int(before), Int(after))
        }
        return report
    }

    /// The vmtx entry of a glyph that replaces `previous` (nil: the font had
    /// none for the code point): the same vertical origin, so a vertical
    /// layout puts the new letter where the old one stood.
    private func replacedVerticalMetric(_ previous: UInt16?, newTop: Int32?) -> VerticalMetric {
        if let previous, let metric = verticalMetrics?[Int(previous)] {
            guard let newTop, let oldTop = (try? flattenedOutline(of: Int(previous)))?.ys.max() else { return metric }
            let origin = Int(metric.topSideBearing) + Int(oldTop.rounded())
            return VerticalMetric(
                advanceHeight: metric.advanceHeight, topSideBearing: Int16(clamping: origin - Int(newTop)))
        }
        let (ascender, descender) = emBoxVerticalExtent()
        return VerticalMetric(
            advanceHeight: UInt16(clamping: ascender - descender),
            topSideBearing: Int16(clamping: newTop.map { ascender - $0 } ?? 0))
    }

    /// Name ID 16, else 1, English when there is one: for reports.
    var familyName: String {
        for id: UInt16 in [16, 1] {
            let records = names.filter { $0.nameID == id }
            if let text = (records.first { $0.platformID == 3 && $0.languageID == 0x0409 } ?? records.first)?.string {
                return text
            }
        }
        return "?"
    }

    /// The output carries `donor`'s glyphs, so it carries its copyright and
    /// license notices too (OFL condition 2): name IDs 0 and 13 get the
    /// second font's text appended on a new line, where they do not already
    /// contain it. ID 14 (the license URL) stays the target's: it is one URL.
    mutating func appendNotices(of donor: Font) {
        for nameID: UInt16 in [0, 13] {
            let records = donor.names.filter { $0.nameID == nameID }
            guard
                let notice = (records.first { $0.platformID == 3 && $0.languageID == 0x0409 } ?? records.first)?
                    .string, !notice.isEmpty
            else { continue }
            if !names.contains(where: { $0.nameID == nameID }) {
                names.append(NameRecord(windowsLanguage: 0x0409, nameID: nameID, string: notice))
                continue
            }
            for index in names.indices where names[index].nameID == nameID {
                guard let text = names[index].string, !text.contains(notice) else { continue }
                names[index] = names[index].replacingText(text + "\n" + notice)
            }
        }
    }
}

extension NameRecord {
    /// The record with other text, in its own encoding; unchanged when the
    /// text cannot be encoded there (Mac Roman).
    fileprivate func replacingText(_ text: String) -> NameRecord {
        var result = self
        switch (platformID, encodingID) {
        case (1, 0):
            guard let data = text.data(using: .macOSRoman) else { return self }
            result.bytes = [UInt8](data)
        default:
            result.bytes = NameRecord(windowsLanguage: 0, nameID: 0, string: text).bytes
        }
        return result
    }
}

/// fontTools `otRound`, as `FlatOutline.rounded()` rounds the points.
private func roundHalfUp(_ value: Double) -> Int { Int((value + 0.5).rounded(.down)) }

// MARK: - Recipe coding

extension ReplaceStep: Codable {
    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(["op", "font", "sets", "characters", "match", "size", "baselineShift"])
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        font = try container.decode(Recipe.Source.self, forKey: AnyCodingKey("font"))

        var chosen: Set<ReplaceCharacterSet> = []
        for (index, raw) in (try container.decodeIfPresent([String].self, forKey: AnyCodingKey("sets")) ?? []).enumerated() {
            guard let set = ReplaceCharacterSet(rawValue: raw) else {
                let accepted = ReplaceCharacterSet.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")
                throw RecipeError.invalidValue(
                    path: keyPath(decoder.codingPath + [AnyCodingKey("sets"), AnyCodingKey(intValue: index)!]),
                    reason: "'\(raw)' is not one of \(accepted)")
            }
            chosen.insert(set)
        }
        sets = ReplaceCharacterSet.allCases.filter(chosen.contains)

        var scalars: Set<Unicode.Scalar> = []
        let listed = try container.decodeIfPresent([String].self, forKey: AnyCodingKey("characters")) ?? []
        for (index, text) in listed.enumerated() {
            guard let scalar = singleScalar(text) else {
                throw RecipeError.invalidValue(
                    path: keyPath(decoder.codingPath + [AnyCodingKey("characters"), AnyCodingKey(intValue: index)!]),
                    reason: "'\(text)' must be exactly one character (one Unicode code point)")
            }
            scalars.insert(scalar)
        }
        characters = scalars.sorted { $0.value < $1.value }.map { String($0) }
        guard !sets.isEmpty || !characters.isEmpty else {
            throw decoder.invalid("sets", "name at least one set or character to replace")
        }

        match = try container.decodeChoice(ReplaceMatch.self, "match", default: .unitsPerEm)
        size = try container.decodeIfPresent(Double.self, forKey: AnyCodingKey("size")) ?? 1
        guard size.isFinite, ReplaceStep.sizeRange.contains(size) else {
            throw decoder.invalid(
                "size",
                "must be between \(ReplaceStep.sizeRange.lowerBound) and \(ReplaceStep.sizeRange.upperBound), got \(size)")
        }
        baselineShift = try container.decodeIfPresent(Int.self, forKey: AnyCodingKey("baselineShift")) ?? 0
        guard Int16(exactly: baselineShift) != nil else {
            throw decoder.invalid("baselineShift", "\(baselineShift) font units is out of range")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(font, forKey: AnyCodingKey("font"))
        try container.encode(sets.map(\.rawValue), forKey: AnyCodingKey("sets"))
        try container.encode(characters, forKey: AnyCodingKey("characters"))
        try container.encode(match.rawValue, forKey: AnyCodingKey("match"))
        try container.encode(size, forKey: AnyCodingKey("size"))
        try container.encode(baselineShift, forKey: AnyCodingKey("baselineShift"))
    }
}

extension Recipe {
    /// The replace steps in recipe order, each with its own second font.
    public var replaceSteps: [ReplaceStep] {
        steps.compactMap { if case .replace(let step) = $0 { step } else { nil } }
    }
}

extension [Recipe.Step] {
    /// A recipe may have several replace steps, each with its own second font
    /// (Latin letters from one, a few CJK characters from another), but a
    /// character comes from one of them: a second step asking for it would
    /// silently win over the first, so the recipe is refused instead. Decoding
    /// checks this; so do the build and the preview, for steps put together
    /// in code.
    func checkReplacedOnce() throws {
        var owner: [UInt32: Int] = [:]
        for (index, step) in enumerated() {
            guard case .replace(let replace) = step else { continue }
            let codePoints = replace.codePoints
            let taken = codePoints.filter { owner[$0] != nil }
            if let first = taken.first {
                let shown = taken.prefix(8).map { codePoint in
                    "U+\(hex(codePoint))" + (Unicode.Scalar(codePoint).map { " \($0)" } ?? "")
                }
                throw RecipeError.invalidValue(
                    path: "steps[\(index)]",
                    reason: shown.joined(separator: ", ") + (taken.count > 8 ? " and \(taken.count - 8) more" : "")
                        + " also replaced by steps[\(owner[first]!)]; each character comes from one replace step")
            }
            for codePoint in codePoints { owner[codePoint] = index }
        }
    }
}
