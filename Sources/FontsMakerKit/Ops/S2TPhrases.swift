import Foundation

// Phrase-level simplified → traditional conversion (technical design §5.4,
// 詞彙規則): the cmap keeps the character-level conversion; GSUB rules derived
// from OpenCC's phrase dictionaries make a shaper show OpenCC's result where a
// phrase converts differently (里程碑 stays 里程碑 instead of 裡程碑).

/// A dictionary phrase and what OpenCC converts it to, as code points.
struct PhraseConversion: Equatable, Hashable, Sendable {
    var phrase: [UInt32]
    var converted: [UInt32]
}

/// One OpenCC text dictionary, first value per key (DictEntry::GetDefault).
struct OpenCCDictionary: Sendable {
    var entries: [[UInt32]: [UInt32]] = [:]
    var maxKeyLength = 0

    /// `key<TAB>value value ...` per line; `#` starts a comment line.
    init(resource: String) throws {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "txt", subdirectory: "OpenCC") else {
            throw ResourceError.missing("OpenCC/\(resource).txt")
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[0].isEmpty, let first = fields[1].split(separator: " ").first else {
                throw ResourceError.malformed("OpenCC/\(resource).txt line \(number + 1)")
            }
            let key = fields[0].unicodeScalars.map(\.value)
            entries[key] = first.unicodeScalars.map(\.value)
            maxKeyLength = max(maxKeyLength, key.count)
        }
    }

    /// Dict::MatchPrefix: the longest key starting at `start`.
    func longestMatch(in text: [UInt32], at start: Int) -> (length: Int, value: [UInt32])? {
        var length = min(maxKeyLength, text.count - start)
        while length > 0 {
            if let value = entries[Array(text[start..<start + length])] { return (length, value) }
            length -= 1
        }
        return nil
    }

    /// OpenCC's forward maximum matching over a group with match policy
    /// short_circuit (Conversion.cpp, DictGroup.cpp): at each position the
    /// first dictionary with any match supplies its longest match.
    static func convert(_ text: [UInt32], with group: [OpenCCDictionary]) -> [UInt32] {
        var result: [UInt32] = []
        var index = 0
        next: while index < text.count {
            for dictionary in group {
                if let match = dictionary.longestMatch(in: text, at: index) {
                    result += match.value
                    index += match.length
                    continue next
                }
            }
            result.append(text[index])
            index += 1
        }
        return result
    }
}

/// OpenCC's phrases with the result of its s2t or s2tw config for each.
struct OpenCCPhrases: Sendable {
    /// Every phrase of the segmentation dictionary, sorted by phrase.
    let conversions: [PhraseConversion]
    /// Every character some conversion produces, ascending.
    let convertedCharacters: [UInt32]

    /// Built once per process and config. Loading fails loudly, never silently empty.
    static func bundled(taiwanVariants: Bool) throws -> OpenCCPhrases {
        try (taiwanVariants ? s2tw : s2t).get()
    }

    private static let s2t = Result<OpenCCPhrases, any Error> { try OpenCCPhrases(taiwanVariants: false) }
    private static let s2tw = Result<OpenCCPhrases, any Error> { try OpenCCPhrases(taiwanVariants: true) }

    /// s2t.json and s2tw.json at the pinned commit: the phrase group is the
    /// union of STPhrases and the generated regional phrases, where a key in
    /// both takes STPhrases' value (match policy union, first dictionary wins
    /// ties). OpenCC consumes a matched phrase whole, so its result for the
    /// phrase is the phrase's own value, then (s2tw) TWVariantsPhrases and
    /// TWVariants by forward maximum matching over that value.
    private init(taiwanVariants: Bool) throws {
        var phrases = try OpenCCDictionary(resource: "STPhrases_GeneratedFromRegionalPhrases").entries
        phrases.merge(try OpenCCDictionary(resource: "STPhrases").entries) { _, stPhrases in stPhrases }
        let taiwan =
            taiwanVariants
            ? [try OpenCCDictionary(resource: "TWVariantsPhrases"), try OpenCCDictionary(resource: "TWVariants")] : []
        var characters = Set<UInt32>()
        var conversions: [PhraseConversion] = []
        conversions.reserveCapacity(phrases.count)
        for (phrase, value) in phrases {
            let converted = taiwan.isEmpty ? value : OpenCCDictionary.convert(value, with: taiwan)
            characters.formUnion(converted)
            conversions.append(PhraseConversion(phrase: phrase, converted: converted))
        }
        self.conversions = conversions.sorted { $0.phrase.lexicographicallyPrecedes($1.phrase) }
        convertedCharacters = characters.sorted()
    }
}

