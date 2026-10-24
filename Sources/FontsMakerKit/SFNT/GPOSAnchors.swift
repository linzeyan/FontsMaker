/// Anchors of GPOS attachment lookups, moved with the outlines that embolden
/// widen shifts (technical design §5.6). An anchor is a point in its glyph's
/// coordinates: when the outline moves right by s, an accent attached at the
/// anchor stays on the letter only if the anchor moves by s too.
///
/// Mark-to-base (4), mark-to-ligature (5), mark-to-mark (6) and cursive (3)
/// lookups hold anchors. A subtable is rewritten whole, because compilers
/// share one anchor table between glyphs (fontTools does): moving it in place
/// would move every glyph that shares it, by the first glyph's shift.
enum GPOSAnchors {
    struct Anchor: Hashable {
        var x: Int16
        var y: Int16
        /// Format 2's contour point. It numbers a point of the source
        /// outline, which embolden replaced, so a moved anchor drops it.
        var point: UInt16?
        /// Format 3's device or variation tables, as bytes.
        var xDevice: [UInt8]
        var yDevice: [UInt8]

        init(_ table: [UInt8], at start: Int) throws {
            var reader = ByteReader(table, from: start, context: "GPOS anchor")
            let format = try reader.u16()
            x = try reader.i16()
            y = try reader.i16()
            point = nil
            xDevice = []
            yDevice = []
            switch format {
            case 1: break
            case 2: point = try reader.u16()
            case 3:
                let xOffset = Int(try reader.u16())
                let yOffset = Int(try reader.u16())
                if xOffset != 0 { xDevice = try GPOSAnchors.device(table, at: start + xOffset) }
                if yOffset != 0 { yDevice = try GPOSAnchors.device(table, at: start + yOffset) }
            default: throw FontLoadError.malformed("GPOS: unknown anchor format \(format)")
            }
        }

        func moved(by shift: Int32) throws -> Anchor {
            guard shift != 0 else { return self }
            guard let movedX = Int16(exactly: Int32(x) + shift) else {
                throw FontWriteError.unencodable("GPOS: anchor x \(x) moved by \(shift) does not fit 16 bits")
            }
            var anchor = self
            anchor.x = movedX
            anchor.point = nil
            return anchor
        }

        /// Self-contained: format 3's device tables follow the anchor.
        var encoded: [UInt8] {
            var writer = ByteWriter()
            if !xDevice.isEmpty || !yDevice.isEmpty {
                writer.u16(3)
                writer.i16(x)
                writer.i16(y)
                writer.u16(xDevice.isEmpty ? 0 : 10)
                writer.u16(yDevice.isEmpty ? 0 : UInt16(10 + xDevice.count))
                writer.append(xDevice)
                writer.append(yDevice)
            } else if let point {
                writer.u16(2)
                writer.i16(x)
                writer.i16(y)
                writer.u16(point)
            } else {
                writer.u16(1)
                writer.i16(x)
                writer.i16(y)
            }
            return writer.bytes
        }
    }

    /// A Device table (sizes 1–3) or VariationIndex table (0x8000), as bytes.
    static func device(_ table: [UInt8], at start: Int) throws -> [UInt8] {
        var reader = ByteReader(table, from: start, context: "GPOS device")
        let startSize = Int(try reader.u16())
        let endSize = Int(try reader.u16())
        let format = try reader.u16()
        let length: Int
        switch format {
        case 1, 2, 3:
            let bits = 1 << Int(format)  // 2, 4 or 8 bits per size
            length = 6 + 2 * ((max(0, endSize - startSize + 1) * bits + 15) / 16)
        case 0x8000:
            length = 6
        default:
            throw FontLoadError.malformed("GPOS: unknown device format \(format)")
        }
        try reader.seek(start)
        return try reader.read(length)
    }

    /// Anchors keyed by the glyph that owns them, in coverage order.
    enum Subtable {
        /// Mark-to-base, -ligature or -mark: the marks' records, and the
        /// records of what they attach to (one per component for ligatures).
        case attachment(
            coverage1: [UInt8], coverage2: [UInt8], classCount: Int, marks: [(UInt16, Anchor)],
            targets: [[[Anchor?]]], ligature: Bool)
        case cursive(coverage: [UInt8], records: [(entry: Anchor?, exit: Anchor?)])
    }

