import CryptoKit
import Foundation

extension Recipe {
    /// Decodes a recipe, translating Foundation's decoding errors into
    /// `RecipeError`s that name the offending key path.
    public init(json: Data) throws {
        do {
            self = try JSONDecoder().decode(Recipe.self, from: json)
        } catch let error as DecodingError {
            throw RecipeError(error)
        }
    }

    public init(contentsOf url: URL) throws {
        try self.init(json: try Data(contentsOf: url))
    }

    /// `source.file` resolved against the directory of the recipe file.
    public func sourceURL(recipeURL: URL) -> URL {
        URL(fileURLWithPath: source.file, relativeTo: recipeURL.deletingLastPathComponent()).standardizedFileURL
    }

    /// Sorted keys, no whitespace, defaults filled in: equal recipes encode
    /// to equal bytes however the file was formatted.
    public func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Lowercase hex sha256 of the canonical encoding, written into name ID 5
    /// so an output font can be traced to its recipe (design §5.5).
    /// `source.file` is left out: it only says where the font sits on one
    /// machine, while `source.sha256` already pins which font it is.
    public func identityHash() throws -> String {
        var identity = self
        identity.source.file = ""
        // Likewise every replace step's second font, pinned by its own sha256.
        identity.steps = steps.map { step in
            guard case .replace(var replace) = step else { return step }
            replace.font.file = ""
            return .replace(replace)
        }
        return sha256Hex(try identity.canonicalJSON())
    }
}

func sha256Hex<D: DataProtocol>(_ data: D) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Strict decoding helpers

/// Coding key for whatever keys a JSON object actually has.
struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) {
        stringValue = string
        intValue = nil
    }

    init?(stringValue: String) { self.init(stringValue) }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// `steps[0].perCharacter.鬢.weight`: array positions in brackets, object keys dotted.
func keyPath(_ path: [CodingKey]) -> String {
    var result = ""
    for key in path {
        if let index = key.intValue {
            result += "[\(index)]"
        } else {
            result += (result.isEmpty ? "" : ".") + key.stringValue
        }
    }
    return result.isEmpty ? "(top level)" : result
}

extension Decoder {
    /// Throws for the first (alphabetically) key outside `known`.
    func rejectUnknownKeys(_ known: Set<String>) throws {
        let container = try self.container(keyedBy: AnyCodingKey.self)
        if let unknown = container.allKeys.map(\.stringValue).filter({ !known.contains($0) }).sorted().first {
            throw RecipeError.unknownKey(path: keyPath(codingPath + [AnyCodingKey(unknown)]))
        }
    }

    func invalid(_ key: String? = nil, _ reason: String) -> RecipeError {
        .invalidValue(path: keyPath(codingPath + (key.map { [AnyCodingKey($0)] } ?? [])), reason: reason)
    }
}

extension KeyedDecodingContainer where Key == AnyCodingKey {
    /// Raw-value enums get a message listing the accepted values instead of
    /// Foundation's "cannot initialize from invalid String value".
    func decodeChoice<T: RawRepresentable & CaseIterable>(_ type: T.Type, _ key: String, default value: T) throws -> T
    where T.RawValue == String {
        guard let raw = try decodeIfPresent(String.self, forKey: AnyCodingKey(key)) else { return value }
        guard let choice = T(rawValue: raw) else {
            let accepted = T.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")
            throw RecipeError.invalidValue(
                path: keyPath(codingPath + [AnyCodingKey(key)]), reason: "'\(raw)' is not one of \(accepted)")
        }
        return choice
    }
}

extension RecipeError {
    init(_ error: DecodingError) {
        switch error {
        case .keyNotFound(let key, let context):
            self = .missingKey(path: keyPath(context.codingPath + [key]))
        case .typeMismatch(let type, let context):
            self = .invalidValue(path: keyPath(context.codingPath), reason: "expected \(RecipeError.describe(type))")
        case .valueNotFound(let type, let context):
            self = .invalidValue(
                path: keyPath(context.codingPath), reason: "expected \(RecipeError.describe(type)), found null")
        case .dataCorrupted(let context):
            let underlying = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
            if context.codingPath.isEmpty {
                self = .notJSON(underlying ?? context.debugDescription)
            } else {
                self = .invalidValue(path: keyPath(context.codingPath), reason: context.debugDescription)
            }
        @unknown default:
            self = .notJSON(String(describing: error))
        }
    }