/// What s2t with `phrases` leaves for `buildPhraseLookups()`. The rules are
/// glyph IDs, and steps after s2t may still move glyphs (pseudoVertical turns
/// and clones them), so they are derived only once every step has run.
struct PhrasePlan: Equatable, Sendable {
    var taiwanVariants: Bool
    /// The glyph showing each character a phrase converts to, as the font
    /// showed it before s2t remapped the cmap. That glyph may be one no code
    /// point reaches any more (后's own glyph once 后 shows 後, wanted in
    /// 皇后), so steps that move or clone glyphs update these like the cmap.
    var targetGlyphs: [UInt32: UInt16]

    init(taiwanVariants: Bool, glyphsBeforeConversion: [UInt32: UInt16]) throws {
        self.taiwanVariants = taiwanVariants
        var targetGlyphs: [UInt32: UInt16] = [:]
        for character in try OpenCCPhrases.bundled(taiwanVariants: taiwanVariants).convertedCharacters {
            targetGlyphs[character] = glyphsBeforeConversion[character]
        }
        self.targetGlyphs = targetGlyphs
    }
}

public struct PhraseReport: Equatable, Sendable {
    /// Phrases in OpenCC's dictionaries (STPhrases and the generated regional phrases).
    public var phrases: Int
    /// Phrases the character-level conversion already shows as OpenCC
    /// converts them, and no rule changes.
    public var unchanged: Int
    /// Substitution rules: one per glyph sequence of the phrases that convert
    /// differently from character by character.
    public var activeRules: Int
    /// Such phrases folded into another's rule: same glyphs, same result.
    public var mergedPhrases: Int
    /// Rules that substitute nothing but make the shaper split text into
    /// phrases as OpenCC does (心里 must win over 里长 in 心里长了草).
    public var blockingRules: Int
    /// Unchanged phrases with the glyphs of an active rule's phrase: the font
    /// cannot tell them apart, and the rule applies to both.
    public var shadowed: [Shadowed]
    /// Phrases the font cannot express, by phrase.
    public var dropped: [DroppedPhrase]
    /// GSUB table size; 0 before when the source font had none.
    public var gsubBytesBefore: Int
    public var gsubBytesAfter: Int
    public var contextSubtables: Int
    public var singleSubstitutionLookups: Int

    public struct Shadowed: Equatable, Sendable {
        public var phrase: String
        public var converted: String
        /// The active rule's phrase that looks the same.
        public var rulePhrase: String
    }
}

public struct DroppedPhrase: Equatable, Sendable {
    public var phrase: String
    public var converted: String
    public var reason: Reason

    public enum Reason: Equatable, Sendable {
        /// A character of the phrase has no glyph, so no text can match it.
        case characterNotInFont(UInt32)
        /// The font cannot show OpenCC's result: one of its characters has no glyph.
        case convertedCharacterNotInFont(UInt32)
        /// OpenCC's result has a different length; a substitution is one glyph for one.
        case lengthChanged
    }
}

/// GSUB phrase rules in one glyph space (technical design §5.4).
struct PhraseRules: Sendable {
    struct Substitution: Equatable, Hashable, Sendable {
        var position: Int
        var glyph: UInt16
    }

    struct Rule: Equatable, Sendable {
        /// What the cmap gives the phrase's characters.
        var input: [UInt16]
        /// Ascending positions; empty for a blocking rule.
        var substitutions: [Substitution]
        /// The first phrase (in dictionary order) with this glyph sequence.
        var conversion: PhraseConversion
    }

    var active: [Rule] = []
    var blocking: [Rule] = []
    var unchanged = 0
    var mergedPhrases = 0
    var shadowed: [PhraseReport.Shadowed] = []
    var dropped: [DroppedPhrase] = []

