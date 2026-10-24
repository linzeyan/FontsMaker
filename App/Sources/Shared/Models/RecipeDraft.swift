import FontsMakerKit
import Foundation

/// What the effect cards and the name fields say, before it becomes a `Recipe`.
struct RecipeDraft: Equatable, Sendable {
    static let maxWeight: Double = 30
    /// What 加粗 starts at when switched on: the reference fonts' Medium
    /// (白鷺楷 is 原俠正楷 plus 12 units).
    static let defaultWeight: Double = 12
    /// 簡體書顯示繁體 as switched on: the most common traditional form, Taiwan
    /// variants, and phrase rules, so 里程碑 stays 里程碑.
    static let defaultS2T = S2TOptions(mode: .single, taiwanVariants: true, phrases: true)
    /// 行高's slider, in em: from set solid to double-spaced and beyond.
    static let lineHeightRange = 1.0...2.5
    /// 字距's slider tops out at a tenth of an em, in font units.
    static func maxTracking(unitsPerEm: Int) -> Int { max(1, unitsPerEm / 10) }
    /// 字距 as switched on: 2% of an em, a light loosening for bold text.
    static func defaultTracking(unitsPerEm: Int) -> Int { max(1, Int((Double(unitsPerEm) * 0.02).rounded())) }

    /// "1.50 em": a line height the way 行高 shows it.
    static func formatEm(_ units: Int, unitsPerEm: Int) -> String {
        String(format: "%.2f em", Double(units) / Double(unitsPerEm))
    }

    /// 0 leaves the embolden step out (a recipe weight must be positive).
    var emboldenWeight: Double = 0
    /// 字寬跟著加寬: advances grow with the bolder letters (`EmboldenStep.widen`).
    var widen = false
    /// 字距, font units after each glyph; 0 leaves the tracking step out.
    var tracking = 0
    /// 行高, font units from ascender to descender; nil leaves the font's own.
    var lineHeight: Int?
    /// Risk review decisions, by character (one Unicode scalar each).
    var skip: Set<String> = []
    var perCharacter: [String: Double] = [:]
    var s2t: S2TOptions? {
        // Phrase rules reproduce OpenCC, which skipAmbiguous deliberately does
        // not follow (the engine refuses the pair), so choosing it turns them off.
        didSet { if s2t?.mode == .skipAmbiguous { s2t?.phrases = false } }
    }
    var pseudoVertical: PseudoVerticalOptions?
    var familyName = ""
    var localizedFamilyName = ""
    var styleName = "Regular"
    /// Which font of a collection, and which instance of a variable font:
    /// the recipe's `source.faceIndex` and `source.variation`. Axes at their
    /// default are left out, so choosing the default instance writes the
    /// same recipe as never choosing one.
    var faceIndex = 0
    var variation: [String: Double] = [:]
    /// Glyphs redrawn in the glyph editor, by character (the recipe's
    /// `outlines` step); only those that differ from the source.
    var outlines: [String: EditedGlyph] = [:]
    /// 英文字母換成另一套字型; nil leaves the replace step out.
    var replacement: Replacement?
    /// Risk review's 從另一套字型取代, by character (one Unicode scalar
    /// each): the library font whose glyph the character shows instead of
    /// its emboldened own. A review decision like `skip`, so it counts only
    /// while 加粗 is on.
    var borrowed: [String: BorrowedFont] = [:]

    /// The second font of 英文字母換成另一套字型 (design §5.7): a library
    /// font, by the same sha256 and file name the recipe pins it with.
    struct Replacement: Codable, Equatable, Sendable {
        var sha256: String
        var fileName: String
        /// The step's `size`: 1 is the target's x-height.
        var size = 1.0
    }

    /// A library font risky glyphs are borrowed from, as the recipe pins it.
    struct BorrowedFont: Codable, Hashable, Sendable {
        var sha256: String
        var fileName: String
    }

    /// Everything Latin a CJK font carries for running English text, accents
    /// included; the full-width forms and curly quotes stay the CJK font's.
    static let replacementSets: [ReplaceCharacterSet] = [.latinLetters, .digits, .asciiPunctuation, .latin1]
    /// 大小's slider: around the x-height match, where Latin beside CJK reads right.
    static let replacementSizeRange = 0.8...1.3

