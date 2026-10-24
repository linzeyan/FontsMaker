/// The parts of GPOS the engine reads and writes (technical design §4.3):
/// pair kerning, for the glyphs replace copies from a second font (§5.7), and
/// the anchors of mark and cursive attachment, which follow the outlines
/// embolden widen moves (§5.6, `GPOSAnchors`). Everything else in GPOS is
/// carried over as it is, through `GSUBLayout` with tag "GPOS".
enum GPOS {
    /// A ValueRecord's coordinates. Device and variation offsets are left
    /// out: they adjust for hinted sizes or variation instances, neither of
    /// which survives the engine's outline operations (design D5, §4.1).
    struct Value: Hashable, Sendable {
        var xPlacement = 0
        var yPlacement = 0
        var xAdvance = 0
        var yAdvance = 0

        var isZero: Bool { xPlacement == 0 && yPlacement == 0 && xAdvance == 0 && yAdvance == 0 }

        static func + (lhs: Value, rhs: Value) -> Value {
            Value(
                xPlacement: lhs.xPlacement + rhs.xPlacement, yPlacement: lhs.yPlacement + rhs.yPlacement,
                xAdvance: lhs.xAdvance + rhs.xAdvance, yAdvance: lhs.yAdvance + rhs.yAdvance)
        }

        /// Scaled and rounded as the copied glyphs' coordinates are (otRound).
        func scaled(_ scale: Double) -> Value {
            func round(_ value: Int) -> Int { Int((Double(value) * scale + 0.5).rounded(.down)) }
            return Value(
                xPlacement: round(xPlacement), yPlacement: round(yPlacement), xAdvance: round(xAdvance),
                yAdvance: round(yAdvance))
        }

        /// The ValueFormat bits of the fields that are not zero.
        var format: UInt16 {
            (xPlacement != 0 ? 0x1 : 0) | (yPlacement != 0 ? 0x2 : 0) | (xAdvance != 0 ? 0x4 : 0)
                | (yAdvance != 0 ? 0x8 : 0)
        }
    }

    /// The adjustments a pair lookup makes to the first and the second glyph.
    struct PairAdjustment: Equatable, Sendable {
        var first = Value()
        var second = Value()

        var isZero: Bool { first.isZero && second.isZero }

        static func + (lhs: PairAdjustment, rhs: PairAdjustment) -> PairAdjustment {
            PairAdjustment(first: lhs.first + rhs.first, second: lhs.second + rhs.second)
        }
    }

    struct GlyphPair: Hashable, Sendable {
        var left: UInt16
        var right: UInt16
    }

    // MARK: Primitives

    /// Covered glyphs in coverage-index order.
    static func coverage(_ table: [UInt8], at start: Int) throws -> [UInt16] {
        var reader = ByteReader(table, from: start, context: "GPOS coverage")
        let format = try reader.u16()
        let count = Int(try reader.u16())
        switch format {
        case 1:
            return try (0..<count).map { _ in try reader.u16() }
        case 2:
            var glyphs: [UInt16] = []
            for _ in 0..<count {
                let first = try reader.u16()
                let last = try reader.u16()
                let startIndex = Int(try reader.u16())
                guard first <= last, startIndex == glyphs.count else {
                    throw FontLoadError.malformed("GPOS: coverage ranges out of order")
                }
                glyphs.append(contentsOf: first...last)
            }
            return glyphs
        default:
            throw FontLoadError.malformed("GPOS: unknown coverage format \(format)")
        }
    }

    /// The bytes of the coverage table at `start`, for copying it unchanged.
    static func coverageBytes(_ table: [UInt8], at start: Int) throws -> [UInt8] {
        var reader = ByteReader(table, from: start, context: "GPOS coverage")
        let format = try reader.u16()
        let count = Int(try reader.u16())
        guard format == 1 || format == 2 else { throw FontLoadError.malformed("GPOS: unknown coverage format \(format)") }
        try reader.seek(start)
        return try reader.read(4 + (format == 1 ? 2 : 6) * count)
    }