    /// The glyphs whose anchors a subtable holds, with the subtable read.
    static func read(_ table: [UInt8], at start: Int, type: UInt16) throws -> (Subtable, [UInt16], [UInt16]) {
        var reader = ByteReader(table, from: start, context: "GPOS lookup type \(type)")
        let format = try reader.u16()
        guard format == 1 else { throw FontLoadError.malformed("GPOS: lookup type \(type) has format \(format)") }
        if type == 3 {
            let coverageStart = start + Int(try reader.u16())
            let glyphs = try GPOS.coverage(table, at: coverageStart)
            let count = Int(try reader.u16())
            guard count == glyphs.count else { throw FontLoadError.malformed("GPOS: cursive records differ from coverage") }
            var records: [(entry: Anchor?, exit: Anchor?)] = []
            for _ in 0..<count {
                let entry = Int(try reader.u16())
                let exit = Int(try reader.u16())
                records.append(
                    (
                        entry == 0 ? nil : try Anchor(table, at: start + entry),
                        exit == 0 ? nil : try Anchor(table, at: start + exit)
                    ))
            }
            return (.cursive(coverage: try GPOS.coverageBytes(table, at: coverageStart), records: records), glyphs, [])
        }
        let coverage1 = start + Int(try reader.u16())
        let coverage2 = start + Int(try reader.u16())
        let classCount = Int(try reader.u16())
        let markArray = start + Int(try reader.u16())
        let targetArray = start + Int(try reader.u16())
        let markGlyphs = try GPOS.coverage(table, at: coverage1)
        let targetGlyphs = try GPOS.coverage(table, at: coverage2)

        var markReader = ByteReader(table, from: markArray, context: "GPOS MarkArray")
        let markCount = Int(try markReader.u16())
        guard markCount == markGlyphs.count else { throw FontLoadError.malformed("GPOS: MarkArray differs from coverage") }
        var marks: [(UInt16, Anchor)] = []
        for _ in 0..<markCount {
            let markClass = try markReader.u16()
            guard Int(markClass) < classCount else { throw FontLoadError.malformed("GPOS: mark class \(markClass)") }
            marks.append((markClass, try Anchor(table, at: markArray + Int(try markReader.u16()))))
        }

        // Records of `classCount` anchor offsets relative to `base`.
        func anchorRecords(_ reader: inout ByteReader, count: Int, base: Int) throws -> [[Anchor?]] {
            try (0..<count).map { _ in
                try (0..<classCount).map { _ in
                    let offset = Int(try reader.u16())
                    return offset == 0 ? nil : try Anchor(table, at: base + offset)
                }
            }
        }
        var targetReader = ByteReader(table, from: targetArray, context: "GPOS target array")
        let targetCount = Int(try targetReader.u16())
        guard targetCount == targetGlyphs.count else {
            throw FontLoadError.malformed("GPOS: attachment array differs from coverage")
        }
        var targets: [[[Anchor?]]] = []
        if type == 5 {
            for _ in 0..<targetCount {
                let attach = targetArray + Int(try targetReader.u16())
                var attachReader = ByteReader(table, from: attach, context: "GPOS LigatureAttach")
                let components = Int(try attachReader.u16())
                targets.append(try anchorRecords(&attachReader, count: components, base: attach))
            }
        } else {
            targets = try anchorRecords(&targetReader, count: targetCount, base: targetArray).map { [$0] }
        }
        return (
            .attachment(
                coverage1: try GPOS.coverageBytes(table, at: coverage1),
                coverage2: try GPOS.coverageBytes(table, at: coverage2), classCount: classCount, marks: marks,
                targets: targets, ligature: type == 5),
            markGlyphs, targetGlyphs
        )
    }

    /// Anchors after records: each distinct anchor once, at `start` past the
    /// beginning of the block they are counted from.
    private struct AnchorPool {
        var bytes: [UInt8] = []
        var offsets: [Anchor: Int] = [:]
        let start: Int

        init(start: Int) { self.start = start }

        mutating func offset(_ anchor: Anchor?) throws -> UInt16 {
            guard let anchor else { return 0 }
            if let known = offsets[anchor] { return try GPOSAnchors.offset16(known) }
            let position = start + bytes.count
            offsets[anchor] = position
            bytes += anchor.encoded
            return try GPOSAnchors.offset16(position)
        }
    }

    static func offset16(_ value: Int) throws -> UInt16 {
        guard let narrow = UInt16(exactly: value) else {
            throw FontWriteError.unencodable("GPOS: an attachment subtable with moved anchors exceeds 64 KB")
        }
        return narrow
    }

