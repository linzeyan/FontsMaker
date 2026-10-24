import Foundation

/// Naming of an output font (technical design §5.5, product spec §4.3).
public struct RenameOptions: Equatable, Sendable {
    /// English family name (Windows 0x0409); also the base of the PostScript name.
    public var familyName: String
    /// Localized family names by language tag; only "zh-TW" (Windows 0x0404) is supported.
    public var localizedFamilyNames: [String: String]
    /// "Regular", "Bold", "Medium", "Bold Italic", "Light Italic", ...
    public var styleName: String
    /// nil: derived from the weight word of `styleName`.
    public var weightClass: UInt16?
    /// Written after "Version x.yyy; " in name ID 5, e.g. "FontsMaker 0.1.0; recipe 1a2b3c4d".
    public var provenance: String

    public init(
        familyName: String, localizedFamilyNames: [String: String] = [:], styleName: String = "Regular",
        weightClass: UInt16? = nil, provenance: String
    ) {
        self.familyName = familyName
        self.localizedFamilyNames = localizedFamilyNames
        self.styleName = styleName
        self.weightClass = weightClass
        self.provenance = provenance
    }
}

public struct RenameReport: Equatable, Sendable {
    public var familyName: String
    public var fullName: String
    public var postScriptName: String
    public var weightClass: UInt16
    /// Name IDs 16/17 were written because the style is outside Regular/Italic/Bold/Bold Italic.
    public var typographicNames: Bool
    public var removedRecords: Int
    public var writtenRecords: Int
    /// Reserved Font Names declared only outside the font (OFL.txt, README) cannot be
    /// checked from the file, so every build carries this reminder (product spec §4.3).
    public var reservedNameNotice: String
}

public enum RenameError: Error, Equatable, Sendable {
    case containsSourceFamilyName(field: String, value: String, sourceName: String)
    case containsReservedFontName(field: String, value: String, reservedName: String)
    case invalidPostScriptCharacters(field: String, value: String, characters: String)
    case postScriptNameTooLong(String)
    case unknownWeight(styleName: String)
    case unsupportedLanguage(String)
    case missingOS2
}

extension RenameError: LocalizedError, CustomStringConvertible {
    public var description: String {
        switch self {
        case .containsSourceFamilyName(let field, let value, let sourceName):
            return
                "\(field) '\(value)' contains the source family name '\(sourceName)'. A derived font needs its own "
                + "name, so it does not clash with the original when both are installed (OFL condition 3)."
        case .containsReservedFontName(let field, let value, let reservedName):
            return
                "\(field) '\(value)' contains '\(reservedName)', which the source font declares as a Reserved Font "
                + "Name. The OFL forbids it in modified versions without the copyright holder's permission."
        case .invalidPostScriptCharacters(let field, let value, let characters):
            return
                "\(field) '\(value)' contains characters a PostScript name cannot hold (\(characters)). Use ASCII "
                + "letters, digits and spaces; put the Chinese name in localizedFamilyName."
        case .postScriptNameTooLong(let name):
            return "The PostScript name '\(name)' is longer than 63 characters; use a shorter family or style name."
        case .unknownWeight(let styleName):
            return
                "styleName '\(styleName)' has no standard weight word (Thin, ExtraLight, Light, Regular, Medium, "
                + "SemiBold, Bold, ExtraBold, Black); set weightClass explicitly."
        case .unsupportedLanguage(let tag):
            return "Localized family names are supported for zh-TW only, not '\(tag)'."
        case .missingOS2:
            return "The font has no OS/2 table, so its weight class cannot be set."
        }
    }

    public var errorDescription: String? { description }
}

extension Font {
    /// Every record that names the font, on every platform and in every
    /// language: left in place, an old zh-CN or Mac name would keep showing
    /// the source family in some menus (design §2). 18/20/21/22/25 (Mac
    /// compatible full name, CID findfont, WWS family/subfamily, variations
    /// PostScript prefix) carry the same identity, so they go as well.
    /// ID 5 is replaced by the traceable version string.
    static let identityNameIDs: Set<UInt16> = [1, 2, 3, 4, 5, 6, 16, 17, 18, 20, 21, 22, 25]
    static let copyrightSuffix = "; Modified with FontsMaker"
    static let english: UInt16 = 0x0409
    static let traditionalChinese: UInt16 = 0x0404

    /// Checks the naming rules against this (source) font without changing
    /// it, so a build can refuse bad names before any expensive step runs.
    public func validateRename(_ options: RenameOptions) throws {
        _ = try plannedNames(options)
    }