    /// - Parameters:
    ///   - cmap: the cmap as the font will ship it: a phrase's glyphs are what its characters map to.
    ///   - targetGlyphs: `PhrasePlan.targetGlyphs` as the font will ship them.
    /// - Throws: `S2TError.conflictingPhrases` when phrases with one glyph
    ///   sequence need different substitutions (design §5.4).
    init(_ conversions: [PhraseConversion], cmap: [UInt32: UInt16], targetGlyphs: [UInt32: UInt16]) throws {
        var activeIndex: [[UInt16]: Int] = [:]
        var conflicts: [String] = []
        // Phrases that substitute nothing: unchanged ones, and dropped ones
        // OpenCC still consumes whole in text, so they may block other rules.
        var passive: [(rule: Rule, unchanged: Bool)] = []
        // Classified in dictionary order, so "first phrase" is well defined.
        phrases: for conversion in conversions {
            func drop(_ reason: DroppedPhrase.Reason) {
                dropped.append(
                    DroppedPhrase(
                        phrase: text(conversion.phrase), converted: text(conversion.converted), reason: reason))
            }
            guard conversion.phrase.count == conversion.converted.count else {
                drop(.lengthChanged)
                continue
            }
            var input: [UInt16] = []
            for character in conversion.phrase {
                guard let glyph = cmap[character] else {
                    drop(.characterNotInFont(character))
                    continue phrases
                }
                input.append(glyph)
            }
            var substitutions: [Substitution] = []
            for (position, character) in conversion.converted.enumerated() {
                guard let glyph = targetGlyphs[character] else {
                    drop(.convertedCharacterNotInFont(character))
                    passive.append((Rule(input: input, substitutions: [], conversion: conversion), false))
                    continue phrases
                }
                if glyph != input[position] { substitutions.append(Substitution(position: position, glyph: glyph)) }
            }
            if substitutions.isEmpty {
                unchanged += 1
                passive.append((Rule(input: input, substitutions: [], conversion: conversion), true))
            } else if let index = activeIndex[input] {
                if active[index].substitutions == substitutions {
                    mergedPhrases += 1
                } else {
                    let kept = active[index].conversion
                    conflicts.append(
                        "\(text(kept.phrase)) → \(text(kept.converted)) and "
                            + "\(text(conversion.phrase)) → \(text(conversion.converted))")
                }
            } else {
                activeIndex[input] = active.count
                active.append(Rule(input: input, substitutions: substitutions, conversion: conversion))
            }
        }
        if !conflicts.isEmpty { throw S2TError.conflictingPhrases(conflicts) }

        var candidates: [Rule] = []
        var seen = Set<[UInt16]>()
        for (rule, isUnchanged) in passive {
            if let index = activeIndex[rule.input] {
                // The spike's 幺么小丑: 么 and 麼 share a glyph after s2t, so
                // it reads as 幺麼小丑, whose rule then applies to it too.
                if isUnchanged {
                    unchanged -= 1
                    shadowed.append(
                        PhraseReport.Shadowed(
                            phrase: text(rule.conversion.phrase), converted: text(rule.conversion.converted),
                            rulePhrase: text(active[index].conversion.phrase)))
                }
                continue
            }
            if seen.insert(rule.input).inserted { candidates.append(rule) }
        }
        blocking = PhraseRules.blockingClosure(active: active.map(\.input), candidates: candidates)
    }

    /// The unchanged phrases that must become identity rules so the shaper
    /// splits text into phrases as OpenCC does (design §5.4 step 3).
    ///
    /// OpenCC matches the longest phrase at each position, left to right, and
    /// consumes it. A phrase U that needs no substitution still matters when
    /// consuming it stops a rule X from applying: X a shorter prefix of U, or
    /// X starting inside U (within it, or running past its end). Without U as
    /// a rule the shaper would apply X there; with it, U consumes the span
    /// first, as in OpenCC. Each blocker can pre-empt further rules the same
    /// way, so this repeats until nothing is added.
    static func blockingClosure(active: [[UInt16]], candidates: [Rule]) -> [Rule] {
        var rules = Set(active)
        var prefixes = Set<[UInt16]>()
        func addPrefixes(_ input: [UInt16]) {
            for length in 1...input.count { prefixes.insert(Array(input[..<length])) }
        }
        active.forEach(addPrefixes)
        var remaining = candidates
        var chosen: [Rule] = []
        while true {
            var added: [Rule] = []
            var rest: [Rule] = []
            for candidate in remaining {
                if preempts(candidate.input, rules: rules, prefixes: prefixes) {
                    added.append(candidate)
                } else {
                    rest.append(candidate)
                }
            }
            if added.isEmpty { return chosen }
            for rule in added {
                rules.insert(rule.input)
                addPrefixes(rule.input)
            }
            chosen += added
            remaining = rest
        }
    }

