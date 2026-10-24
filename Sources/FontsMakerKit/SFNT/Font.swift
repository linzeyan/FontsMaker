import Foundation

public struct HorizontalMetric: Equatable, Sendable {
    public var advanceWidth: UInt16
    /// Only meaningful for glyphs without points; for all others the writer
    /// derives it from the outline (lsb = xMin), as TrueType requires.
    public var leftSideBearing: Int16

    public init(advanceWidth: UInt16, leftSideBearing: Int16) {
        self.advanceWidth = advanceWidth
        self.leftSideBearing = leftSideBearing
    }
}

/// One `vmtx` entry. Unlike `HorizontalMetric.leftSideBearing`, the top side
/// bearing is written as stored: it depends on the vertical origin, which the
/// glyph outline alone does not determine.
public struct VerticalMetric: Equatable, Sendable {
    public var advanceHeight: UInt16
    public var topSideBearing: Int16

    public init(advanceHeight: UInt16, topSideBearing: Int16) {
        self.advanceHeight = advanceHeight
        self.topSideBearing = topSideBearing
    }
}

/// The OS/2 fields the engine reads or edits. The table itself is written by
/// patching these into the source bytes, so every other field stays untouched.
public struct OS2Fields: Equatable, Sendable {
    /// lineHeight raises 2 or 3 to 4 to set USE_TYPO_METRICS (same layout).
    public var version: UInt16
    public var xAvgCharWidth: Int16
    public var weightClass: UInt16
    public let fsType: UInt16
    /// ITALIC (bit 0), BOLD (bit 5) and REGULAR (bit 6) must agree with the style names.
    public var fsSelection: UInt16
    /// nil for the short version-0 table that predates typo metrics.
    public var typoAscender: Int16?
    public var typoDescender: Int16?
    public var typoLineGap: Int16?
    /// nil for the short version-0 table, like the typo metrics.
    public var winAscent: UInt16?
    public var winDescent: UInt16?
}

/// The hhea line metrics. Patched into the source bytes like `OS2Fields`;
/// the rest of hhea is recomputed from the glyphs by the writer.
public struct HheaFields: Equatable, Sendable {
    public var ascender: Int16
    public var descender: Int16
    public var lineGap: Int16
}

/// A TrueType font held as: decoded tables the engine edits, and the raw
/// bytes of every source table (technical design §4.1). Tables the engine
/// does not model are written back byte for byte.
public struct Font: Sendable {
    public var sfntVersion: UInt32
    /// Raw bytes of every table in the source, keyed by tag.
    public var tables: [String: [UInt8]]
    public let unitsPerEm: UInt16
    public var glyphs: [Glyph]
    public var horizontalMetrics: [HorizontalMetric]
    /// nil when the font has no `vhea`/`vmtx` pair; otherwise one entry per glyph.
    public var verticalMetrics: [VerticalMetric]?
    public var characterMap: CharacterMap
    public var names: [NameRecord]
    var nameLanguageTags: [[UInt8]]
    public var hhea: HheaFields
    public var os2: OS2Fields?
    /// `head.macStyle`: bold (bit 0) and italic (bit 1) mirror the style names.
    public var macStyle: UInt16
    /// Glyph → vertical alternate from GSUB `vert`/`vrt2` (read-only).
    public let verticalSubstitutions: [UInt16: UInt16]
    /// Set by s2t with `phrases`, turned into GSUB rules by `buildPhraseLookups()`.
    var phrasePlan: PhrasePlan? = nil
    /// Set by lineHeight: the writer raises win to cover every glyph it
    /// writes, so Windows GDI clips none (`coverGlyphsWithWin`).
    var winCoversGlyphs = false

    public init(contentsOf url: URL, faceIndex: Int = 0, variation: [String: Double] = [:]) throws {
        try self.init(bytes: [UInt8](try Data(contentsOf: url)), faceIndex: faceIndex, variation: variation)
    }

    public init(data: Data, faceIndex: Int = 0, variation: [String: Double] = [:]) throws {
        try self.init(bytes: [UInt8](data), faceIndex: faceIndex, variation: variation)
    }

