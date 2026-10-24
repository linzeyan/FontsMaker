import ArgumentParser
import FontsMakerKit
import Foundation

struct Inspect: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show a font's names, glyph counts, outline format, variation axes, the fonts of a "
            + "collection, license status and Reserved Font Names."
    )

    @Argument(help: "Path to a font: TrueType or OpenType (.ttf, .otf), variable, or a collection (.ttc).")
    var font: String

    @Option(help: "Font of a collection (.ttc) to describe in detail (the recipe's source.faceIndex).")
    var face: Int = 0

    func run() throws {
        let url = URL(fileURLWithPath: font)
        let bytes = [UInt8](try Data(contentsOf: url))
        let faces = try Font.faces(in: bytes)
        guard faces.indices.contains(face) else {
            throw FontLoadError.faceIndexOutOfRange(index: face, faceCount: faces.count)
        }
        let selected = faces[face]
        // Glyph and character counts below are of the font as the engine
        // reads it: converted to TrueType, at the default instance.
        let model = try Font(bytes: bytes, faceIndex: face)

        var glyphsPerCharacterCount: [UInt16: Int] = [:]
        for glyph in model.characterMap.mappings.values { glyphsPerCharacterCount[glyph, default: 0] += 1 }
        let sharedGlyphs = glyphsPerCharacterCount.values.filter { $0 > 1 }.count
        let composites = model.glyphs.filter(\.isComposite).count
        let vertical = model.verticalSubstitutions.count

        var lines: [String] = []
        func row(_ label: String, _ value: String) {
            lines.append(label.padding(toLength: 16, withPad: " ", startingAt: 0) + value)
        }
        row("File", url.lastPathComponent)
        if faces.count > 1 {
            row("Collection", "\(faces.count) fonts; details below are of faceIndex \(face)")
            for entry in faces {
                lines.append("  \(entry.index)  \(entry.fullName ?? "<no name>")  (\(entry.outlineFormat.rawValue))")
            }
        }
        row(
            "Outline format",
            selected.outlineFormat == .trueType && selected.axes.isEmpty
                ? selected.outlineFormat.rawValue
                : "\(selected.outlineFormat.rawValue); converted to static TrueType when read")
        if !selected.axes.isEmpty {
            row("Variation axes", "\(selected.axes.count); without source.variation the default instance is used")
            for axis in selected.axes {
                let range = [axis.minimum, axis.defaultValue, axis.maximum].map(formatAxis)
                lines.append(
                    "  \(axis.tag)  min \(range[0])  default \(range[1])  max \(range[2])"
                        + (axis.name.map { "  \($0)" } ?? "") + (axis.hidden ? "  (hidden)" : ""))
            }
            row("Named instances", "\(selected.namedInstances.count)")
            for instance in selected.namedInstances {
                let location = selected.axes.map {
                    "\($0.tag) \(formatAxis(instance.coordinates[$0.tag] ?? $0.defaultValue))"
                }
                lines.append("  \(instance.name ?? "<no name>"): " + location.joined(separator: ", "))
            }
        }
        row("Glyphs", "\(model.glyphs.count) (\(composites) composite)")
        row("Characters", "\(model.characterMap.mappings.count) mapped code points")
        row("Shared glyphs", "\(sharedGlyphs) glyphs are mapped from more than one code point")
        row("Vertical forms", vertical > 0 ? "yes (vert/vrt2, \(vertical) substitutions)" : "no")
        // What a lineHeight step starts from: readers read different tables.
        let hhea = model.hhea
        var metrics =
            "units per em \(model.unitsPerEm); ascender/descender/line gap: hhea \(hhea.ascender)/\(hhea.descender)/"
            + "\(hhea.lineGap) (line \(Int(hhea.ascender) - Int(hhea.descender) + Int(hhea.lineGap)))"
        if let os2 = model.os2, let ascender = os2.typoAscender, let descender = os2.typoDescender,
            let gap = os2.typoLineGap
        {
            metrics += ", typo \(ascender)/\(descender)/\(gap)"
        }
        if let os2 = model.os2, let ascent = os2.winAscent, let descent = os2.winDescent {
            metrics += ", win \(ascent)/-\(descent)"
        }
        row("Line metrics", metrics)
        row("License", describe(model.licenseStatus))
        if let url = model.names.first(where: { $0.nameID == 14 })?.string {
            row("License URL", url)
        }
        let reserved = model.reservedFontNames
        row(
            "Reserved names",
            reserved.isEmpty
                ? "none declared in the font file (projects often declare them only in OFL.txt or README)"
                : reserved.map { "\"\($0)\"" }.joined(separator: ", "))
        lines.append("Names")
        for (nameID, title) in [(1, "Family"), (16, "Typographic family"), (4, "Full name"), (6, "PostScript name")] {
            let records = model.names.filter { $0.nameID == nameID }
            if records.isEmpty { continue }
            lines.append("  \(title) (ID \(nameID))")
            for record in records {
                let language = languageLabel(record).padding(toLength: 18, withPad: " ", startingAt: 0)
                lines.append("    \(language)\(record.string ?? "<undecodable>")")
            }
        }
        print(lines.joined(separator: "\n"))
    }

    private func formatAxis(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
    }

    private func describe(_ status: LicenseStatus) -> String {
        switch status {
        case .restricted: return "restricted (OS/2 fsType forbids modification; FontsMaker will refuse it)"
        case .openFontLicense: return "OFL (SIL Open Font License)"
        case .unknown: return "unknown (you must confirm you may modify and redistribute this font)"
        }
    }

    private func languageLabel(_ record: NameRecord) -> String {
        switch record.platformID {
        case 0:
            return "Unicode"
        case 1:
            let mac: [UInt16: String] = [0: "en", 11: "ja", 19: "zh-Hant", 23: "ko", 33: "zh-Hans"]
            return "Mac " + (mac[record.languageID] ?? "lang \(record.languageID)")
        case 3:
            let windows: [UInt16: String] = [
                0x0409: "en-US", 0x0809: "en-GB", 0x0404: "zh-TW", 0x0804: "zh-CN", 0x0C04: "zh-HK",
                0x1004: "zh-SG", 0x1404: "zh-MO", 0x0411: "ja-JP", 0x0412: "ko-KR",
            ]
            return "Windows "
                + (windows[record.languageID] ?? "0x" + String(record.languageID, radix: 16, uppercase: true))
        default:
            return "platform \(record.platformID)"
        }
    }
}
