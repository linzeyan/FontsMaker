/// How a font stores its glyph outlines.
public enum OutlineFormat: String, Equatable, Sendable {
    case trueType = "TrueType (glyf)"
    case cff = "CFF"
    case cff2 = "CFF2"
}

/// One variation axis of an `fvar` table, in user-space values.
public struct VariationAxis: Equatable, Sendable {
    public var tag: String
    public var minimum: Double
    public var defaultValue: Double
    public var maximum: Double
    /// HIDDEN_AXIS: meant for the font's own use, not for a user interface.
    public var hidden: Bool
    /// English axis name from the name table, when there is one.
    public var name: String?
}

/// A named instance of an `fvar` table, such as "Bold" at wght 700.
public struct NamedInstance: Equatable, Sendable {
    public var name: String?
    public var coordinates: [String: Double]
}

/// What a font file holds, read without converting any outlines: cheap
/// enough to show before the user picks a face or axis values.
public struct FontFace: Equatable, Sendable {
    public var index: Int
    public var outlineFormat: OutlineFormat
    /// Name ID 4 (full name), English when there is one.
    public var fullName: String?
    public var axes: [VariationAxis]
    public var namedInstances: [NamedInstance]
}

/// One font's tables, from a plain sfnt file or one member of a collection.
struct SFNTFace {
    var sfntVersion: UInt32
    var tables: [String: [UInt8]]

    /// nil when the face has neither glyf nor CFF/CFF2 outlines.
    var outlineFormat: OutlineFormat? {
        if tables["glyf"] != nil { return .trueType }
        if tables["CFF2"] != nil { return .cff2 }
        if tables["CFF "] != nil { return .cff }
        return nil
    }
}

enum SFNTFile {
    /// Offsets of every face's table directory: one for a plain sfnt, the
    /// TTC header's list for a collection. WOFF is refused by its signature.
    static func faceOffsets(_ bytes: [UInt8]) throws -> [Int] {
        guard bytes.count >= 12 else { throw FontLoadError.notAFont }
        var reader = ByteReader(bytes, context: "font header")
        switch try reader.u32() {
        case 0x774F_4646: throw FontLoadError.woff  // 'wOFF'
        case 0x774F_4632: throw FontLoadError.woff2  // 'wOF2'
        case 0x7474_6366:  // 'ttcf'
            try reader.skip(4)  // major/minor version; both versions start alike
            let count = Int(try reader.u32())
            guard count >= 1 else { throw FontLoadError.malformed("font collection holds no fonts") }
            // Each offset takes 4 bytes; a count the file cannot hold is damage, not a huge collection.
            guard count <= (bytes.count - 12) / 4 else {
                throw FontLoadError.malformed("font collection header lists \(count) fonts")
            }
            return try (0..<count).map { _ in Int(try reader.u32()) }
        case 0x0001_0000, 0x7472_7565, 0x4F54_544F:  // TrueType, Apple's 'true', 'OTTO'
            return [0]
        default:
            throw FontLoadError.notAFont
        }
    }

    static func face(_ bytes: [UInt8], index: Int) throws -> SFNTFace {
        let offsets = try faceOffsets(bytes)
        guard offsets.indices.contains(index) else {
            throw FontLoadError.faceIndexOutOfRange(index: index, faceCount: offsets.count)
        }
        return try readTableDirectory(bytes, at: offsets[index])
    }

    /// Table offsets are from the start of the file, in a collection too.
    private static func readTableDirectory(_ bytes: [UInt8], at start: Int) throws -> SFNTFace {
        var reader = ByteReader(bytes, from: start, context: "table directory")
        let sfntVersion = try reader.u32()
        switch sfntVersion {
        case 0x0001_0000, 0x7472_7565, 0x4F54_544F: break
        default: throw FontLoadError.notAFont
        }
        let count = Int(try reader.u16())
        try reader.skip(6)
        var tables: [String: [UInt8]] = [:]
        for _ in 0..<count {
            let tag = try reader.tag()
            _ = try reader.u32()  // checksum: recomputed on write
            let offset = Int(try reader.u32())
            let length = Int(try reader.u32())
            var tableReader = ByteReader(bytes, from: offset, context: "'\(tag)' table")
            tables[tag] = try tableReader.read(length)
        }
        return SFNTFace(sfntVersion: sfntVersion, tables: tables)
    }
}

