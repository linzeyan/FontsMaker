import Foundation

public struct WriteOptions: Equatable, Sendable {
    /// The "outline modified" policy (technical design D5): once outlines
    /// change, TrueType instructions are wrong, so all hinting is removed.
    public var stripHinting: Bool

    public init(stripHinting: Bool = false) {
        self.stripHinting = stripHinting
    }
}

extension Font {
    /// Tables whose content depends on hinting or on the original outlines'
    /// rasterization; dropped together with glyph instructions.
    static let hintingTables: Set<String> = ["fpgm", "prep", "cvt ", "hdmx", "LTSH", "VDMX"]

    /// Tables regenerated from the model; never copied from the source bytes.
    static let rebuiltTables: Set<String> = ["head", "hhea", "maxp", "OS/2", "hmtx", "loca", "glyf", "cmap", "name"]

    /// Recommended TrueType table data order; remaining tables follow sorted by tag.
    static let preferredTableOrder = [
        "head", "hhea", "maxp", "OS/2", "hmtx", "LTSH", "VDMX", "hdmx", "cmap", "fpgm", "prep", "cvt ",
        "loca", "glyf", "kern", "name", "post", "gasp", "PCLT",
    ]

    /// Serializes the font. The output depends only on the model and options:
    /// no clock, no hash-order iteration, so equal input gives equal bytes.
    public func write(options: WriteOptions = WriteOptions()) throws -> Data {
        Data(try serialize(options: options))
    }

    func serialize(options: WriteOptions) throws -> [UInt8] {
        // Writing now would drop the half of s2t `phrases` that lives in GSUB.
        guard phrasePlan == nil else {
            throw FontWriteError.unencodable("s2t phrases: the phrase rules were never added to GSUB")
        }
        let numGlyphs = glyphs.count
        guard numGlyphs <= Int(UInt16.max) else {
            throw FontWriteError.unencodable("\(numGlyphs) glyphs; TrueType allows at most 65535")
        }
        guard horizontalMetrics.count == numGlyphs else {
            throw FontWriteError.unencodable(
                "glyph count \(numGlyphs) and horizontal metrics count \(horizontalMetrics.count) disagree")
        }
        if let verticalMetrics, verticalMetrics.count != numGlyphs {
            throw FontWriteError.unencodable(
                "glyph count \(numGlyphs) and vertical metrics count \(verticalMetrics.count) disagree")
        }
        let glyphData = try encodeGlyphs(keepInstructions: !options.stripHinting)
        var output: [String: [UInt8]] = [:]

        // DSIG signs the source bytes; any rewrite invalidates it.
        let dropped = options.stripHinting ? Font.hintingTables.union(["DSIG"]) : ["DSIG"]
        for (tag, data) in tables where !dropped.contains(tag) && !Font.rebuiltTables.contains(tag) {
            output[tag] = data
        }
        output["glyf"] = glyphData.glyf
        output["loca"] = glyphData.loca
        output["head"] = try patchedHead(glyphData)
        output["maxp"] = try patchedMaxp(stripHinting: options.stripHinting)
        let (hmtx, numberOfHMetrics) = encodeHorizontalMetrics(glyphData.bounds)
        output["hmtx"] = hmtx
        output["hhea"] = try patchedHhea(glyphData.bounds, numberOfHMetrics: numberOfHMetrics)
        output["cmap"] = try characterMap.encoded()
        output["name"] = try NameTable(records: names, languageTags: nameLanguageTags).encoded()
        if var os2Table = tables["OS/2"], var os2 {
            if winCoversGlyphs {
                let ys = glyphData.bounds.compactMap { $0 }
                os2.cover(ys.isEmpty ? nil : (ys.map(\.yMax).max()!, ys.map(\.yMin).min()!))
            }
            os2Table.writeU16(os2.version, at: 0)
            os2Table.writeI16(os2.xAvgCharWidth, at: 2)
            os2Table.writeU16(os2.weightClass, at: 4)
            os2Table.writeU16(os2.fsSelection, at: 62)
            if let typoAscender = os2.typoAscender { os2Table.writeI16(typoAscender, at: 68) }
            if let typoDescender = os2.typoDescender { os2Table.writeI16(typoDescender, at: 70) }
            if let typoLineGap = os2.typoLineGap { os2Table.writeI16(typoLineGap, at: 72) }
            if let winAscent = os2.winAscent { os2Table.writeU16(winAscent, at: 74) }
            if let winDescent = os2.winDescent { os2Table.writeU16(winDescent, at: 76) }
            output["OS/2"] = os2Table
        }
        if let verticalMetrics, var vhea = tables["vhea"] {
            let (vmtx, numberOfLongMetrics) = encodeVerticalMetrics(verticalMetrics)
            output["vmtx"] = vmtx
            vhea.writeU16(UInt16(numberOfLongMetrics), at: 34)
            output["vhea"] = vhea
        }
        // Format 2 names glyphs by index; once glyphs are added the name array
        // no longer matches numGlyphs. Format 3 (no names) is valid for any count.
        if var post = tables["post"], post.count >= 32, numGlyphs != Int(tables["maxp"]!.readU16(at: 4)) {
            post = Array(post.prefix(32))
            post.writeU32(0x0003_0000, at: 0)
            output["post"] = post
        }
        return Font.assemble(output, sfntVersion: sfntVersion)
    }