    /// Loads one font of a file (`faceIndex` picks the member of a .ttc).
    /// A static TrueType font is read as it is; CFF/CFF2 outlines and
    /// variable fonts are first converted to static TrueType (design §4.1).
    /// `variation` picks the instance of a variable font by axis tag; axes it
    /// leaves out take their default value.
    public init(bytes: [UInt8], faceIndex: Int = 0, variation: [String: Double] = [:]) throws {
        let face = try SFNTFile.face(bytes, index: faceIndex)
        guard let format = face.outlineFormat else { throw FontLoadError.missingTable("glyf") }
        if format == .trueType && face.tables["fvar"] == nil {
            guard variation.isEmpty else { throw FontLoadError.notVariable }
            try self.init(sfntVersion: face.sfntVersion, tables: face.tables)
        } else {
            // CoreText loads one font per file; a collection member is
            // handed over as a standalone font of its own tables.
            let isCollection = bytes.starts(with: [0x74, 0x74, 0x63, 0x66])  // 'ttcf'
            let sfnt = isCollection ? Font.assemble(face.tables, sfntVersion: face.sfntVersion) : bytes
            self = try Font.normalized(face, format: format, sfnt: sfnt, variation: variation)
        }
    }

    /// Decodes a TrueType table set. `outlines` replaces glyf/loca/hmtx with
    /// glyphs and advances converted from other outline formats.
    init(
        sfntVersion: UInt32, tables: [String: [UInt8]],
        outlines: (glyphs: [Glyph], metrics: [HorizontalMetric])? = nil
    ) throws {
        self.sfntVersion = sfntVersion
        self.tables = tables

        func table(_ tag: String) throws -> [UInt8] {
            guard let data = tables[tag] else { throw FontLoadError.missingTable(tag) }
            return data
        }

        let head = try table("head")
        guard head.count >= 54, head.readU16(at: 12) == 0x5F0F && head.readU16(at: 14) == 0x3CF5 else {
            throw FontLoadError.malformed("head: bad length or magic number")
        }
        unitsPerEm = head.readU16(at: 18)
        macStyle = head.readU16(at: 44)
        let longLoca = head.readI16(at: 50) == 1

        let maxp = try table("maxp")
        guard maxp.count >= 32, maxp.readU16(at: 0) == 1 else {
            throw FontLoadError.malformed("maxp: TrueType fonts need a version 1.0 maxp table")
        }
        let numGlyphs = Int(maxp.readU16(at: 4))

        let hhea = try table("hhea")
        guard hhea.count >= 36 else { throw FontLoadError.malformed("hhea: table too short") }
        let numberOfHMetrics = Int(hhea.readU16(at: 34))
        self.hhea = HheaFields(
            ascender: hhea.readI16(at: 4), descender: hhea.readI16(at: 6), lineGap: hhea.readI16(at: 8))

        if let outlines {
            guard outlines.glyphs.count == numGlyphs, outlines.metrics.count == numGlyphs else {
                throw FontLoadError.malformed("converted outlines do not match numGlyphs \(numGlyphs)")
            }
            glyphs = outlines.glyphs
            horizontalMetrics = outlines.metrics
        } else {
            glyphs = try Font.readGlyphs(
                glyf: try table("glyf"), loca: try table("loca"), longLoca: longLoca, numGlyphs: numGlyphs)
            horizontalMetrics = try Font.readHorizontalMetrics(
                try table("hmtx"), numberOfHMetrics: numberOfHMetrics, numGlyphs: numGlyphs)
        }
        if let vhea = tables["vhea"], let vmtx = tables["vmtx"] {
            guard vhea.count >= 36 else { throw FontLoadError.malformed("vhea: table too short") }
            verticalMetrics = try Font.readVerticalMetrics(
                vmtx, numberOfLongMetrics: Int(vhea.readU16(at: 34)), numGlyphs: numGlyphs)
        } else {
            verticalMetrics = nil
        }
        characterMap = try CharacterMap.parse(try table("cmap"), numGlyphs: numGlyphs)
        let nameTable = try NameTable.parse(try table("name"))
        names = nameTable.records
        nameLanguageTags = nameTable.languageTags
        os2 = try tables["OS/2"].map(Font.readOS2)
        verticalSubstitutions =
            try tables["GSUB"].map { try GSUB.verticalSubstitutions($0, numGlyphs: numGlyphs) } ?? [:]
    }

    private static func readGlyphs(glyf: [UInt8], loca: [UInt8], longLoca: Bool, numGlyphs: Int) throws -> [Glyph] {
        var reader = ByteReader(loca, context: "loca")
        var offsets: [Int] = []
        offsets.reserveCapacity(numGlyphs + 1)
        for _ in 0...numGlyphs {
            offsets.append(longLoca ? Int(try reader.u32()) : Int(try reader.u16()) * 2)
        }
        var glyphs: [Glyph] = []
        glyphs.reserveCapacity(numGlyphs)
        for index in 0..<numGlyphs {
            let start = offsets[index]
            let end = offsets[index + 1]
            guard start <= end, end <= glyf.count else {
                throw FontLoadError.malformed("loca: invalid range for glyph \(index)")
            }
            do {
                glyphs.append(try Glyph.parse(glyf: glyf, range: start..<end, numGlyphs: numGlyphs))
            } catch FontLoadError.malformed(let detail) {
                throw FontLoadError.malformed("glyph \(index): \(detail)")
            }
        }
        return glyphs
    }