    /// Fixed order: outlines first, as the engine requires (it replaces
    /// source glyphs); replace next, so embolden makes the new letters as
    /// bold as the rest; then embolden, so review decisions name characters
    /// by the cmap it runs on (as in the example recipes); tracking after
    /// it, so the space it adds comes on top of what widen keeps.
    ///
    /// Borrowed glyphs come right after embolden, one replace step per font:
    /// they replace glyphs whose strokes emboldening crowded, so they keep
    /// their own font's weight, as 白鷺楷 took 傳 and 導 from 霞鶩文楷 Medium
    /// as drawn. Emboldened too, they would crowd the same way. Before
    /// tracking, s2t and pseudoVertical, which then treat them like any other
    /// glyph (a simplified character shows its borrowed traditional form).
    var steps: [Recipe.Step] {
        var steps: [Recipe.Step] = []
        if !outlines.isEmpty { steps.append(.outlines(OutlinesStep(glyphs: outlines))) }
        if let replacement {
            steps.append(
                .replace(
                    ReplaceStep(
                        font: Recipe.Source(file: replacement.fileName, sha256: replacement.sha256),
                        sets: RecipeDraft.replacementSets, match: .xHeight, size: replacement.size)))
        }
        if emboldenWeight > 0 {
            steps.append(
                .embolden(
                    EmboldenStep(
                        weight: emboldenWeight,
                        skip: skip.sorted { $0.unicodeScalars.first!.value < $1.unicodeScalars.first!.value },
                        perCharacter: perCharacter.mapValues { EmboldenStep.CharacterOverride(weight: $0) },
                        widen: widen)))
            // In sha256 order, so the recipe does not depend on dictionary order.
            for (font, characters) in Dictionary(grouping: borrowed.keys, by: { borrowed[$0]! })
                .sorted(by: { $0.key.sha256 < $1.key.sha256 })
            {
                // Same em as the CJK glyph it replaces: the font's own size.
                steps.append(
                    .replace(
                        ReplaceStep(
                            font: Recipe.Source(file: font.fileName, sha256: font.sha256), characters: characters)))
            }
        }
        if tracking != 0 { steps.append(.tracking(TrackingOptions(units: tracking))) }
        if let lineHeight { steps.append(.lineHeight(LineHeightOptions(units: lineHeight))) }
        if let s2t { steps.append(.s2t(s2t)) }
        if let pseudoVertical { steps.append(.pseudoVertical(pseudoVertical)) }
        return steps
    }

    /// The recipe as the CLI will read it back: encoded canonically and decoded
    /// strictly, so the recipe hash in name ID 5 (and so the bytes) match a CLI
    /// build of the exported file, and the format's own rules (no surrounding
    /// spaces, ...) apply here too.
    func recipe(source: Recipe.Source) throws -> Recipe {
        let localized = localizedFamilyName.isEmpty ? [:] : ["zh-TW": localizedFamilyName]
        let draft = Recipe(
            source: source,
            output: Recipe.Output(familyName: familyName, localizedFamilyName: localized, styleName: styleName),
            steps: steps)
        return try Recipe(json: draft.canonicalJSON())
    }

    /// The second fonts the steps read, sha256 → file name: what the
    /// preview and the build need loaded.
    var secondFonts: [String: String] {
        var fonts: [String: String] = [:]
        for case .replace(let step) in steps { fonts[step.font.sha256] = step.font.file }
        return fonts
    }