/// The parts of `fvar` the engine needs: axes and named instances.
struct FvarTable {
    var axes: [VariationAxis]
    var instances: [NamedInstance]

    static func parse(_ table: [UInt8], names: [NameRecord]) throws -> FvarTable {
        var reader = ByteReader(table, context: "fvar")
        guard try reader.u16() == 1 else { throw FontLoadError.unsupported("fvar major version other than 1") }
        try reader.skip(2)  // minor version
        let axesOffset = Int(try reader.u16())
        try reader.skip(2)  // reserved
        let axisCount = Int(try reader.u16())
        let axisSize = Int(try reader.u16())
        let instanceCount = Int(try reader.u16())
        let instanceSize = Int(try reader.u16())
        guard axisSize >= 20, instanceSize >= 4 + 4 * axisCount else {
            throw FontLoadError.malformed("fvar: record sizes \(axisSize)/\(instanceSize) too small")
        }
        func fixed(_ reader: inout ByteReader) throws -> Double { Double(Int32(bitPattern: try reader.u32())) / 65536 }

        var axes: [VariationAxis] = []
        for index in 0..<axisCount {
            try reader.seek(axesOffset + index * axisSize)
            let tag = try reader.tag()
            let minimum = try fixed(&reader)
            let defaultValue = try fixed(&reader)
            let maximum = try fixed(&reader)
            let flags = try reader.u16()
            let nameID = try reader.u16()
            guard minimum <= defaultValue, defaultValue <= maximum else {
                throw FontLoadError.malformed("fvar: axis '\(tag)' has default outside its range")
            }
            axes.append(
                VariationAxis(
                    tag: tag, minimum: minimum, defaultValue: defaultValue, maximum: maximum, hidden: flags & 1 != 0,
                    name: englishName(nameID, in: names)))
        }
        guard Set(axes.map(\.tag)).count == axes.count else {
            throw FontLoadError.malformed("fvar: an axis tag appears twice")
        }
        var instances: [NamedInstance] = []
        let instancesOffset = axesOffset + axisCount * axisSize
        for index in 0..<instanceCount {
            try reader.seek(instancesOffset + index * instanceSize)
            let nameID = try reader.u16()
            try reader.skip(2)  // flags
            var coordinates: [String: Double] = [:]
            for axis in axes { coordinates[axis.tag] = try fixed(&reader) }
            instances.append(NamedInstance(name: englishName(nameID, in: names), coordinates: coordinates))
        }
        return FvarTable(axes: axes, instances: instances)
    }
}

/// Windows US English first, then any record that decodes.
func englishName(_ nameID: UInt16, in records: [NameRecord]) -> String? {
    let candidates = records.filter { $0.nameID == nameID }
    let preferred =
        candidates.first { $0.platformID == 3 && $0.languageID == 0x409 }
        ?? candidates.first { $0.platformID == 1 && $0.languageID == 0 }
    return preferred?.string ?? candidates.lazy.compactMap(\.string).first
}

extension Font {
    /// Every font in a file (several for a .ttc), without converting outlines.
    public static func faces(in bytes: [UInt8]) throws -> [FontFace] {
        let count = try SFNTFile.faceOffsets(bytes).count
        return try (0..<count).map { index in
            let face = try SFNTFile.face(bytes, index: index)
            guard let format = face.outlineFormat else { throw FontLoadError.missingTable("glyf") }
            let names = try face.tables["name"].map { try NameTable.parse($0).records } ?? []
            let fvar = try face.tables["fvar"].map { try FvarTable.parse($0, names: names) }
            return FontFace(
                index: index, outlineFormat: format, fullName: englishName(4, in: names), axes: fvar?.axes ?? [],
                namedInstances: fvar?.instances ?? [])
        }
    }
}