    // MARK: glyf / loca

    struct EncodedGlyphs {
        var glyf: [UInt8]
        var loca: [UInt8]
        var longLoca: Bool
        /// Per glyph; nil when the (flattened) glyph has no points.
        var bounds: [BoundingBox?]
    }

    private func encodeGlyphs(keepInstructions: Bool) throws -> EncodedGlyphs {
        var glyf: [UInt8] = []
        var offsets: [Int] = [0]
        var bounds: [BoundingBox?] = []
        bounds.reserveCapacity(glyphs.count)
        for (glyphID, glyph) in glyphs.enumerated() {
            let box: BoundingBox?
            switch glyph.outline {
            case .simple(let simple): box = BoundingBox(simple.points)
            case .composite: box = BoundingBox(try flattenedOutline(of: glyphID).rounded().points)
            }
            bounds.append(box)
            glyf.append(
                contentsOf: try glyph.encoded(bounds: box, keepInstructions: keepInstructions, glyphID: glyphID))
            // 4-byte alignment keeps every offset even, so short loca stays possible.
            while glyf.count % 4 != 0 { glyf.append(0) }
            offsets.append(glyf.count)
        }
        // Short loca stores offset/2 in 16 bits.
        let longLoca = glyf.count > 0x1FFFE
        var loca = ByteWriter()
        for offset in offsets {
            if longLoca {
                loca.u32(UInt32(offset))
            } else {
                loca.u16(UInt16(offset / 2))
            }
        }
        return EncodedGlyphs(glyf: glyf, loca: loca.bytes, longLoca: longLoca, bounds: bounds)
    }

    // MARK: head / hhea / hmtx / maxp

    private func patchedHead(_ glyphData: EncodedGlyphs) throws -> [UInt8] {
        // Only bbox, loca format and the checksum change; created/modified stay
        // as in the source so the output carries no wall-clock time (§8).
        var head = tables["head"]!
        let box = glyphData.bounds.compactMap { $0 }.reduce(nil as BoundingBox?) { $0?.union($1) ?? $1 } ?? .zero
        head.writeU32(0, at: 8)  // checkSumAdjustment, filled in by assemble()
        head.writeI16(try checkedInt16(box.xMin, "head xMin"), at: 36)
        head.writeI16(try checkedInt16(box.yMin, "head yMin"), at: 38)
        head.writeI16(try checkedInt16(box.xMax, "head xMax"), at: 40)
        head.writeI16(try checkedInt16(box.yMax, "head yMax"), at: 42)
        head.writeU16(macStyle, at: 44)
        head.writeI16(glyphData.longLoca ? 1 : 0, at: 50)
        return head
    }