    /// Replaces the font's naming records and the weight/style bits
    /// (usWeightClass, fsSelection ITALIC/BOLD/REGULAR, macStyle bold/italic).
    public mutating func rename(_ options: RenameOptions) throws -> RenameReport {
        let plan = try plannedNames(options)
        guard var os2 else { throw RenameError.missingOS2 }

        let before = names.count
        names.removeAll { Font.identityNameIDs.contains($0.nameID) }
        let removed = before - names.count
        for index in names.indices where names[index].nameID == 0 {
            names[index] = appendingCopyrightSuffix(names[index])
        }
        names.append(contentsOf: plan.records)

        os2.weightClass = plan.weightClass
        // ITALIC (0), BOLD (5), REGULAR (6); the other bits describe metrics, not style.
        os2.fsSelection &= ~UInt16(0b110_0001)
        if plan.style.italic { os2.fsSelection |= 1 << 0 }
        if plan.style.bold { os2.fsSelection |= 1 << 5 }
        if !plan.style.italic && !plan.style.bold { os2.fsSelection |= 1 << 6 }
        self.os2 = os2
        macStyle &= ~UInt16(0b11)
        if plan.style.bold { macStyle |= 1 << 0 }
        if plan.style.italic { macStyle |= 1 << 1 }

        let licenseURL = names.first { $0.nameID == 14 }?.string
        let inFile = reservedFontNames
        var notice =
            "Reserved Font Names declared only outside the font file (OFL.txt, README) cannot be checked here; "
            + "confirm the new name against the source project before distributing"
            + (licenseURL.map { " (license: \($0))" } ?? "") + "."
        if !inFile.isEmpty {
            notice += " Checked in-file RFNs: " + inFile.map { "\"\($0)\"" }.joined(separator: ", ") + "."
        }
        return RenameReport(
            familyName: options.familyName, fullName: plan.fullName, postScriptName: plan.postScriptName,
            weightClass: plan.weightClass, typographicNames: plan.style.typographic, removedRecords: removed,
            writtenRecords: plan.records.count, reservedNameNotice: notice)
    }

    // MARK: - Planning

    struct NamePlan {
        var style: StyleName
        var weightClass: UInt16
        var fullName: String
        var postScriptName: String
        var records: [NameRecord]
    }

    private func plannedNames(_ options: RenameOptions) throws -> NamePlan {
        for tag in options.localizedFamilyNames.keys.sorted() where tag != "zh-TW" {
            throw RenameError.unsupportedLanguage(tag)
        }
        let localized = options.localizedFamilyNames["zh-TW"]
        try checkAgainstSourceNames(options.familyName, field: "familyName")
        try checkAgainstSourceNames(options.styleName, field: "styleName")
        if let localized { try checkAgainstSourceNames(localized, field: "localizedFamilyName.zh-TW") }

        let style = StyleName(options.styleName)
        guard let weightClass = options.weightClass ?? style.weightClass else {
            throw RenameError.unknownWeight(styleName: options.styleName)
        }
        let postScriptName =
            try postScriptPart(options.familyName, field: "familyName") + "-"
            + postScriptPart(style.postScriptStyle, field: "styleName")
        guard postScriptName.count <= 63 else { throw RenameError.postScriptNameTooLong(postScriptName) }

        // head.fontRevision, 16.16 fixed point.
        let head = tables["head"]!
        let revision = Int32(bitPattern: UInt32(head.readU16(at: 4)) << 16 | UInt32(head.readU16(at: 6)))
        let version = String(format: "%.3f", Double(revision) / 65536)
        let fullName = options.familyName + " " + style.fullStyle
        var records: [NameRecord] = []
        func add(_ language: UInt16, _ nameID: UInt16, _ text: String) {
            records.append(NameRecord(windowsLanguage: language, nameID: nameID, string: text))
        }
        func addFamily(_ language: UInt16, _ family: String) {
            add(language, 1, style.legacyFamily(family))
            add(language, 2, style.legacySubfamily)
            add(language, 4, family + " " + style.fullStyle)
            if style.typographic {
                add(language, 16, family)
                add(language, 17, style.fullStyle)
            }
        }
        addFamily(Font.english, options.familyName)
        add(Font.english, 3, "\(version);FontsMaker;\(postScriptName)")
        add(Font.english, 5, "Version \(version); \(options.provenance)")
        add(Font.english, 6, postScriptName)
        if let localized { addFamily(Font.traditionalChinese, localized) }
        return NamePlan(
            style: style, weightClass: weightClass, fullName: fullName, postScriptName: postScriptName,
            records: records)
    }

