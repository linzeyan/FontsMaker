import Foundation

/// License gate (technical design §7, product spec §4.2).
public enum LicenseStatus: String, Equatable, Sendable {
    /// OS/2 fsType has the Restricted License bit: the font must not be modified.
    case restricted
    /// The name table points at the SIL Open Font License.
    case openFontLicense
    /// Anything else: the user has to confirm they hold the rights.
    case unknown
}

public enum License {
    static let restrictedLicenseBit: UInt16 = 0x0002
    static let oflMarkers = ["open font license", "scripts.sil.org/ofl", "openfontlicense.org"]

    public static func status(fsType: UInt16, names: [NameRecord]) -> LicenseStatus {
        if fsType & restrictedLicenseBit != 0 { return .restricted }
        let licenseTexts = names.filter { $0.nameID == 13 || $0.nameID == 14 }.compactMap(\.string)
        let isOFL = licenseTexts.contains { text in
            let lowered = text.lowercased()
            return oflMarkers.contains { lowered.contains($0) }
        }
        return isOFL ? .openFontLicense : .unknown
    }

    /// Reserved Font Names declared inside the font: the quoted strings that
    /// follow "Reserved Font Name" in name IDs 0 (copyright) and 13 (license),
    /// deduplicated in order of appearance.
    public static func reservedFontNames(names: [NameRecord]) -> [String] {
        var found: [String] = []
        for record in names where record.nameID == 0 || record.nameID == 13 {
            for name in reservedFontNames(in: record.string ?? "") where !found.contains(name) {
                found.append(name)
            }
        }
        return found
    }

    private static let quotePairs: [Character: Character] = [
        "\"": "\"", "'": "'", "\u{201C}": "\u{201D}", "\u{2018}": "\u{2019}", "\u{300C}": "\u{300D}",
    ]

    /// Parses declarations such as `with Reserved Font Name "Source"` or
    /// `Reserved Font Names "A", "B" and "C"`. The phrase is skipped when it is
    /// itself quoted, because the full OFL text defines the term that way
    /// (`"Reserved Font Name" refers to …`) and that is not a declaration.
    public static func reservedFontNames(in text: String) -> [String] {
        let phrase = Array("reserved font name")
        let characters = Array(text)
        let lowered = characters.map { $0.lowercased().first ?? $0 }
        var names: [String] = []
        var index = 0
        while index + phrase.count <= characters.count {
            guard Array(lowered[index..<index + phrase.count]) == phrase else {
                index += 1
                continue
            }
            let isQuotedTerm = index > 0 && quotePairs[characters[index - 1]] != nil
            var cursor = index + phrase.count
            index = cursor
            if isQuotedTerm { continue }
            if cursor < characters.count && lowered[cursor] == "s" { cursor += 1 }
            // Collect quoted strings separated by whitespace, commas, colons or "and".
            while cursor < characters.count {
                let character = characters[cursor]
                if character.isWhitespace || character == "," || character == ":" {
                    cursor += 1
                } else if lowered[cursor...].starts(with: "and"), cursor + 3 < characters.count,
                    characters[cursor + 3].isWhitespace
                {
                    cursor += 3
                } else if let closing = quotePairs[character],
                    let end = characters[(cursor + 1)...].firstIndex(of: closing)
                {
                    let name = String(characters[(cursor + 1)..<end]).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { names.append(name) }
                    cursor = end + 1
                } else {
                    break
                }
            }
            index = cursor
        }
        return names
    }
}

extension Font {
    public var licenseStatus: LicenseStatus {
        License.status(fsType: os2?.fsType ?? 0, names: names)
    }

    public var reservedFontNames: [String] {
        License.reservedFontNames(names: names)
    }
}