    private static func preempts(_ input: [UInt16], rules: Set<[UInt16]>, prefixes: Set<[UInt16]>) -> Bool {
        let count = input.count
        if count > 2 {
            for length in 2..<count where rules.contains(Array(input[..<length])) { return true }
        }
        for start in 1..<max(count, 1) {
            if prefixes.contains(Array(input[start...])) { return true }
            if count - start > 2 {
                for length in 2..<(count - start) where rules.contains(Array(input[start..<start + length])) {
                    return true
                }
            }
        }
        return false
    }

    /// Every rule in the order the context lookup must try them: by first
    /// glyph, then longer phrases first, as OpenCC prefers the longest match.
    var ordered: [Rule] {
        (active + blocking).sorted { lhs, rhs in
            if lhs.input[0] != rhs.input[0] { return lhs.input[0] < rhs.input[0] }
            if lhs.input.count != rhs.input.count { return lhs.input.count > rhs.input.count }
            return lhs.conversion.phrase.lexicographicallyPrecedes(rhs.conversion.phrase)
        }
    }

    /// The font's GSUB with the phrase lookups added (design §4.3, §5.4): one
    /// contextual lookup that matches whole phrases, and the single
    /// substitutions it calls, all behind extension lookups, under `rlig` in
    /// every language system: the one registration the spike found HarfBuzz
    /// and CoreText apply by default, horizontally and vertically.
    func gsub(addingTo table: [UInt8]?) throws -> (table: [UInt8], contextSubtables: Int, singleLookups: Int) {
        var layout = try table.map { try GSUBLayout(parsing: $0) } ?? GSUBLayout.withoutGSUB
        let contextLookup = layout.lookups.count
        // A single substitution lookup maps each glyph once, but one glyph can
        // need different outputs in different phrases (發 → 髮 in 头发, 發
        // elsewhere): the k-th output of a glyph goes into lookup k.
        var outputs: [UInt16: Set<UInt16>] = [:]
        let rules = ordered
        for rule in rules {
            for substitution in rule.substitutions {
                outputs[rule.input[substitution.position], default: []].insert(substitution.glyph)
            }
        }
        var maps: [[UInt16: UInt16]] = []
        var slot: [UInt32: Int] = [:]
        for (glyph, targets) in outputs.sorted(by: { $0.key < $1.key }) {
            for (index, target) in targets.sorted().enumerated() {
                if maps.count == index { maps.append([:]) }
                maps[index][glyph] = target
                slot[UInt32(glyph) << 16 | UInt32(target)] = index
            }
        }
        guard contextLookup + 1 + maps.count <= Int(UInt16.max) else {
            throw FontWriteError.unencodable("GSUB: \(contextLookup) lookups leave no room for the phrase lookups")
        }
        let contextRules = rules.map { rule in
            GSUBLayout.ContextRule(
                input: rule.input,
                records: rule.substitutions.map { substitution in
                    let from = rule.input[substitution.position]
                    let index = slot[UInt32(from) << 16 | UInt32(substitution.glyph)]!
                    return (UInt16(substitution.position), UInt16(contextLookup + 1 + index))
                })
        }
        let contextSubtables = try GSUBLayout.contextSubtables(contextRules)
        let lookups =
            [GSUBLayout.NewLookup(type: 5, subtables: contextSubtables)]
            + maps.map { GSUBLayout.NewLookup(type: 1, subtables: GSUBLayout.singleSubstitutionSubtables($0)) }
        layout.register(feature: "rlig", lookups: [UInt16(contextLookup)])
        return (try layout.encoded(adding: lookups), contextSubtables.count, maps.count)
    }
}