    private static func encode(_ subtable: Subtable) throws -> [UInt8] {
        switch subtable {
        case .cursive(let coverage, let records):
            let coverageStart = 6 + 4 * records.count
            var pool = AnchorPool(start: coverageStart + coverage.count)
            var writer = ByteWriter()
            writer.u16(1)
            writer.u16(try offset16(coverageStart))
            writer.u16(UInt16(records.count))
            for record in records {
                writer.u16(try pool.offset(record.entry))
                writer.u16(try pool.offset(record.exit))
            }
            writer.append(coverage)
            writer.append(pool.bytes)
            return writer.bytes
        case .attachment(let coverage1, let coverage2, let classCount, let marks, let targets, let ligature):
            var markArray = ByteWriter()
            var markPool = AnchorPool(start: 2 + 4 * marks.count)
            markArray.u16(UInt16(marks.count))
            for (markClass, anchor) in marks {
                markArray.u16(markClass)
                markArray.u16(try markPool.offset(anchor))
            }
            markArray.append(markPool.bytes)

            func records(_ records: [[Anchor?]], headerSize: Int) throws -> [UInt8] {
                var pool = AnchorPool(start: headerSize + 2 * classCount * records.count)
                var writer = ByteWriter()
                writer.u16(UInt16(records.count))
                for record in records { for anchor in record { writer.u16(try pool.offset(anchor)) } }
                writer.append(pool.bytes)
                return writer.bytes
            }
            var targetArray = ByteWriter()
            if ligature {
                let attaches = try targets.map { try records($0, headerSize: 2) }
                targetArray.u16(UInt16(attaches.count))
                var next = 2 + 2 * attaches.count
                for attach in attaches {
                    targetArray.u16(try offset16(next))
                    next += attach.count
                }
                for attach in attaches { targetArray.append(attach) }
            } else {
                targetArray.append(try records(targets.map { $0[0] }, headerSize: 2))
            }

            var writer = ByteWriter()
            let coverage1Start = 12
            let coverage2Start = coverage1Start + coverage1.count
            let markArrayStart = coverage2Start + coverage2.count
            let targetArrayStart = markArrayStart + markArray.count
            writer.u16(1)
            writer.u16(try offset16(coverage1Start))
            writer.u16(try offset16(coverage2Start))
            writer.u16(UInt16(classCount))
            writer.u16(try offset16(markArrayStart))
            writer.u16(try offset16(targetArrayStart))
            writer.append(coverage1)
            writer.append(coverage2)
            writer.append(markArray.bytes)
            writer.append(targetArray.bytes)
            return writer.bytes
        }
    }

    /// The GPOS table with every anchor of a glyph in `shifts` moved right by
    /// its shift, and the glyphs whose anchors moved; nil when no anchor
    /// belongs to a shifted glyph, so the table stays byte for byte.
    static func moved(_ table: [UInt8], by shifts: [UInt16: Int32]) throws -> (table: [UInt8], glyphs: Set<UInt16>)? {
        let layout = try GSUBLayout(parsing: table, tag: "GPOS")
        var replacing: [Int: [UInt8]] = [:]
        var movedGlyphs = Set<UInt16>()
        for lookup in layout.lookups where [3, 4, 5, 6].contains(lookup.type) {
            for position in lookup.subtables where replacing[position] == nil {
                let (subtable, firstGlyphs, secondGlyphs) = try read(table, at: position, type: lookup.type)
                let touched = (firstGlyphs + secondGlyphs).filter { (shifts[$0] ?? 0) != 0 }
                guard !touched.isEmpty else { continue }
                movedGlyphs.formUnion(touched)
                func shift(_ glyph: UInt16) -> Int32 { shifts[glyph] ?? 0 }
                let moved: Subtable
                switch subtable {
                case .cursive(let coverage, let records):
                    moved = .cursive(
                        coverage: coverage,
                        records: try zip(firstGlyphs, records).map { glyph, record in
                            (try record.entry?.moved(by: shift(glyph)), try record.exit?.moved(by: shift(glyph)))
                        })
                case .attachment(let coverage1, let coverage2, let classCount, let marks, let targets, let ligature):
                    moved = .attachment(
                        coverage1: coverage1, coverage2: coverage2, classCount: classCount,
                        marks: try zip(firstGlyphs, marks).map { ($1.0, try $1.1.moved(by: shift($0))) },
                        targets: try zip(secondGlyphs, targets).map { glyph, components in
                            try components.map { record in try record.map { try $0?.moved(by: shift(glyph)) } }
                        },
                        ligature: ligature)
                }
                replacing[position] = try encode(moved)
            }
        }
        guard !replacing.isEmpty else { return nil }
        return (try layout.encoded(adding: [], replacing: replacing), movedGlyphs)
    }
}

extension Font {
    /// Moves the GPOS anchors of every glyph in `shifts` with its outline
    /// (`GPOSAnchors`); returns how many glyphs had anchors. A font without
    /// GPOS, or whose shifted glyphs have no anchors, keeps its GPOS bytes.
    func gposWithMovedAnchors(_ shifts: [Int: Int32]) throws -> (table: [UInt8], glyphs: Int)? {
        guard let gpos = tables["GPOS"], !shifts.isEmpty else { return nil }
        var narrow: [UInt16: Int32] = [:]
        for (glyph, shift) in shifts where shift != 0 { narrow[UInt16(glyph)] = shift }
        return try GPOSAnchors.moved(gpos, by: narrow).map { ($0.table, $0.glyphs.count) }
    }
}