    private static func readHorizontalMetrics(
        _ hmtx: [UInt8], numberOfHMetrics: Int, numGlyphs: Int
    ) throws -> [HorizontalMetric] {
        guard numberOfHMetrics >= 1, numberOfHMetrics <= numGlyphs else {
            throw FontLoadError.malformed("hhea: numberOfHMetrics \(numberOfHMetrics) out of range")
        }
        var reader = ByteReader(hmtx, context: "hmtx")
        var metrics: [HorizontalMetric] = []
        metrics.reserveCapacity(numGlyphs)
        for _ in 0..<numberOfHMetrics {
            metrics.append(HorizontalMetric(advanceWidth: try reader.u16(), leftSideBearing: try reader.i16()))
        }
        // Trailing glyphs repeat the last advance and store only their lsb.
        let lastAdvance = metrics[numberOfHMetrics - 1].advanceWidth
        for _ in numberOfHMetrics..<numGlyphs {
            metrics.append(HorizontalMetric(advanceWidth: lastAdvance, leftSideBearing: try reader.i16()))
        }
        return metrics
    }

    /// Same layout as hmtx: long (advance, tsb) pairs, then tsb-only entries
    /// that repeat the last advance.
    private static func readVerticalMetrics(
        _ vmtx: [UInt8], numberOfLongMetrics: Int, numGlyphs: Int
    ) throws -> [VerticalMetric] {
        guard numberOfLongMetrics >= 1, numberOfLongMetrics <= numGlyphs else {
            throw FontLoadError.malformed("vhea: numOfLongVerMetrics \(numberOfLongMetrics) out of range")
        }
        var reader = ByteReader(vmtx, context: "vmtx")
        var metrics: [VerticalMetric] = []
        metrics.reserveCapacity(numGlyphs)
        for _ in 0..<numberOfLongMetrics {
            metrics.append(VerticalMetric(advanceHeight: try reader.u16(), topSideBearing: try reader.i16()))
        }
        let lastAdvance = metrics[numberOfLongMetrics - 1].advanceHeight
        for _ in numberOfLongMetrics..<numGlyphs {
            metrics.append(VerticalMetric(advanceHeight: lastAdvance, topSideBearing: try reader.i16()))
        }
        return metrics
    }

    private static func readOS2(_ table: [UInt8]) throws -> OS2Fields {
        guard table.count >= 68 else { throw FontLoadError.malformed("OS/2: table too short") }
        let hasTypoMetrics = table.count >= 74
        let hasWinMetrics = table.count >= 78
        return OS2Fields(
            version: table.readU16(at: 0),
            xAvgCharWidth: table.readI16(at: 2),
            weightClass: table.readU16(at: 4),
            fsType: table.readU16(at: 8),
            fsSelection: table.readU16(at: 62),
            typoAscender: hasTypoMetrics ? table.readI16(at: 68) : nil,
            typoDescender: hasTypoMetrics ? table.readI16(at: 70) : nil,
            typoLineGap: hasTypoMetrics ? table.readI16(at: 72) : nil,
            winAscent: hasWinMetrics ? table.readU16(at: 74) : nil,
            winDescent: hasWinMetrics ? table.readU16(at: 76) : nil)
    }
}

extension Font {
    /// Adds a glyph at the end of the glyph order and returns its ID. Existing
    /// IDs never move, so cmap, GSUB, GPOS and kern stay valid; the writer
    /// extends hmtx/vmtx and switches `post` to format 3 (no glyph names).
    /// `vertical` is required exactly when the font has vertical metrics.
    public mutating func appendGlyph(
        _ glyph: Glyph, horizontal: HorizontalMetric, vertical: VerticalMetric?
    ) throws -> UInt16 {
        guard glyphs.count < Int(UInt16.max) else {
            throw FontWriteError.unencodable("cannot add a glyph: TrueType allows at most 65535")
        }
        guard (vertical != nil) == (verticalMetrics != nil) else {
            throw FontWriteError.unencodable(
                verticalMetrics == nil
                    ? "a vertical metric was given for a font without vmtx"
                    : "the font has vmtx, so an added glyph needs a vertical metric")
        }
        glyphs.append(glyph)
        horizontalMetrics.append(horizontal)
        if let vertical { verticalMetrics?.append(vertical) }
        return UInt16(glyphs.count - 1)
    }
}
