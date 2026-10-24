/// Unicode → glyph mapping (many-to-one: several code points may share a glyph).
public struct CharacterMap: Equatable, Sendable {
    public var mappings: [UInt32: UInt16]
    /// Raw format 14 subtable (Unicode variation sequences). Kept verbatim
    /// because it refers to glyph IDs, which Phase 1 never renumbers.
    public var variationSequences: [UInt8]?

    public init(mappings: [UInt32: UInt16] = [:], variationSequences: [UInt8]? = nil) {
        self.mappings = mappings
        self.variationSequences = variationSequences
    }
}

extension CharacterMap {
    /// Same preference order as fontTools `getBestCmap`, so both sides of the
    /// round-trip comparison read the same subtable.
    private static let unicodePreference: [(platform: UInt16, encoding: UInt16)] = [
        (3, 10), (0, 6), (0, 4), (3, 1), (0, 3), (0, 2), (0, 1), (0, 0),
    ]

    static func parse(_ table: [UInt8], numGlyphs: Int) throws -> CharacterMap {
        var reader = ByteReader(table, context: "cmap")
        _ = try reader.u16()  // version
        let count = Int(try reader.u16())
        var records: [(platform: UInt16, encoding: UInt16, offset: Int)] = []
        for _ in 0..<count {
            records.append((try reader.u16(), try reader.u16(), Int(try reader.u32())))
        }

        var mappings: [UInt32: UInt16]?
        for preferred in unicodePreference {
            guard
                let record = records.first(where: {
                    $0.platform == preferred.platform && $0.encoding == preferred.encoding
                })
            else { continue }
            var sub = ByteReader(table, from: record.offset, context: "cmap")
            switch try sub.u16() {
            case 4: mappings = try parseFormat4(table, at: record.offset, numGlyphs: numGlyphs)
            case 12: mappings = try parseFormat12(table, at: record.offset, numGlyphs: numGlyphs)
            default: continue
            }
            break
        }
        guard let mappings else {
            throw FontLoadError.unsupported("no Unicode cmap subtable in format 4 or 12")
        }

        var variationSequences: [UInt8]?
        if let record = records.first(where: { $0.platform == 0 && $0.encoding == 5 }) {
            var sub = ByteReader(table, from: record.offset, context: "cmap")
            guard try sub.u16() == 14 else {
                throw FontLoadError.malformed("cmap: (0,5) subtable is not format 14")
            }
            let length = Int(try sub.u32())
            try sub.seek(record.offset)
            variationSequences = try sub.read(length)
        }
        return CharacterMap(mappings: mappings, variationSequences: variationSequences)
    }

    private static func parseFormat4(_ table: [UInt8], at start: Int, numGlyphs: Int) throws -> [UInt32: UInt16] {
        var reader = ByteReader(table, from: start, context: "cmap format 4")
        try reader.skip(6)  // format, length, language
        let segCount = Int(try reader.u16()) / 2
        try reader.skip(6)
        let endCodesAt = reader.offset
        let startCodesAt = endCodesAt + 2 * segCount + 2
        let deltasAt = startCodesAt + 2 * segCount
        let rangeOffsetsAt = deltasAt + 2 * segCount

        var mappings: [UInt32: UInt16] = [:]
        for segment in 0..<segCount {
            try reader.seek(endCodesAt + 2 * segment)
            let end = try reader.u16()
            try reader.seek(startCodesAt + 2 * segment)
            let startCode = try reader.u16()
            try reader.seek(deltasAt + 2 * segment)
            let delta = try reader.u16()
            let rangeOffsetPosition = rangeOffsetsAt + 2 * segment
            try reader.seek(rangeOffsetPosition)
            let rangeOffset = Int(try reader.u16())
            guard startCode <= end else { continue }
            for code in UInt32(startCode)...UInt32(end) {
                // U+FFFF is the mandatory terminator segment, not a character.
                if code == 0xFFFF { continue }
                var glyph: UInt16
                if rangeOffset == 0 {
                    glyph = UInt16(truncatingIfNeeded: code) &+ delta
                } else {
                    try reader.seek(rangeOffsetPosition + rangeOffset + 2 * Int(code - UInt32(startCode)))
                    glyph = try reader.u16()
                    if glyph != 0 { glyph = glyph &+ delta }
                }
                if glyph == 0 { continue }
                guard Int(glyph) < numGlyphs else {
                    throw FontLoadError.malformed("cmap: U+\(hex(code)) maps to glyph \(glyph) beyond numGlyphs")
                }
                mappings[code] = glyph
            }
        }
        return mappings
    }