    /// Rule from product spec §4.3: no source family name (IDs 1 and 16, every
    /// platform and language) and no in-file Reserved Font Name inside a new
    /// name. Compared case-insensitively and ignoring spaces, because the
    /// PostScript name drops spaces ("Guan Kiap" would still collide).
    private func checkAgainstSourceNames(_ value: String, field: String) throws {
        let candidate = Font.comparable(value)
        var sourceFamilies: [String] = []
        for record in names where record.nameID == 1 || record.nameID == 16 {
            if let name = record.string, !sourceFamilies.contains(name) { sourceFamilies.append(name) }
        }
        for name in sourceFamilies where !Font.comparable(name).isEmpty {
            if candidate.contains(Font.comparable(name)) {
                throw RenameError.containsSourceFamilyName(field: field, value: value, sourceName: name)
            }
        }
        for reserved in reservedFontNames where !Font.comparable(reserved).isEmpty {
            if candidate.contains(Font.comparable(reserved)) {
                throw RenameError.containsReservedFontName(field: field, value: value, reservedName: reserved)
            }
        }
    }

    static func comparable(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { !$0.properties.isWhitespace })
    }

    /// PostScript names allow printable ASCII except [](){}<>/% (OpenType name ID 6).
    private func postScriptPart(_ value: String, field: String) throws -> String {
        let forbidden = Set("[](){}<>/%")
        var invalid: [Character] = []
        var result = ""
        for character in value where character != " " {
            if let ascii = character.asciiValue, (33...126).contains(ascii), !forbidden.contains(character) {
                result.append(character)
            } else if !invalid.contains(character) {
                invalid.append(character)
            }
        }
        if !invalid.isEmpty {
            throw RenameError.invalidPostScriptCharacters(
                field: field, value: value, characters: invalid.map { "'\($0)'" }.joined(separator: " "))
        }
        return result
    }

    private func appendingCopyrightSuffix(_ record: NameRecord) -> NameRecord {
        // Undecodable legacy encodings stay as they are rather than being guessed at.
        guard let text = record.string, !text.hasSuffix(Font.copyrightSuffix) else { return record }
        let updated = text + Font.copyrightSuffix
        var result = record
        switch (record.platformID, record.encodingID) {
        case (1, 0):
            guard let data = updated.data(using: .macOSRoman) else { return record }
            result.bytes = [UInt8](data)
        default:
            result.bytes = NameRecord(windowsLanguage: 0, nameID: 0, string: updated).bytes
        }
        return result
    }
}

/// The OpenType naming model for one style name. Regular, Italic, Bold and
/// Bold Italic form the four-member "RIBBI" family of name IDs 1/2; any other
/// weight goes into ID 1 ("Family Medium" + "Regular") and the real family
/// and style into the typographic IDs 16/17.
struct StyleName {
    static let weights: [String: UInt16] = [
        "thin": 100, "hairline": 100, "extralight": 200, "ultralight": 200, "light": 300, "": 400, "regular": 400,
        "normal": 400, "medium": 500, "semibold": 600, "demibold": 600, "bold": 700, "extrabold": 800,
        "ultrabold": 800, "black": 900, "heavy": 900,
    ]

    let italic: Bool
    /// RIBBI bold: sets the BOLD bit; SemiBold or ExtraBold do not.
    let bold: Bool
    let typographic: Bool
    let weightClass: UInt16?
    /// Weight words as written ("Medium", "Extra Light"), "" for Regular.
    private let weightWords: String
    /// The style as used in full names: canonical RIBBI spelling, else as written.
    let fullStyle: String

    init(_ styleName: String) {
        let words = styleName.split(separator: " ").map(String.init)
        italic = words.contains { $0.lowercased() == "italic" }
        weightWords = words.filter { $0.lowercased() != "italic" }.joined(separator: " ")
        let key = weightWords.replacingOccurrences(of: " ", with: "").lowercased()
        weightClass = StyleName.weights[key]
        bold = key == "bold"
        typographic = !(key == "" || key == "regular" || bold)
        if typographic {
            fullStyle = words.joined(separator: " ")
        } else {
            fullStyle = bold ? (italic ? "Bold Italic" : "Bold") : (italic ? "Italic" : "Regular")
        }
    }

    var legacySubfamily: String {
        typographic ? (italic ? "Italic" : "Regular") : fullStyle
    }

    func legacyFamily(_ family: String) -> String {
        typographic ? family + " " + weightWords : family
    }

    var postScriptStyle: String { fullStyle }
}