    /// Writes advance + lsb pairs, collapsing the trailing run of equal
    /// advances into lsb-only entries. lsb is the glyph's xMin whenever it has points.
    private func encodeHorizontalMetrics(_ bounds: [BoundingBox?]) -> ([UInt8], Int) {
        var numberOfHMetrics = horizontalMetrics.count
        let lastAdvance = horizontalMetrics.last?.advanceWidth
        while numberOfHMetrics > 1 && horizontalMetrics[numberOfHMetrics - 2].advanceWidth == lastAdvance {
            numberOfHMetrics -= 1
        }
        var writer = ByteWriter()
        for (glyphID, metric) in horizontalMetrics.enumerated() {
            let lsb = bounds[glyphID].map { Int16(truncatingIfNeeded: $0.xMin) } ?? metric.leftSideBearing
            if glyphID < numberOfHMetrics { writer.u16(metric.advanceWidth) }
            writer.i16(lsb)
        }
        return (writer.bytes, numberOfHMetrics)
    }

    /// Same trailing-run compaction as hmtx; top side bearings are kept as stored.
    private func encodeVerticalMetrics(_ metrics: [VerticalMetric]) -> ([UInt8], Int) {
        var numberOfLongMetrics = metrics.count
        let lastAdvance = metrics.last?.advanceHeight
        while numberOfLongMetrics > 1 && metrics[numberOfLongMetrics - 2].advanceHeight == lastAdvance {
            numberOfLongMetrics -= 1
        }
        var writer = ByteWriter()
        for (glyphID, metric) in metrics.enumerated() {
            if glyphID < numberOfLongMetrics { writer.u16(metric.advanceHeight) }
            writer.i16(metric.topSideBearing)
        }
        return (writer.bytes, numberOfLongMetrics)
    }

    private func patchedHhea(_ bounds: [BoundingBox?], numberOfHMetrics: Int) throws -> [UInt8] {
        var hhea = tables["hhea"]!
        var minLeft = Int32.max
        var minRight = Int32.max
        var maxExtent = Int32.min
        for (glyphID, box) in bounds.enumerated() {
            guard let box else { continue }
            let advance = Int32(horizontalMetrics[glyphID].advanceWidth)
            minLeft = min(minLeft, box.xMin)
            minRight = min(minRight, advance - box.xMax)
            maxExtent = max(maxExtent, box.xMax)
        }
        if maxExtent == Int32.min { (minLeft, minRight, maxExtent) = (0, 0, 0) }
        hhea.writeI16(self.hhea.ascender, at: 4)
        hhea.writeI16(self.hhea.descender, at: 6)
        hhea.writeI16(self.hhea.lineGap, at: 8)
        hhea.writeU16(horizontalMetrics.map(\.advanceWidth).max() ?? 0, at: 10)
        hhea.writeI16(try checkedInt16(minLeft, "hhea minLeftSideBearing"), at: 12)
        hhea.writeI16(try checkedInt16(minRight, "hhea minRightSideBearing"), at: 14)
        hhea.writeI16(try checkedInt16(maxExtent, "hhea xMaxExtent"), at: 16)
        hhea.writeU16(UInt16(numberOfHMetrics), at: 34)
        return hhea
    }