    /// Glyph → class; glyphs not listed are class 0.
    static func classDefinition(_ table: [UInt8], at start: Int) throws -> [UInt16: UInt16] {
        var reader = ByteReader(table, from: start, context: "GPOS ClassDef")
        let format = try reader.u16()
        var classes: [UInt16: UInt16] = [:]
        switch format {
        case 1:
            let first = try reader.u16()
            let count = Int(try reader.u16())
            for index in 0..<count {
                let value = try reader.u16()
                guard let glyph = UInt16(exactly: Int(first) + index) else {
                    throw FontLoadError.malformed("GPOS: ClassDef past glyph 65535")
                }
                classes[glyph] = value
            }
        case 2:
            let count = Int(try reader.u16())
            for _ in 0..<count {
                let first = try reader.u16()
                let last = try reader.u16()
                let value = try reader.u16()
                guard first <= last else { throw FontLoadError.malformed("GPOS: inverted ClassDef range") }
                for glyph in first...last { classes[glyph] = value }
            }
        default:
            throw FontLoadError.malformed("GPOS: unknown ClassDef format \(format)")
        }
        return classes
    }

    /// Bytes of a ValueRecord in `format`: two per field, offsets included.
    static func valueSize(_ format: UInt16) -> Int { 2 * (format & 0xFF).nonzeroBitCount }

    static func readValue(_ reader: inout ByteReader, format: UInt16) throws -> Value {
        var value = Value()
        if format & 0x1 != 0 { value.xPlacement = Int(try reader.i16()) }
        if format & 0x2 != 0 { value.yPlacement = Int(try reader.i16()) }
        if format & 0x4 != 0 { value.xAdvance = Int(try reader.i16()) }
        if format & 0x8 != 0 { value.yAdvance = Int(try reader.i16()) }
        try reader.skip(2 * (format & 0xF0).nonzeroBitCount)
        return value
    }

    static func writeValue(_ value: Value, format: UInt16, to writer: inout ByteWriter) throws {
        func field(_ number: Int) throws -> Int16 {
            guard let narrow = Int16(exactly: number) else {
                throw FontWriteError.unencodable("GPOS: kerning value \(number) does not fit 16 bits")
            }
            return narrow
        }
        if format & 0x1 != 0 { writer.i16(try field(value.xPlacement)) }
        if format & 0x2 != 0 { writer.i16(try field(value.yPlacement)) }
        if format & 0x4 != 0 { writer.i16(try field(value.xAdvance)) }
        if format & 0x8 != 0 { writer.i16(try field(value.yAdvance)) }
    }
}

// MARK: - Kerning

extension GPOS {
    /// The lookups of the `kern` feature a shaper applies to Latin text:
    /// those of the `latn` script's default language system, else `DFLT`'s,
    /// else the first script's; nil when the font has no `kern` feature.
    /// One language system rather than every `kern` feature in the font:
    /// fonts give scripts features of their own that repeat the same pairs,
    /// and adding them up would kern those pairs twice.
    static func kernLookups(_ layout: GSUBLayout) -> [Int]? {
        let ordered =
            layout.scripts.filter { $0.tag == "latn" } + layout.scripts.filter { $0.tag == "DFLT" } + layout.scripts
        for script in ordered {
            guard let langSys = script.defaultLangSys ?? script.languages.first?.langSys else { continue }
            if let feature = langSys.features.first(where: { layout.features[Int($0)].tag == "kern" }) {
                return layout.features[Int(feature)].lookups.map(Int.init).sorted()
            }
        }
        return nil
    }

    /// What the `kern` feature does between any two glyphs of `glyphs`, as a
    /// shaper applies it: lookups in lookup-list order, each adding what its
    /// first matching subtable gives (a format 1 subtable matches when it
    /// lists the pair, a format 2 one as soon as it covers the first glyph,
    /// OpenType's rule). Only pair adjustment (type 2) is read; nil when the
    /// font has no `kern` feature.
    static func kerning(_ table: [UInt8], among glyphs: Set<UInt16>) throws -> [GlyphPair: PairAdjustment]? {
        let layout = try GSUBLayout(parsing: table, tag: "GPOS")
        guard let lookups = kernLookups(layout) else { return nil }
        let lefts = glyphs.sorted()
        var result: [GlyphPair: PairAdjustment] = [:]
        var parsed: [Int: PairSubtable] = [:]
        for lookupIndex in lookups where layout.lookups[lookupIndex].type == 2 {
            let subtables = try layout.lookups[lookupIndex].subtables.map { position in
                if let known = parsed[position] { return known }
                let subtable = try PairSubtable(table, at: position)
                parsed[position] = subtable
                return subtable
            }
            for left in lefts {
                var pending = glyphs
                for subtable in subtables where !pending.isEmpty {
                    for (right, adjustment) in try subtable.adjustments(left: left, rights: &pending, in: table)
                    where !adjustment.isZero {
                        result[GlyphPair(left: left, right: right), default: PairAdjustment()] =
                            result[GlyphPair(left: left, right: right), default: PairAdjustment()] + adjustment
                    }
                }
            }
        }
        return result.filter { !$0.value.isZero }
    }

