import Foundation

/// Character-level simplified → traditional conversion (technical design §5.4).
public struct S2TOptions: Hashable, Sendable {
    public var mode: S2TMode
    /// Afterwards apply OpenCC's Taiwan variants (爲 → 為, 裏 → 裡, ...), like OpenCC `s2tw`.
    public var taiwanVariants: Bool
    /// Also add GSUB rules that show OpenCC's phrase-level result where it
    /// differs from the character-level one (里程碑 stays 里程碑, not 裡程碑).
    /// Requires `mode: .single`: the rules reproduce OpenCC, which
    /// `skipAmbiguous` deliberately does not.
    public var phrases: Bool

    public init(mode: S2TMode = .single, taiwanVariants: Bool = false, phrases: Bool = false) {
        self.mode = mode
        self.taiwanVariants = taiwanVariants
        self.phrases = phrases
    }
}

public enum S2TMode: String, CaseIterable, Sendable {
    /// One-to-many characters take OpenCC's first (most common) candidate
    /// the font has a glyph for.
    case single
    /// One-to-many characters stay simplified.
    case skipAmbiguous
}

public struct S2TReport: Equatable, Sendable {
    /// Code points now mapped to their traditional character's glyph.
    public var remapped: Int
    /// Code points whose traditional character already used the same glyph.
    public var alreadyTraditional: Int
    /// Simplified code points the font had no glyph for, now mapped to their
    /// traditional character's glyph (简 in a traditional-only font). Not in
    /// `remapped`; code points it lacks whose traditional character it also
    /// lacks are not reported anywhere: that would list every conversion for a
    /// Latin font.
    public var added: Int = 0
    /// One-to-many simplified characters left alone (`skipAmbiguous`).
    public var skippedAmbiguous: Int
    /// Conversions the font cannot show: the traditional character has no glyph.
    public var missingTraditional: [Conversion]
    /// `single` conversions whose first OpenCC candidate has no glyph, so a
    /// later candidate the font has was used. Also counted in `remapped` or
    /// `alreadyTraditional`.
    public var fallbacks: [Fallback]
    /// The GSUB phrase rules, with `phrases`. Built after every other step
    /// (they are glyph IDs, which later steps may still move), so the build
    /// fills this in at the end; nil without `phrases`.
    public var phrases: PhraseReport? = nil

    public struct Conversion: Equatable, Sendable {
        public var simplified: UInt32
        public var traditional: UInt32
    }

    public struct Fallback: Equatable, Sendable {
        public var simplified: UInt32
        /// OpenCC's first candidate, missing from the font.
        public var preferred: UInt32
        /// The candidate used instead.
        public var used: UInt32
    }
}

/// OpenCC dictionaries bundled with the engine (Resources/OpenCC, Apache-2.0).
public struct OpenCCTables: Sendable {
    /// Simplified → traditional candidates, most common first.
    public let simplifiedToTraditional: [UInt32: [UInt32]]
    /// Traditional → Taiwan standard form, most common first.
    public let taiwanVariants: [UInt32: [UInt32]]

    /// Parsed once per process. Loading fails loudly, never silently empty.
    public static func bundled() throws -> OpenCCTables {
        try cached.get()
    }

    private static let cached = Result<OpenCCTables, any Error> {
        OpenCCTables(
            simplifiedToTraditional: try parse(resource: "STCharacters"),
            taiwanVariants: try parse(resource: "TWVariants"))
    }

    /// `key<TAB>value value ...` per line; `#` starts a comment line.
    static func parse(resource: String) throws -> [UInt32: [UInt32]] {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "txt", subdirectory: "OpenCC") else {
            throw ResourceError.missing("OpenCC/\(resource).txt")
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        var table: [UInt32: [UInt32]] = [:]
        for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: "\t")
            guard fields.count == 2, let key = singleScalar(String(fields[0])) else {
                throw ResourceError.malformed("OpenCC/\(resource).txt line \(number + 1)")
            }
            var values: [UInt32] = []
            for value in fields[1].split(separator: " ") {
                guard let scalar = singleScalar(String(value)) else {
                    throw ResourceError.malformed("OpenCC/\(resource).txt line \(number + 1)")
                }
                values.append(scalar.value)
            }
            guard !values.isEmpty else { throw ResourceError.malformed("OpenCC/\(resource).txt line \(number + 1)") }
            table[key.value] = values
        }
        return table
    }
}

public enum ResourceError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    case missing(String)
    case malformed(String)

    public var description: String {
        switch self {
        case .missing(let name): return "Bundled data file \(name) is missing from FontsMakerKit's resources."
        case .malformed(let location): return "Bundled data file is malformed at \(location)."
        }
    }

    public var errorDescription: String? { description }
}