    private static func parseFormat12(_ table: [UInt8], at start: Int, numGlyphs: Int) throws -> [UInt32: UInt16] {
        var reader = ByteReader(table, from: start, context: "cmap format 12")
        try reader.skip(12)  // format, reserved, length, language
        let groupCount = Int(try reader.u32())
        var mappings: [UInt32: UInt16] = [:]
        for _ in 0..<groupCount {
            let first = try reader.u32()
            let last = try reader.u32()
            let startGlyph = try reader.u32()
            guard first <= last, last <= 0x10FFFF else {
                throw FontLoadError.malformed("cmap format 12: invalid group \(first)...\(last)")
            }
            for code in first...last {
                // 64-bit so a hostile startGlyph cannot overflow.
                let glyph = UInt64(startGlyph) + UInt64(code - first)
                if glyph == 0 { continue }
                guard glyph < numGlyphs else {
                    throw FontLoadError.malformed("cmap: U+\(hex(code)) maps to glyph \(glyph) beyond numGlyphs")
                }
                mappings[code] = UInt16(glyph)
            }
        }
        return mappings
    }

    /// Writes (0,3)+(3,1) → one format 4 subtable, (0,4)+(3,10) → one format 12
    /// subtable (only when a code point lies outside the BMP), and (0,5) → the
    /// preserved format 14. All other source subtables (e.g. Mac Roman) are
    /// dropped: every Unicode-aware renderer reads the subtables above.
    func encoded() throws -> [UInt8] {
        let sorted = mappings.sorted { $0.key < $1.key }
        let format4 = try CharacterMap.encodeFormat4(sorted.filter { $0.key <= 0xFFFF })
        let needsFormat12 = sorted.last.map { $0.key > 0xFFFF } ?? false
        let format12 = needsFormat12 ? CharacterMap.encodeFormat12(sorted) : nil

        var subtables: [[UInt8]] = [format4]
        var records: [(platform: UInt16, encoding: UInt16, subtable: Int)] = [(0, 3, 0)]
        if let format12 {
            subtables.append(format12)
            records.append((0, 4, subtables.count - 1))
        }
        if let variationSequences {
            subtables.append(variationSequences)
            records.append((0, 5, subtables.count - 1))
        }
        records.append((3, 1, 0))
        if format12 != nil { records.append((3, 10, 1)) }

        var writer = ByteWriter()
        writer.u16(0)
        writer.u16(UInt16(records.count))
        var subtableOffsets: [Int] = []
        var position = 4 + 8 * records.count
        for subtable in subtables {
            subtableOffsets.append(position)
            position += subtable.count
        }
        for record in records {
            writer.u16(record.platform)
            writer.u16(record.encoding)
            writer.u32(UInt32(subtableOffsets[record.subtable]))
        }
        for subtable in subtables { writer.append(subtable) }
        return writer.bytes
    }

    /// fontTools' segmentation (`splitRange` in fontTools/ttLib/tables/_c_m_a_p.py):
    /// each run of consecutive code points is cut where a long enough stretch
    /// of consecutive glyph IDs can use idDelta instead of glyphIdArray slots.
    /// A segment costs 8 bytes and a slot 2, so a stretch pays off beyond 4
    /// code points at either end of the run and beyond 8 in its middle. CJK
    /// fonts with glyphs in Unicode order shrink the most: Source Han
    /// derivatives would not fit the 64 KiB format otherwise.
    private static func encodeFormat4(_ pairs: [(key: UInt32, value: UInt16)]) throws -> [UInt8] {
        struct Segment {
            var start: UInt16
            var end: UInt16
            var delta: UInt16
            var glyphs: [UInt16]?
        }
        var segments: [Segment] = []
        var index = 0
        while index < pairs.count {
            var last = index
            while last + 1 < pairs.count && pairs[last + 1].key == pairs[last].key + 1 { last += 1 }
            for range in splitRange(pairs[index...last]) {
                let run = pairs[range]
                let first = run.first!
                let delta = first.value &- UInt16(first.key)
                // fontTools compares glyph IDs as integers, without wrapping.
                let consecutive = run.indices.allSatisfy {
                    Int(pairs[$0].value) - Int(first.value) == $0 - range.lowerBound
                }
                segments.append(
                    Segment(
                        start: UInt16(first.key), end: UInt16(run.last!.key),
                        delta: consecutive ? delta : 0,
                        glyphs: consecutive ? nil : run.map(\.value)))
            }
            index = last + 1
        }
        if segments.last?.end != 0xFFFF {
            segments.append(Segment(start: 0xFFFF, end: 0xFFFF, delta: 1, glyphs: nil))
        }

        let segCount = segments.count
        let arrayCount = segments.reduce(0) { $0 + ($1.glyphs?.count ?? 0) }
        let length = 16 + 8 * segCount + 2 * arrayCount
        guard length <= Int(UInt16.max) else {
            throw FontWriteError.unencodable(
                "cmap format 4 subtable needs \(length) bytes, more than the 65535 the format allows")
        }
        var writer = ByteWriter()
        writer.u16(4)
        writer.u16(UInt16(length))
        writer.u16(0)  // language
        let (searchRange, entrySelector, rangeShift) = binarySearchFields(count: segCount, unitSize: 2)
        writer.u16(UInt16(segCount * 2))
        writer.u16(searchRange)
        writer.u16(entrySelector)
        writer.u16(rangeShift)
        for segment in segments { writer.u16(segment.end) }
        writer.u16(0)  // reservedPad
        for segment in segments { writer.u16(segment.start) }
        for segment in segments { writer.u16(segment.delta) }
        var arrayIndex = 0
        for (position, segment) in segments.enumerated() {
            if let glyphs = segment.glyphs {
                // Byte distance from this idRangeOffset entry to its first glyphIdArray slot.
                writer.u16(UInt16(2 * (segCount - position) + 2 * arrayIndex))
                arrayIndex += glyphs.count
            } else {
                writer.u16(0)
            }
        }
        for segment in segments {
            for glyph in segment.glyphs ?? [] { writer.u16(glyph) }
        }
        return writer.bytes
    }