    /// One PairPos subtable, read as far as finding a pair needs.
    private enum PairSubtable {
        case glyphs(coverage: [UInt16: Int], valueFormats: (UInt16, UInt16), pairSets: [Int])
        case classes(
            coverage: Set<UInt16>, valueFormats: (UInt16, UInt16), first: [UInt16: UInt16], second: [UInt16: UInt16],
            class2Count: Int, records: Int, class1Count: Int)

        init(_ table: [UInt8], at start: Int) throws {
            var reader = ByteReader(table, from: start, context: "GPOS PairPos")
            let format = try reader.u16()
            let covered = try GPOS.coverage(table, at: start + Int(try reader.u16()))
            let formats = (try reader.u16(), try reader.u16())
            switch format {
            case 1:
                let count = Int(try reader.u16())
                guard count == covered.count else { throw FontLoadError.malformed("GPOS: PairSet count differs from coverage") }
                let sets = try (0..<count).map { _ in start + Int(try reader.u16()) }
                var index: [UInt16: Int] = [:]
                for (position, glyph) in covered.enumerated() where index[glyph] == nil { index[glyph] = position }
                self = .glyphs(coverage: index, valueFormats: formats, pairSets: sets)
            case 2:
                let first = try GPOS.classDefinition(table, at: start + Int(try reader.u16()))
                let second = try GPOS.classDefinition(table, at: start + Int(try reader.u16()))
                let class1Count = Int(try reader.u16())
                let class2Count = Int(try reader.u16())
                self = .classes(
                    coverage: Set(covered), valueFormats: formats, first: first, second: second,
                    class2Count: class2Count, records: reader.offset, class1Count: class1Count)
            default:
                throw FontLoadError.malformed("GPOS: unknown PairPos format \(format)")
            }
        }

        /// The adjustments this subtable makes for `left` followed by any of
        /// `rights`; the glyphs it matched leave `rights`, so a later subtable
        /// of the same lookup does not apply to them.
        func adjustments(left: UInt16, rights: inout Set<UInt16>, in table: [UInt8]) throws
            -> [(UInt16, PairAdjustment)]
        {
            switch self {
            case .glyphs(let coverage, let formats, let pairSets):
                guard let index = coverage[left] else { return [] }
                var reader = ByteReader(table, from: pairSets[index], context: "GPOS PairSet")
                let count = Int(try reader.u16())
                var found: [(UInt16, PairAdjustment)] = []
                for _ in 0..<count {
                    let right = try reader.u16()
                    let adjustment = PairAdjustment(
                        first: try GPOS.readValue(&reader, format: formats.0),
                        second: try GPOS.readValue(&reader, format: formats.1))
                    if rights.remove(right) != nil { found.append((right, adjustment)) }
                }
                return found
            case .classes(let coverage, let formats, let first, let second, let class2Count, let records, let class1Count):
                guard coverage.contains(left) else { return [] }
                let class1 = Int(first[left] ?? 0)
                let recordSize = GPOS.valueSize(formats.0) + GPOS.valueSize(formats.1)
                var found: [(UInt16, PairAdjustment)] = []
                for right in rights.sorted() {
                    let class2 = Int(second[right] ?? 0)
                    guard class1 < class1Count, class2 < class2Count else { continue }
                    var reader = ByteReader(
                        table, from: records + (class1 * class2Count + class2) * recordSize, context: "GPOS Class2Record")
                    found.append(
                        (
                            right,
                            PairAdjustment(
                                first: try GPOS.readValue(&reader, format: formats.0),
                                second: try GPOS.readValue(&reader, format: formats.1))
                        ))
                }
                rights.removeAll()
                return found
            }
        }
    }