    /// nil when the names can be built; otherwise why not, for inline display.
    /// Runs the engine's own rules (product spec §4.3) against the source font,
    /// and against every second font that gives glyphs too (by sha256), as
    /// the build does.
    func nameProblem(source: Recipe.Source, font: Font, secondFonts: [String: Font] = [:]) -> String? {
        if familyName.isEmpty { return "必須填寫新字型名稱（不可與來源字型同名）。" }
        do {
            let recipe = try recipe(source: source)
            let rename = RenameOptions(
                familyName: recipe.output.familyName, localizedFamilyNames: recipe.output.localizedFamilyName,
                styleName: recipe.output.styleName, provenance: "")
            try font.validateRename(rename)
            for step in recipe.replaceSteps { try secondFonts[step.font.sha256]?.validateRename(rename) }
            return nil
        } catch let error as RenameError {
            return RecipeDraft.describe(error)
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Suggested names

    /// The effect cards, on or off; only these decide the suggested names,
    /// so a slider drag never renames the font.
    var effects: Effects {
        Effects(
            embolden: emboldenWeight > 0, spacing: tracking != 0 || lineHeight != nil,
            pseudoVertical: pseudoVertical != nil, s2t: s2t != nil)
    }

    struct Effects: Equatable, Sendable {
        var embolden = false
        /// 字距 or 行高: reading tuning, like 加粗.
        var spacing = false
        var pseudoVertical = false
        var s2t = false

        /// One word per effect, in the order the cards show them; the
        /// reading-tuning cards share 加粗's.
        var words: [String] {
            (embolden || spacing ? ["Ebook"] : []) + (pseudoVertical ? ["V"] : []) + (s2t ? ["TC"] : [])
        }
    }

    /// Family names to offer for a font whose English family is
    /// `sourceFamily`, best first: its initials and the effect words
    /// ("GuanKiapTsingKhai" with 加粗＋直排 → "GKTK Ebook V"). Never the
    /// source name itself, which the naming rules refuse (product spec §4.3)
    /// and which is often a Reserved Font Name. The fallback drops the
    /// initials, for the rare font whose own name they collide with.
    static func suggestedFamilyNames(sourceFamily: String, effects: Effects) -> [String] {
        let words = effects.words.isEmpty ? ["Custom"] : effects.words
        // A word starts after a space, hyphen or underscore, and at a capital
        // after a small letter: many families are written in camel case
        // (GuanKiapTsingKhai has no spaces in its name table).
        var initials = ""
        var previous: Character = " "
        for character in sourceFamily where character.isASCII {
            let startsWord =
                (" -_".contains(previous) && (character.isLetter || character.isNumber))
                || (character.isUppercase && previous.isLowercase)
            if startsWord { initials += character.uppercased() }
            previous = character
        }
        let fallback = (["FM"] + words).joined(separator: " ")
        return initials.isEmpty ? [fallback] : [([initials] + words).joined(separator: " "), fallback]
    }

    /// The style names by weight class, 100–900: the names the engine turns
    /// back into exactly these classes (`StyleName.weights`).
    private static let weightNames = [
        100: "Thin", 200: "ExtraLight", 300: "Light", 400: "Regular", 500: "Medium", 600: "SemiBold", 700: "Bold",
        800: "ExtraBold", 900: "Black",
    ]

    /// The styles 樣式 offers: upright ones, or for an italic source the
    /// italic ones, so the suggestion is always among them.
    static func styles(italic: Bool) -> [String] {
        weightNames.keys.sorted().map { weightNames[$0]! }.map { name in
            italic ? (name == "Regular" ? "Italic" : name + " Italic") : name
        }
    }

    /// The style the source font as chosen (face, instance) has, one weight
    /// class heavier when emboldened, as the reference fonts name theirs
    /// (原俠正楷 + 12 units is 白鷺楷 Medium). `sourceWeight` is the source's
    /// usWeightClass, which for a variable font's instance is its wght value
    /// (`Font.applyInstanceStyle`): Literata's Bold instance emboldened is
    /// ExtraBold, where the source's own default would say Medium. One class
    /// per 加粗 rather than one per so many units: the weight slider never
    /// renames the font (product spec §4.8). Rounded to the nearest hundred,
    /// as named styles are; Italic stays in the name, and the engine sets
    /// weight class and style bits from the name (§5.5).
    static func suggestedStyle(effects: Effects, sourceWeight: Int, italic: Bool) -> String {
        let rounded = Int((Double(sourceWeight) / 100).rounded()) * 100
        let weight = min(900, max(100, rounded + (effects.embolden ? 100 : 0)))
        return styles(italic: italic)[weight / 100 - 1]
    }

    /// fsSelection ITALIC or macStyle italic: either is how a font says it is the italic of its family.
    static func isItalic(_ font: Font) -> Bool {
        (font.os2?.fsSelection ?? 0) & 1 != 0 || font.macStyle & 2 != 0
    }

    private static func describe(_ error: RenameError) -> String {
        switch error {
        case .containsSourceFamilyName(_, let value, let sourceName):
            return "「\(value)」包含來源字型名稱「\(sourceName)」。衍生字型要用自己的名稱，避免與原字型衝突（OFL 第 3 條）。"
        case .containsReservedFontName(_, let value, let reservedName):
            return "「\(value)」包含來源宣告的保留字型名稱（RFN）「\(reservedName)」。"
        case .invalidPostScriptCharacters(_, let value, let characters):
            return "英文名稱「\(value)」含有不能用在 PostScript 名稱的字元（\(characters)）。中文名稱請填在「中文名稱」。"
        case .postScriptNameTooLong(let name):
            return "PostScript 名稱「\(name)」超過 63 個字元，請縮短名稱。"
        default:
            return error.localizedDescription
        }
    }
}

/// The editor keeps each font's draft as `Drafts/<sha256>.json` beside the
/// library. Every control is stored as it stands, not as the recipe it makes:
/// a recipe drops the review decisions while the weight is 0 and cannot hold
/// an empty name. The s2t and pseudoVertical options are coded as the recipe
/// steps they become, so a saved draft passes the engine's own checks (no
/// phrases with skipAmbiguous) or is not restored at all.
extension RecipeDraft: Codable {
    private enum CodingKeys: String, CodingKey {
        case emboldenWeight, widen, tracking, lineHeight, skip, perCharacter, s2t, pseudoVertical, familyName
        case localizedFamilyName, styleName, faceIndex, variation, replacement, outlines, borrowed
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        emboldenWeight = try container.decode(Double.self, forKey: .emboldenWeight)
        // Absent from drafts saved before these controls existed, which mean "off".
        widen = try container.decodeIfPresent(Bool.self, forKey: .widen) ?? false
        tracking = try container.decodeIfPresent(Int.self, forKey: .tracking) ?? 0
        lineHeight = try container.decodeIfPresent(Int.self, forKey: .lineHeight)
        skip = try container.decode(Set<String>.self, forKey: .skip)
        perCharacter = try container.decode([String: Double].self, forKey: .perCharacter)
        switch try container.decodeIfPresent(Recipe.Step.self, forKey: .s2t) {
        case .s2t(let options)?: s2t = options
        case nil: s2t = nil
        case _?:
            throw DecodingError.dataCorruptedError(forKey: .s2t, in: container, debugDescription: "not an s2t step")
        }
        switch try container.decodeIfPresent(Recipe.Step.self, forKey: .pseudoVertical) {
        case .pseudoVertical(let options)?: pseudoVertical = options
        case nil: pseudoVertical = nil
        case _?:
            throw DecodingError.dataCorruptedError(
                forKey: .pseudoVertical, in: container, debugDescription: "not a pseudoVertical step")
        }
        familyName = try container.decode(String.self, forKey: .familyName)
        localizedFamilyName = try container.decode(String.self, forKey: .localizedFamilyName)
        styleName = try container.decode(String.self, forKey: .styleName)
        // Optional as in the recipe: most fonts have one face and no axes.
        faceIndex = try container.decodeIfPresent(Int.self, forKey: .faceIndex) ?? 0
        variation = try container.decodeIfPresent([String: Double].self, forKey: .variation) ?? [:]
        replacement = try container.decodeIfPresent(Replacement.self, forKey: .replacement)
        borrowed = try container.decodeIfPresent([String: BorrowedFont].self, forKey: .borrowed) ?? [:]
        // Coded as the step it becomes, like s2t: the engine's checks apply.
        switch try container.decodeIfPresent(Recipe.Step.self, forKey: .outlines) {
        case .outlines(let step)?: outlines = step.glyphs
        case nil: outlines = [:]
        case _?:
            throw DecodingError.dataCorruptedError(
                forKey: .outlines, in: container, debugDescription: "not an outlines step")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(emboldenWeight, forKey: .emboldenWeight)
        try container.encode(widen, forKey: .widen)
        try container.encode(tracking, forKey: .tracking)
        try container.encodeIfPresent(lineHeight, forKey: .lineHeight)
        try container.encode(skip.sorted(), forKey: .skip)
        try container.encode(perCharacter, forKey: .perCharacter)
        try container.encodeIfPresent(s2t.map(Recipe.Step.s2t), forKey: .s2t)
        try container.encodeIfPresent(pseudoVertical.map(Recipe.Step.pseudoVertical), forKey: .pseudoVertical)
        try container.encode(familyName, forKey: .familyName)
        try container.encode(localizedFamilyName, forKey: .localizedFamilyName)
        try container.encode(styleName, forKey: .styleName)
        if faceIndex != 0 { try container.encode(faceIndex, forKey: .faceIndex) }
        if !variation.isEmpty { try container.encode(variation, forKey: .variation) }
        try container.encodeIfPresent(replacement, forKey: .replacement)
        if !borrowed.isEmpty { try container.encode(borrowed, forKey: .borrowed) }
        if !outlines.isEmpty {
            try container.encode(Recipe.Step.outlines(OutlinesStep(glyphs: outlines)), forKey: .outlines)
        }
    }
}