    /// Index ranges of `run` (consecutive code points) that become one
    /// segment each, in order and covering the run.
    private static func splitRange(_ run: ArraySlice<(key: UInt32, value: UInt16)>) -> [ClosedRange<Int>] {
        let whole = [run.startIndex...(run.endIndex - 1)]
        guard run.count > 1 else { return whole }
        // Stretches of consecutive glyph IDs, as index ranges.
        var ordered: [ClosedRange<Int>] = []
        var orderedBegin: Int?
        for index in run.indices.dropFirst() {
            if Int(run[index].value) - 1 == Int(run[index - 1].value) {
                if orderedBegin == nil { orderedBegin = index - 1 }
            } else if let begin = orderedBegin {
                ordered.append(begin...(index - 1))
                orderedBegin = nil
            }
        }
        if let begin = orderedBegin { ordered.append(begin...(run.endIndex - 1)) }

        let first = run.startIndex
        let last = run.endIndex - 1
        var kept: [ClosedRange<Int>] = []
        for stretch in ordered {
            if stretch.lowerBound == first && stretch.upperBound == last { break }  // one delta segment already
            let threshold = stretch.lowerBound == first || stretch.upperBound == last ? 4 : 8
            if stretch.count > threshold { kept.append(stretch) }
        }
        guard !kept.isEmpty else { return whole }

        // The stretches, with the glyphIdArray segments between them.
        var ranges: [ClosedRange<Int>] = []
        var next = first
        for stretch in kept {
            if stretch.lowerBound > next { ranges.append(next...(stretch.lowerBound - 1)) }
            ranges.append(stretch)
            next = stretch.upperBound + 1
        }
        if next <= last { ranges.append(next...last) }
        return ranges
    }

    private static func encodeFormat12(_ pairs: [(key: UInt32, value: UInt16)]) -> [UInt8] {
        var groups: [(first: UInt32, last: UInt32, glyph: UInt32)] = []
        for pair in pairs {
            if let previous = groups.last, previous.last + 1 == pair.key,
                previous.glyph + (pair.key - previous.first) == UInt32(pair.value)
            {
                groups[groups.count - 1].last = pair.key
            } else {
                groups.append((pair.key, pair.key, UInt32(pair.value)))
            }
        }
        var writer = ByteWriter()
        writer.u16(12)
        writer.u16(0)
        writer.u32(UInt32(16 + 12 * groups.count))
        writer.u32(0)  // language
        writer.u32(UInt32(groups.count))
        for group in groups {
            writer.u32(group.first)
            writer.u32(group.last)
            writer.u32(group.glyph)
        }
        return writer.bytes
    }
}

/// searchRange / entrySelector / rangeShift as used by the sfnt header and cmap format 4.
func binarySearchFields(count: Int, unitSize: Int) -> (UInt16, UInt16, UInt16) {
    var power = 1
    var log = 0
    while power * 2 <= count {
        power *= 2
        log += 1
    }
    let searchRange = power * unitSize
    return (UInt16(searchRange), UInt16(log), UInt16(count * unitSize - searchRange))
}

func hex(_ code: UInt32) -> String {
    let digits = String(code, radix: 16, uppercase: true)
    return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
}