    /// Horizontal pairs of a `kern` table (the Windows version 0 and the
    /// Apple version 1 header, format 0 subtables): the first glyph's
    /// advance changes by the value. Cross-stream, vertical and minimum
    /// subtables, and other formats, are not kerning a shaper adds to the
    /// advance, so they are left out. `glyphs` nil keeps every pair.
    static func legacyKerning(_ table: [UInt8], among glyphs: Set<UInt16>?) throws -> [GlyphPair: Int] {
        var reader = ByteReader(table, context: "kern")
        var result: [GlyphPair: Int] = [:]
        let apple = try reader.u16() == 1
        let count: Int
        if apple {
            _ = try reader.u16()
            count = Int(try reader.u32())
        } else {
            count = Int(try reader.u16())
        }
        for _ in 0..<count {
            let start = reader.offset
            let length: Int
            let format: UInt16
            let horizontal: Bool
            let override: Bool
            if apple {
                length = Int(try reader.u32())
                let coverage = try reader.u16()
                _ = try reader.u16()  // tupleIndex
                format = coverage & 0xFF
                horizontal = coverage & 0xE000 == 0  // not vertical, cross-stream or variation
                override = false
            } else {
                _ = try reader.u16()  // subtable version
                length = Int(try reader.u16())
                let coverage = try reader.u16()
                format = coverage >> 8
                horizontal = coverage & 0x7 == 0x1  // horizontal, not minimum, not cross-stream
                override = coverage & 0x8 != 0
            }
            guard format == 0 else {
                guard length > 0 else { throw FontLoadError.malformed("kern: subtable of length 0") }
                try reader.seek(start + length)
                continue
            }
            // A format 0 subtable ends after its pairs. Its 16-bit length
            // field (Windows) overflows on large tables, so it is not used.
            let pairs = Int(try reader.u16())
            try reader.skip(6)
            for _ in 0..<pairs {
                let pair = GlyphPair(left: try reader.u16(), right: try reader.u16())
                let value = Int(try reader.i16())
                guard horizontal, glyphs.map({ $0.contains(pair.left) && $0.contains(pair.right) }) ?? true else {
                    continue
                }
                result[pair] = override ? value : (result[pair] ?? 0) + value
            }
        }
        return result.filter { $0.value != 0 }
    }

    /// PairPos format 1 subtables for `pairs`, split by first glyph so each
    /// stays within the 16-bit offsets. The value formats hold exactly the
    /// fields some pair uses.
    static func pairSubtables(_ pairs: [GlyphPair: PairAdjustment]) throws -> [[UInt8]] {
        var byLeft: [UInt16: [(UInt16, PairAdjustment)]] = [:]
        var format1: UInt16 = 0
        var format2: UInt16 = 0
        for (pair, adjustment) in pairs {
            byLeft[pair.left, default: []].append((pair.right, adjustment))
            format1 |= adjustment.first.format
            format2 |= adjustment.second.format
        }
        let recordSize = 2 + valueSize(format1) + valueSize(format2)
        var chunks: [[UInt16]] = []
        var size = 0
        for left in byLeft.keys.sorted() {
            // Per first glyph: its PairSet offset, coverage entry, PairSet.
            let cost = 2 + 2 + 2 + recordSize * byLeft[left]!.count
            guard 10 + 4 + cost <= Int(UInt16.max) else {
                throw FontWriteError.unencodable("GPOS: glyph \(left) has too many kerning pairs")
            }
            if chunks.isEmpty || size + cost > Int(UInt16.max) {
                chunks.append([])
                size = 10 + 4
            }
            chunks[chunks.count - 1].append(left)
            size += cost
        }
        return try chunks.map { lefts in
            let coverageStart = 10 + 2 * lefts.count
            var next = coverageStart + 4 + 2 * lefts.count
            var writer = ByteWriter()
            writer.u16(1)
            writer.u16(UInt16(coverageStart))
            writer.u16(format1)
            writer.u16(format2)
            writer.u16(UInt16(lefts.count))
            for left in lefts {
                writer.u16(UInt16(next))
                next += 2 + recordSize * byLeft[left]!.count
            }
            writer.u16(1)
            writer.u16(UInt16(lefts.count))
            for left in lefts { writer.u16(left) }
            for left in lefts {
                let records = byLeft[left]!.sorted { $0.0 < $1.0 }
                writer.u16(UInt16(records.count))
                for (right, adjustment) in records {
                    writer.u16(right)
                    try writeValue(adjustment.first, format: format1, to: &writer)
                    try writeValue(adjustment.second, format: format2, to: &writer)
                }
            }
            return writer.bytes
        }
    }
}