    /// Point/contour/component limits are recomputed from the glyphs. The
    /// hinting limits (maxZones…maxSizeOfInstructions) describe the font
    /// program, which the engine cannot analyze: kept from the source, or
    /// reset to their minimum when hinting is stripped.
    private func patchedMaxp(stripHinting: Bool) throws -> [UInt8] {
        var maxp = tables["maxp"]!
        var maxPoints = 0
        var maxContours = 0
        var maxCompositePoints = 0
        var maxCompositeContours = 0
        var maxComponentElements = 0
        var maxComponentDepth = 0
        var depthCache: [Int: Int] = [:]
        for (glyphID, glyph) in glyphs.enumerated() {
            switch glyph.outline {
            case .simple(let simple):
                maxPoints = max(maxPoints, simple.points.count)
                maxContours = max(maxContours, simple.endPoints.count)
            case .composite(let components):
                let flat = try flattenedOutline(of: glyphID)
                maxCompositePoints = max(maxCompositePoints, flat.xs.count)
                maxCompositeContours = max(maxCompositeContours, flat.endPoints.count)
                maxComponentElements = max(maxComponentElements, components.count)
                maxComponentDepth = max(maxComponentDepth, componentDepth(glyphID, cache: &depthCache))
            }
        }
        func field(_ value: Int, _ name: String) throws -> UInt16 {
            guard let narrow = UInt16(exactly: value) else {
                throw FontWriteError.unencodable("maxp \(name) \(value) exceeds 65535")
            }
            return narrow
        }
        maxp.writeU16(UInt16(glyphs.count), at: 4)
        maxp.writeU16(try field(maxPoints, "maxPoints"), at: 6)
        maxp.writeU16(try field(maxContours, "maxContours"), at: 8)
        maxp.writeU16(try field(maxCompositePoints, "maxCompositePoints"), at: 10)
        maxp.writeU16(try field(maxCompositeContours, "maxCompositeContours"), at: 12)
        if stripHinting {
            // maxZones must be 1 or 2; 1 means "no twilight zone".
            maxp.writeU16(1, at: 14)
            for offset in stride(from: 16, through: 26, by: 2) { maxp.writeU16(0, at: offset) }
        }
        maxp.writeU16(try field(maxComponentElements, "maxComponentElements"), at: 28)
        maxp.writeU16(try field(maxComponentDepth, "maxComponentDepth"), at: 30)
        return maxp
    }

    /// 1 for a composite of simple glyphs, +1 per nested composite level
    /// (the convention fontTools and FontForge use).
    private func componentDepth(_ glyphID: Int, cache: inout [Int: Int]) -> Int {
        if let known = cache[glyphID] { return known }
        guard case .composite(let components) = glyphs[glyphID].outline else { return 0 }
        cache[glyphID] = 1  // provisional; cycles are rejected by flattenedOutline first
        var deepest = 0
        for component in components {
            deepest = max(deepest, componentDepth(Int(component.glyphID), cache: &cache))
        }
        cache[glyphID] = deepest + 1
        return deepest + 1
    }

    // MARK: sfnt assembly

    static func assemble(_ tables: [String: [UInt8]], sfntVersion: UInt32) -> [UInt8] {
        let directoryOrder = tables.keys.sorted(by: tagPrecedes)
        let dataOrder =
            preferredTableOrder.filter { tables[$0] != nil }
            + directoryOrder.filter { !preferredTableOrder.contains($0) }

        var offset = 12 + 16 * tables.count
        var offsets: [String: Int] = [:]
        for tag in dataOrder {
            offsets[tag] = offset
            offset += (tables[tag]!.count + 3) / 4 * 4
        }

        var writer = ByteWriter()
        writer.u32(sfntVersion)
        let (searchRange, entrySelector, rangeShift) = binarySearchFields(count: tables.count, unitSize: 16)
        writer.u16(UInt16(tables.count))
        writer.u16(searchRange)
        writer.u16(entrySelector)
        writer.u16(rangeShift)
        for tag in directoryOrder {
            let data = tables[tag]!
            writer.append(Array(tag.utf8))
            writer.u32(tableChecksum(data))
            writer.u32(UInt32(offsets[tag]!))
            writer.u32(UInt32(data.count))
        }
        for tag in dataOrder {
            writer.append(tables[tag]!)
            writer.padToFourBytes()
        }
        var font = writer.bytes
        if let headOffset = offsets["head"] {
            font.writeU32(0xB1B0_AFBA &- tableChecksum(font), at: headOffset + 8)
        }
        return font
    }
}