public enum S2TError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    case phrasesNeedSingleMode
    /// Phrases that look the same in this font (one glyph sequence) but that
    /// OpenCC converts differently: one GSUB rule cannot show both.
    case conflictingPhrases([String])

    public var description: String {
        switch self {
        case .phrasesNeedSingleMode:
            return "s2t phrases need mode 'single': the phrase rules reproduce OpenCC's conversion, "
                + "which 'skipAmbiguous' deliberately does not follow."
        case .conflictingPhrases(let conflicts):
            return "Phrases that share their glyphs in this font convert differently, so no phrase rule can "
                + "show both; build without 'phrases': " + conflicts.joined(separator: "; ")
        }
    }

    public var errorDescription: String? { description }
}

extension Font {
    /// Points each simplified code point at its traditional character's glyph.
    /// Only the cmap changes; outlines are untouched, so the result does not
    /// depend on where the step sits relative to outline operations.
    ///
    /// Every lookup reads the cmap as it was before the step, so conversions
    /// never chain (后 → 後 must not then follow whatever 後 maps to).
    /// With `taiwanVariants`, every code point goes through the Taiwan table
    /// after the simplified table, which is what OpenCC `s2tw` does to text.
    ///
    /// With `phrases`, the step also records which glyph shows each character
    /// a phrase can convert to (`phrasePlan`): the rules themselves are built
    /// by `buildPhraseLookups()` once every step has run.
    public mutating func convertSimplifiedToTraditional(_ options: S2TOptions) throws -> S2TReport {
        let before = characterMap.mappings
        let (shown, report) = try characterConversion(options)
        // Code points the font lacked are added here, so phrase rules (built
        // from this cmap) match simplified text in a traditional-only font too.
        for (codePoint, character) in shown where character != codePoint {
            characterMap.mappings[codePoint] = before[character]
        }
        if options.phrases {
            phrasePlan = try PhrasePlan(taiwanVariants: options.taiwanVariants, glyphsBeforeConversion: before)
        }
        return report
    }

    /// The character-level conversion, not yet applied: for every code point
    /// the font maps or the conversion can show, the character whose glyph it
    /// shows afterwards (itself if none).
    ///
    /// Code points the font lacks are converted too when it has the traditional
    /// glyph: simplified text is what the step is for, and a traditional-only
    /// font (Iansui has 簡 but not 简) would otherwise show it as missing.
    func characterConversion(_ options: S2TOptions) throws -> (shown: [UInt32: UInt32], report: S2TReport) {
        if options.phrases && options.mode != .single { throw S2TError.phrasesNeedSingleMode }
        let tables = try OpenCCTables.bundled()
        let before = characterMap.mappings
        var shown: [UInt32: UInt32] = [:]
        var report = S2TReport(
            remapped: 0, alreadyTraditional: 0, skippedAmbiguous: 0, missingTraditional: [], fallbacks: [])
        var domain = Set(before.keys).union(tables.simplifiedToTraditional.keys)
        if options.taiwanVariants { domain.formUnion(tables.taiwanVariants.keys) }
        for codePoint in domain.sorted() {
            let glyph = before[codePoint]
            if glyph != nil { shown[codePoint] = codePoint }
            var target = codePoint
            if let candidates = tables.simplifiedToTraditional[codePoint] {
                if options.mode == .skipAmbiguous && candidates.count > 1 {
                    if glyph != nil { report.skippedAmbiguous += 1 }
                } else {
                    // Design §5.4: a less common traditional form beats leaving
                    // the simplified glyph (裥 → 襉 is missing from
                    // GuanKiapTsingKhai, 襇 is not, and -T shows 襇).
                    target = candidates.first { before[$0] != nil } ?? candidates[0]
                    if target != candidates[0] && glyph != nil {
                        report.fallbacks.append(
                            S2TReport.Fallback(simplified: codePoint, preferred: candidates[0], used: target))
                    }
                }
            }
            if options.taiwanVariants, let variant = tables.taiwanVariants[target]?.first {
                target = variant
            }
            if target == codePoint { continue }
            guard let traditionalGlyph = before[target] else {
                if glyph != nil {
                    report.missingTraditional.append(S2TReport.Conversion(simplified: codePoint, traditional: target))
                }
                continue
            }
            shown[codePoint] = target
            if glyph == nil {
                report.added += 1
            } else if traditionalGlyph == glyph {
                report.alreadyTraditional += 1
            } else {
                report.remapped += 1
            }
        }
        return (shown, report)
    }
}