extension Font {
    /// The GSUB half of s2t `phrases`: derives the phrase rules from the font
    /// as it will ship (cmap and `phrasePlan` after every step) and adds them
    /// to GSUB. `RecipeBuilder` calls it after the last step; writing a font
    /// whose plan was never built is an error.
    mutating func buildPhraseLookups() throws -> PhraseReport {
        guard let plan = phrasePlan else { preconditionFailure("buildPhraseLookups() needs s2t with phrases first") }
        let phrases = try OpenCCPhrases.bundled(taiwanVariants: plan.taiwanVariants)
        let rules = try PhraseRules(phrases.conversions, cmap: characterMap.mappings, targetGlyphs: plan.targetGlyphs)
        let before = tables["GSUB"]
        var report = PhraseReport(
            phrases: phrases.conversions.count, unchanged: rules.unchanged, activeRules: rules.active.count,
            mergedPhrases: rules.mergedPhrases, blockingRules: rules.blocking.count, shadowed: rules.shadowed,
            dropped: rules.dropped, gsubBytesBefore: before?.count ?? 0, gsubBytesAfter: before?.count ?? 0,
            contextSubtables: 0, singleSubstitutionLookups: 0)
        // No rule applies to this font: its GSUB stays as it was.
        if !rules.active.isEmpty {
            let gsub = try rules.gsub(addingTo: before)
            tables["GSUB"] = gsub.table
            report.gsubBytesAfter = gsub.table.count
            report.contextSubtables = gsub.contextSubtables
            report.singleSubstitutionLookups = gsub.singleLookups
        }
        phrasePlan = nil
        return report
    }
}

/// Converts text the way a font built with an s2t step shows it, for a
/// preview that draws the source font's glyphs instead of shaping the built
/// font (design §5.4, last bullet; §9): each character becomes the character
/// whose source glyph the built font shows at that position, the phrase
/// rules applied as a shaper applies them. Characters the font lacks stay.
///
/// Derivation reads the whole phrase dictionary (about a second for a CJK
/// font), so keep one converter per font and options. The rules come from the
/// font as s2t sees it; steps after s2t can only turn or embolden the glyphs,
/// which changes no character.
public struct S2TTextConverter: Sendable {
    private let shown: [UInt32: UInt32]
    private let glyphs: [UInt32: UInt16]
    private let rules: [UInt16: [PhraseRules.Rule]]

    /// - Parameter font: the font the s2t step starts from (the recipe's source).
    public init(font: Font, options: S2TOptions) throws {
        shown = try font.characterConversion(options).shown
        var converted = font
        _ = try converted.convertSimplifiedToTraditional(options)
        glyphs = converted.characterMap.mappings
        guard let plan = converted.phrasePlan else {
            rules = [:]
            return
        }
        let phrases = try OpenCCPhrases.bundled(taiwanVariants: plan.taiwanVariants)
        let derived = try PhraseRules(phrases.conversions, cmap: glyphs, targetGlyphs: plan.targetGlyphs)
        rules = Dictionary(grouping: derived.ordered) { $0.input[0] }
    }

    public func convert(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        let glyphIDs = scalars.map { glyphs[$0.value] }
        var result = String.UnicodeScalarView()
        func appendShown(_ scalar: Unicode.Scalar) {
            result.append(shown[scalar.value].flatMap(Unicode.Scalar.init) ?? scalar)
        }
        var index = 0
        while index < scalars.count {
            // Rules for one first glyph are ordered as the lookup tries them; the first match wins.
            let rule = glyphIDs[index].flatMap { rules[$0] }?.first { rule in
                index + rule.input.count <= scalars.count
                    && rule.input.indices.allSatisfy { glyphIDs[index + $0] == rule.input[$0] }
            }
            guard let rule else {
                appendShown(scalars[index])
                index += 1
                continue
            }
            var substituted = Set(rule.substitutions.map(\.position))
            for offset in rule.input.indices {
                if substituted.remove(offset) != nil, let scalar = Unicode.Scalar(rule.conversion.converted[offset]) {
                    result.append(scalar)
                } else {
                    appendShown(scalars[index + offset])
                }
            }
            index += rule.input.count
        }
        return String(result)
    }
}

private func text(_ codePoints: [UInt32]) -> String {
    String(String.UnicodeScalarView(codePoints.compactMap(Unicode.Scalar.init)))
}