    private static func describe(_ type: Any.Type) -> String {
        switch type {
        case is Int.Type: return "an integer"
        case is Double.Type: return "a number"
        case is String.Type: return "a string"
        case is Bool.Type: return "true or false"
        case is [Any].Type: return "an array"
        case is [String: Any].Type: return "an object"
        default: return String(describing: type)
        }
    }
}

/// A recipe character key: exactly one Unicode scalar, so it maps to exactly one cmap entry.
func singleScalar(_ text: String) -> Unicode.Scalar? {
    text.unicodeScalars.count == 1 ? text.unicodeScalars.first : nil
}

// MARK: - Recipe

extension Recipe: Codable {
    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(["formatVersion", "source", "output", "steps"])
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let version = try container.decode(Int.self, forKey: AnyCodingKey("formatVersion"))
        guard version == Recipe.formatVersion else { throw RecipeError.unsupportedFormatVersion(version) }
        source = try container.decode(Source.self, forKey: AnyCodingKey("source"))
        output = try container.decode(Output.self, forKey: AnyCodingKey("output"))
        steps = try container.decodeIfPresent([Step].self, forKey: AnyCodingKey("steps")) ?? []
        // Running an operation twice is never what a recipe means (a second
        // pseudoVertical would rotate the rotated glyphs back), so refuse it.
        // replace is the exception: each step takes other characters from
        // its own second font (design §5.7), as long as no character is asked
        // of two of them.
        var seen: Set<String> = []
        for (index, step) in steps.enumerated() where !seen.insert(step.op).inserted && step.op != "replace" {
            throw RecipeError.invalidValue(
                path: "steps[\(index)].op",
                reason: "'\(step.op)' appears more than once; each operation runs at most once")
        }
        try steps.checkReplacedOnce()
        // outlines replaces source glyphs before anything else touches them
        // (design §5.8); anywhere else, the recipe would read in an order the
        // build does not follow.
        if let index = steps.firstIndex(where: { $0.op == "outlines" }), index != 0 {
            throw RecipeError.invalidValue(
                path: "steps[\(index)].op",
                reason: "outlines must be the first step: it replaces source glyphs before every other step")
        }
        // pseudoVertical turns glyphs about the em box the typo metrics give,
        // and sets the line (its column pitch) itself; lineHeight rewrites both.
        if seen.contains("lineHeight") && seen.contains("pseudoVertical"),
            let index = steps.lastIndex(where: { $0.op == "lineHeight" || $0.op == "pseudoVertical" })
        {
            throw RecipeError.invalidValue(
                path: "steps[\(index)].op",
                reason: "lineHeight and pseudoVertical cannot be combined: pseudoVertical sets the line height "
                    + "itself, as the column pitch, and turns glyphs about the em box of the typo metrics")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(Recipe.formatVersion, forKey: AnyCodingKey("formatVersion"))
        try container.encode(source, forKey: AnyCodingKey("source"))
        try container.encode(output, forKey: AnyCodingKey("output"))
        try container.encode(steps, forKey: AnyCodingKey("steps"))
    }
}

extension Recipe.Source: Codable {
    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(["file", "sha256", "faceIndex", "variation"])
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        file = try container.decode(String.self, forKey: AnyCodingKey("file"))
        guard !file.isEmpty else { throw decoder.invalid("file", "the source font path is empty") }
        let hash = try container.decode(String.self, forKey: AnyCodingKey("sha256")).lowercased()
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else {
            throw decoder.invalid("sha256", "expected 64 hexadecimal digits (shasum -a 256 <font>)")
        }
        sha256 = hash
        faceIndex = try container.decodeIfPresent(Int.self, forKey: AnyCodingKey("faceIndex")) ?? 0
        guard faceIndex >= 0 else { throw decoder.invalid("faceIndex", "must be 0 or more, got \(faceIndex)") }
        variation = try container.decodeIfPresent([String: Double].self, forKey: AnyCodingKey("variation")) ?? [:]
        // Whether an axis exists, and its range, depend on the font: checked
        // when the font is loaded. Here only what no font could accept.
        for (tag, value) in variation.sorted(by: { $0.key < $1.key }) {
            let path = keyPath(decoder.codingPath + [AnyCodingKey("variation"), AnyCodingKey(tag)])
            guard tag.unicodeScalars.count == 4, tag.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) })
            else {
                throw RecipeError.invalidValue(
                    path: path, reason: "'\(tag)' is not an axis tag (4 ASCII characters, such as 'wght')")
            }
            guard value.isFinite else { throw RecipeError.invalidValue(path: path, reason: "must be a finite number") }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(file, forKey: AnyCodingKey("file"))
        try container.encode(sha256, forKey: AnyCodingKey("sha256"))
        // Written only when set: recipes from before these keys existed keep
        // their canonical bytes, hence their hash in name ID 5.
        if faceIndex != 0 { try container.encode(faceIndex, forKey: AnyCodingKey("faceIndex")) }
        if !variation.isEmpty { try container.encode(variation, forKey: AnyCodingKey("variation")) }
    }
}

