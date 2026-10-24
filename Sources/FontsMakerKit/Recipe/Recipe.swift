import Foundation

/// A build recipe (technical design §6, decision D4): one source font, one
/// output font, and the operations in between, applied in order.
///
/// Decoding is strict: unknown keys anywhere are errors naming the key path,
/// so a misspelled parameter can never be silently ignored. Optional fields
/// with a fixed default are filled in on decode, so `{"op": "s2t"}` and the
/// fully spelled-out step are the same recipe (and hash the same).
public struct Recipe: Equatable, Sendable {
    public static let formatVersion = 1

    public var source: Source
    public var output: Output
    public var steps: [Step]

    public init(source: Source, output: Output, steps: [Step]) {
        self.source = source
        self.output = output
        self.steps = steps
    }

    public struct Source: Equatable, Sendable {
        /// Path of the source font, relative to the recipe file (absolute paths are allowed).
        public var file: String
        /// Lowercase hex sha256 of the source font file; a mismatch refuses the build.
        public var sha256: String
        /// Which font of a collection (.ttc) to build from; 0 for a plain font file.
        public var faceIndex: Int
        /// Instance of a variable font: axis tag → value. Axes left out take
        /// their default, so an empty map means the default instance.
        public var variation: [String: Double]

        public init(file: String, sha256: String, faceIndex: Int = 0, variation: [String: Double] = [:]) {
            self.file = file
            self.sha256 = sha256
            self.faceIndex = faceIndex
            self.variation = variation
        }
    }

    /// Naming of the output font; applied by the rename step every build runs.
    public struct Output: Equatable, Sendable {
        public var familyName: String
        /// Localized family names keyed by language tag. Only "zh-TW" is written (design §5.5).
        public var localizedFamilyName: [String: String]
        public var styleName: String
        /// nil: derived from the weight word in `styleName` (Regular 400, Medium 500, Bold 700, ...).
        public var weightClass: Int?
        /// nil: `<PostScriptName>.ttf`.
        public var fileName: String?

        public init(
            familyName: String, localizedFamilyName: [String: String] = [:], styleName: String = "Regular",
            weightClass: Int? = nil, fileName: String? = nil
        ) {
            self.familyName = familyName
            self.localizedFamilyName = localizedFamilyName
            self.styleName = styleName
            self.weightClass = weightClass
            self.fileName = fileName
        }
    }

    public enum Step: Equatable, Sendable {
        /// Always the first step: it replaces source glyphs (design §5.8).
        case outlines(OutlinesStep)
        case embolden(EmboldenStep)
        case tracking(TrackingOptions)
        case lineHeight(LineHeightOptions)
        case s2t(S2TOptions)
        case pseudoVertical(PseudoVerticalOptions)
        case replace(ReplaceStep)

        /// The `op` value in JSON.
        public var op: String {
            switch self {
            case .outlines: return "outlines"
            case .embolden: return "embolden"
            case .tracking: return "tracking"
            case .lineHeight: return "lineHeight"
            case .s2t: return "s2t"
            case .pseudoVertical: return "pseudoVertical"
            case .replace: return "replace"
            }
        }

        /// Outline operations trigger composite decomposition and hinting
        /// removal (design §4.1, D5); s2t only touches cmap, tracking and
        /// lineHeight only metrics. replace adds outlines the font's hinting
        /// was never written for.
        public var modifiesOutlines: Bool {
            switch self {
            case .outlines, .embolden, .pseudoVertical, .replace: return true
            case .tracking, .lineHeight, .s2t: return false
            }
        }
    }
}

/// The embolden step as written in a recipe: settings keyed by character.
/// The engine works on glyph IDs; `resolve(in:)` translates (design §4.2, §6).
public struct EmboldenStep: Equatable, Sendable {
    /// Stroke thickening in font units (Phase 0: equals FontForge `changeWeight`).
    public var weight: Double
    /// Characters left unchanged, each a single Unicode scalar; sorted and unique.
    public var skip: [String]
    /// Per-character weight overrides, e.g. a smaller weight for a crowded glyph.
    public var perCharacter: [String: CharacterOverride]
    /// Advances grow with the outlines, keeping the source's side bearings
    /// (`EmboldenOptions.widen`): Latin text keeps its letter spacing.
    public var widen: Bool

    public init(
        weight: Double, skip: [String] = [], perCharacter: [String: CharacterOverride] = [:], widen: Bool = false
    ) {
        self.weight = weight
        self.skip = skip
        self.perCharacter = perCharacter
        self.widen = widen
    }

    public struct CharacterOverride: Equatable, Sendable {
        public var weight: Double

        public init(weight: Double) {
            self.weight = weight
        }
    }
}

/// Problems in the recipe document itself, found before any font is read.
public enum RecipeError: Error, Equatable, Sendable {
    case notJSON(String)
    case unknownKey(path: String)
    case missingKey(path: String)
    case invalidValue(path: String, reason: String)
    case unsupportedFormatVersion(Int)
}

extension RecipeError: LocalizedError, CustomStringConvertible {
    public var description: String {
        switch self {
        case .notJSON(let detail):
            return "The recipe is not valid JSON: \(detail)"
        case .unknownKey(let path):
            return "Unknown key '\(path)' in the recipe. Check the spelling; unknown keys are never ignored."
        case .missingKey(let path):
            return "The recipe is missing the required key '\(path)'."
        case .invalidValue(let path, let reason):
            return "Invalid value at '\(path)': \(reason)"
        case .unsupportedFormatVersion(let version):
            return
                "Recipe formatVersion \(version) is not supported; this FontsMaker reads formatVersion \(Recipe.formatVersion)."
        }
    }

    public var errorDescription: String? { description }
}