extension Recipe.Output: Codable {
    static let supportedLanguages: Set<String> = ["zh-TW"]

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(["familyName", "localizedFamilyName", "styleName", "weightClass", "fileName"])
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        familyName = try container.decode(String.self, forKey: AnyCodingKey("familyName"))
        localizedFamilyName =
            try container.decodeIfPresent([String: String].self, forKey: AnyCodingKey("localizedFamilyName")) ?? [:]
        styleName = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("styleName")) ?? "Regular"
        weightClass = try container.decodeIfPresent(Int.self, forKey: AnyCodingKey("weightClass"))
        fileName = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("fileName"))

        func checkName(_ value: String, _ key: String) throws {
            guard !value.isEmpty, value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw decoder.invalid(key, "must be non-empty without leading or trailing whitespace")
            }
        }
        try checkName(familyName, "familyName")
        try checkName(styleName, "styleName")
        for (language, name) in localizedFamilyName.sorted(by: { $0.key < $1.key }) {
            guard Recipe.Output.supportedLanguages.contains(language) else {
                throw RecipeError.invalidValue(
                    path: keyPath(decoder.codingPath + [AnyCodingKey("localizedFamilyName"), AnyCodingKey(language)]),
                    reason: "only zh-TW is supported (written as Windows language 0x0404)")
            }
            try checkName(name, "localizedFamilyName.\(language)")
        }
        if let weightClass, !(1...1000).contains(weightClass) {
            throw decoder.invalid("weightClass", "\(weightClass) is outside 1...1000")
        }
        if let fileName {
            // The name is joined to an output directory: no path components.
            guard !fileName.hasPrefix("."), !fileName.contains("/"), !fileName.contains("\\"),
                !fileName.contains(":"), fileName.lowercased().hasSuffix(".ttf"), fileName.count > 4
            else {
                throw decoder.invalid("fileName", "'\(fileName)' must be a plain file name ending in .ttf")
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(familyName, forKey: AnyCodingKey("familyName"))
        try container.encode(localizedFamilyName, forKey: AnyCodingKey("localizedFamilyName"))
        try container.encode(styleName, forKey: AnyCodingKey("styleName"))
        try container.encodeIfPresent(weightClass, forKey: AnyCodingKey("weightClass"))
        try container.encodeIfPresent(fileName, forKey: AnyCodingKey("fileName"))
    }
}

// MARK: - Steps

extension Recipe.Step: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let op = try container.decode(String.self, forKey: AnyCodingKey("op"))
        switch op {
        case "outlines":
            self = .outlines(try OutlinesStep(from: decoder))
        case "embolden":
            self = .embolden(try EmboldenStep(from: decoder))
        case "tracking":
            try decoder.rejectUnknownKeys(["op", "units"])
            let units = try container.decode(Int.self, forKey: AnyCodingKey("units"))
            guard units != 0 else { throw decoder.invalid("units", "must not be 0; leave the step out instead") }
            self = .tracking(TrackingOptions(units: units))
        case "lineHeight":
            try decoder.rejectUnknownKeys(["op", "units"])
            let units = try container.decode(Int.self, forKey: AnyCodingKey("units"))
            guard units > 0 else { throw decoder.invalid("units", "must be a positive number of font units") }
            self = .lineHeight(LineHeightOptions(units: units))
        case "s2t":
            try decoder.rejectUnknownKeys(["op", "mode", "taiwanVariants", "phrases"])
            let options = S2TOptions(
                mode: try container.decodeChoice(S2TMode.self, "mode", default: .single),
                taiwanVariants: try container.decodeIfPresent(Bool.self, forKey: AnyCodingKey("taiwanVariants"))
                    ?? false,
                phrases: try container.decodeIfPresent(Bool.self, forKey: AnyCodingKey("phrases")) ?? false)
            if options.phrases && options.mode != .single {
                throw decoder.invalid(
                    "phrases",
                    "phrases need mode 'single': the phrase rules reproduce OpenCC's conversion, which "
                        + "'\(options.mode.rawValue)' deliberately does not follow")
            }
            self = .s2t(options)
        case "pseudoVertical":
            try decoder.rejectUnknownKeys(["op", "punctuation"])
            self = .pseudoVertical(
                PseudoVerticalOptions(
                    punctuation: try container.decodeChoice(PunctuationMode.self, "punctuation", default: .centered)))
        case "replace":
            self = .replace(try ReplaceStep(from: decoder))
        default:
            throw decoder.invalid(
                "op",
                "unknown operation '\(op)'; expected 'outlines', 'embolden', 'tracking', 'lineHeight', 's2t', "
                    + "'pseudoVertical' or 'replace'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(op, forKey: AnyCodingKey("op"))
        switch self {
        case .outlines(let step):
            try step.encode(to: encoder)
        case .embolden(let step):
            try step.encode(to: encoder)
        case .tracking(let options):
            try container.encode(options.units, forKey: AnyCodingKey("units"))
        case .lineHeight(let options):
            try container.encode(options.units, forKey: AnyCodingKey("units"))
        case .s2t(let options):
            try container.encode(options.mode.rawValue, forKey: AnyCodingKey("mode"))
            try container.encode(options.taiwanVariants, forKey: AnyCodingKey("taiwanVariants"))
            // Written only when on: recipes from before `phrases` existed keep
            // their canonical bytes, hence their hash in name ID 5 and the
            // bytes of every font built from them.
            if options.phrases { try container.encode(true, forKey: AnyCodingKey("phrases")) }
        case .pseudoVertical(let options):
            try container.encode(options.punctuation.rawValue, forKey: AnyCodingKey("punctuation"))
        case .replace(let step):
            try step.encode(to: encoder)
        }
    }
}

extension EmboldenStep: Codable {
    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(["op", "weight", "skip", "perCharacter", "widen"])
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        weight = try container.decode(Double.self, forKey: AnyCodingKey("weight"))
        guard weight.isFinite, weight > 0 else { throw decoder.invalid("weight", "must be a positive number") }

        let skipped = try container.decodeIfPresent([String].self, forKey: AnyCodingKey("skip")) ?? []
        var scalars: Set<Unicode.Scalar> = []
        for (index, text) in skipped.enumerated() {
            guard let scalar = singleScalar(text) else {
                throw RecipeError.invalidValue(
                    path: keyPath(decoder.codingPath + [AnyCodingKey("skip"), AnyCodingKey(intValue: index)!]),
                    reason: "'\(text)' must be exactly one character (one Unicode code point)")
            }
            scalars.insert(scalar)
        }
        // A set in meaning; stored sorted so the canonical encoding ignores listing order.
        skip = scalars.sorted { $0.value < $1.value }.map { String($0) }

        perCharacter =
            try container.decodeIfPresent([String: CharacterOverride].self, forKey: AnyCodingKey("perCharacter")) ?? [:]
        for key in perCharacter.keys.sorted() where singleScalar(key) == nil {
            throw RecipeError.invalidValue(
                path: keyPath(decoder.codingPath + [AnyCodingKey("perCharacter"), AnyCodingKey(key)]),
                reason: "'\(key)' must be exactly one character (one Unicode code point)")
        }
        widen = try container.decodeIfPresent(Bool.self, forKey: AnyCodingKey("widen")) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(weight, forKey: AnyCodingKey("weight"))
        try container.encode(skip, forKey: AnyCodingKey("skip"))
        try container.encode(perCharacter, forKey: AnyCodingKey("perCharacter"))
        // Written only when on, like s2t `phrases`: older recipes keep their
        // canonical bytes and hash.
        if widen { try container.encode(true, forKey: AnyCodingKey("widen")) }
    }
}

extension EmboldenStep.CharacterOverride: Codable {
    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(["weight"])
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        weight = try container.decode(Double.self, forKey: AnyCodingKey("weight"))
        guard weight.isFinite, weight > 0 else {
            throw decoder.invalid("weight", "must be a positive number; use 'skip' to leave a character unchanged")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(weight, forKey: AnyCodingKey("weight"))
    }
}
