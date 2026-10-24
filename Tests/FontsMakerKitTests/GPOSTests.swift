import CoreText
import Foundation
import Testing

@testable import FontsMakerKit

// GPOS kerning and anchors (technical design §5.6, §5.7). CoreText is the
// oracle: it reads the built font's GPOS the way a reader does, so these
// tests do not trust the engine's own GPOS parser to check its writer.

/// Glyphs and pen positions CoreText lays `text` out with, at a size of
/// `unitsPerEm` points, so positions are in font units.
private func coreTextLayout(_ data: Data, _ text: String, unitsPerEm: UInt16) throws -> [(
    glyph: Int, x: Double, y: Double
)] {
    let font = try coreTextFont(data, size: CGFloat(unitsPerEm))
    let attributed = NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font])
    var result: [(glyph: Int, x: Double, y: Double)] = []
    for run in CTLineGetGlyphRuns(CTLineCreateWithAttributedString(attributed)) as? [CTRun] ?? [] {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
        for index in 0..<count { result.append((Int(glyphs[index]), positions[index].x, positions[index].y)) }
    }
    return result
}

/// The kerning CoreText applies between the two characters of `pair`:
/// where the second glyph starts, less the first glyph's own advance.
private func coreTextKerning(_ data: Data, _ font: Font, _ pair: String) throws -> Int {
    let laid = try coreTextLayout(data, pair, unitsPerEm: font.unitsPerEm)
    try #require(laid.count == 2, "\(pair) lays out as two glyphs")
    return Int((laid[1].x - laid[0].x - Double(font.horizontalMetrics[laid[0].glyph].advanceWidth)).rounded())
}

/// fontTools `otRound`, as the engine rounds scaled coordinates.
private func otRound(_ value: Double) -> Int { Int((value + 0.5).rounded(.down)) }

/// A Windows `kern` table (version 0) with one format 0 subtable.
private func kernTable(_ pairs: [(UInt16, UInt16, Int16)]) -> [UInt8] {
    let sorted = pairs.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
    var power = 1
    while power * 2 <= sorted.count { power *= 2 }
    var writer = ByteWriter()
    writer.u16(0)
    writer.u16(1)
    writer.u16(0)
    writer.u16(UInt16(14 + 6 * sorted.count))
    writer.u16(0x0001)  // horizontal, format 0
    writer.u16(UInt16(sorted.count))
    writer.u16(UInt16(6 * power))
    writer.u16(UInt16(power.trailingZeroBitCount))
    writer.u16(UInt16(6 * (sorted.count - power)))
    for (left, right, value) in sorted {
        writer.u16(left)
        writer.u16(right)
        writer.i16(value)
    }
    return writer.bytes
}

/// Builds `steps` on `source`; `SECOND` and `THIRD` in the steps stand for
/// the replace steps' {file, sha256} of `second` and `third`.
private func build(
    _ source: (name: String, bytes: [UInt8]), _ steps: String, second: (name: String, bytes: [UInt8])? = nil,
    third: (name: String, bytes: [UInt8])? = nil
) throws -> (result: BuildResult, font: Font) {
    var json = steps
    var replacementData: [String: Data] = [:]
    for (placeholder, font) in [("SECOND", second), ("THIRD", third)] {
        guard let font else { continue }
        let sha256 = sha256Hex(font.bytes)
        json = json.replacingOccurrences(of: placeholder, with: #"{"file": "\#(font.name)", "sha256": "\#(sha256)"}"#)
        replacementData[sha256] = Data(font.bytes)
    }
    let recipe = try Recipe(
        json: recipeJSON(
            sourceFile: source.name, sha256: sha256Hex(source.bytes), output: #"{"familyName": "GPOS Check"}"#,
            steps: json))
    let result = try RecipeBuilder.build(
        recipe, sourceData: Data(source.bytes), replacementData: replacementData, options: BuildOptions())
    return (result, try Font(data: result.fontData))
}

private func reference(_ name: String) throws -> (name: String, bytes: [UInt8]) {
    (name, try ReferenceFonts.bytes(name))
}

/// replace brings the second font's kerning between the letters it copies.
struct ReplaceKerningTests {
    /// Pairs Crimson Text kerns: capitals, lowercase, punctuation.
    static let pairs = ["AV", "VA", "To", "Ty", "WA", "LT", "P.", "Yo", "AT", "r.", "F,", "Av", "Te"]
    static let step =
        #"[{"op": "replace", "font": SECOND, "sets": ["latinLetters", "asciiPunctuation"], "match": "unitsPerEm"}]"#

    static let built = Result {
        try build(try reference("GuanKiapTsingKhai.ttf"), step, second: try reference("CrimsonText-Regular.ttf"))
    }

    /// What the reader sees: each pair kerned by Crimson's value scaled with
    /// the letters (1000/1024 here), not set flat as before.
    @Test func copiedLettersKernAsInTheSecondFont() throws {
        let (result, output) = try ReplaceKerningTests.built.get()
        let donorBytes = try ReferenceFonts.bytes("CrimsonText-Regular.ttf")
        let donor = try Font(bytes: donorBytes)
        let scale = 1000.0 / 1024
        var kerned = 0
        for pair in ReplaceKerningTests.pairs {
            let expected = otRound(Double(try coreTextKerning(Data(donorBytes), donor, pair)) * scale)
            let actual = try coreTextKerning(result.fontData, output, pair)
            #expect(actual == expected, "\(pair): \(actual), Crimson scaled \(expected)")
            if expected != 0 { kerned += 1 }
        }
        #expect(kerned >= 8, "most of the pairs are ones Crimson kerns")
        let report = try #require(result.reports.lazy.compactMap { if case .replace(_, let r) = $0 { r } else { nil } }.first)
        #expect(report.kerning.source == .gpos && report.kerning.pairs > 100, "\(report.kerning.pairs) pairs")
        #expect(result.reports.contains { $0.summary.contains("kerning pairs from its GPOS kern feature") })
    }

    /// The target's own kerning (GuanKiapTsingKhai kerns kana) is not
    /// disturbed by the new lookup on the same feature.
    @Test func targetKerningStays() throws {
        let (result, output) = try ReplaceKerningTests.built.get()
        let sourceBytes = try ReferenceFonts.bytes("GuanKiapTsingKhai.ttf")
        let source = try Font(bytes: sourceBytes)
        let kana = Array("あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをんアイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲンぁぃぅぇぉっゃゅょ")
        var kerned = 0
        for index in kana.indices.dropLast() {
            let pair = String(kana[index]) + String(kana[index + 1])
            let before = try coreTextKerning(Data(sourceBytes), source, pair)
            #expect(try coreTextKerning(result.fontData, output, pair) == before, "\(pair)")
            if before != 0 { kerned += 1 }
        }
        #expect(kerned >= 2, "GuanKiapTsingKhai kerns some of these kana pairs")
    }

    /// A second font with only a `kern` table gives its pairs too; and a
    /// target with only a `kern` table keeps its own pairs, which move into
    /// the new GPOS lookup: a shaper that finds a GPOS kern feature no longer
    /// reads the kern table.
    @Test func kernTablesOfEitherFont() throws {
        var donor = try Font(bytes: try ReferenceFonts.bytes("CrimsonText-Regular.ttf"))
        func glyph(_ font: Font, _ character: Character) -> UInt16 {
            font.characterMap.mappings[character.unicodeScalars.first!.value]!
        }
        donor.tables["GPOS"] = nil
        donor.tables["kern"] = kernTable([
            (glyph(donor, "A"), glyph(donor, "V"), -120), (glyph(donor, "T"), glyph(donor, "o"), -60),
        ])
        var target = try Fixtures.font("ops.ttf")
        let one = glyph(target, "一")
        let mouth = glyph(target, "口")
        target.tables["kern"] = kernTable([(one, mouth, -77)])
        let (result, output) = try build(
            ("ops-kern.ttf", [UInt8](try target.write())),
            #"[{"op": "replace", "font": SECOND, "characters": ["A", "V", "T", "o"]}]"#,
            second: ("crimson-kern.ttf", [UInt8](try donor.write())))
        #expect(try coreTextKerning(result.fontData, output, "AV") == otRound(-120 * 1000 / 1024.0))
        #expect(try coreTextKerning(result.fontData, output, "To") == otRound(-60 * 1000 / 1024.0))
        #expect(try coreTextKerning(result.fontData, output, "一口") == -77)
        let report = try #require(result.reports.lazy.compactMap { if case .replace(_, let r) = $0 { r } else { nil } }.first)
        #expect(report.kerning == KerningCopyReport(source: .kernTable, pairs: 2, targetKernTablePairs: 1))
        #expect(table("kern", in: [UInt8](result.fontData)) != nil, "kept for readers that only read kern")
    }

    /// Two replace steps, each from its own font: the second adds its pairs
    /// beside the first's, on the same kern feature, and takes none away
    /// (Latin letters and borrowed characters are separate steps, design §5.7).
    @Test func eachReplaceStepKeepsItsKerning() throws {
        func glyph(_ font: Font, _ character: Character) -> UInt16 {
            font.characterMap.mappings[character.unicodeScalars.first!.value]!
        }
        func donor(_ left: Character, _ right: Character, _ value: Int16) throws -> [UInt8] {
            var font = try Font(bytes: try ReferenceFonts.bytes("CrimsonText-Regular.ttf"))
            font.tables["GPOS"] = nil
            font.tables["kern"] = kernTable([(glyph(font, left), glyph(font, right), value)])
            return [UInt8](try font.write())
        }
        let (result, output) = try build(
            ("ops.ttf", [UInt8](try Fixtures.font("ops.ttf").write())),
            #"[{"op": "replace", "font": SECOND, "characters": ["A", "V"]}, "#
                + #"{"op": "replace", "font": THIRD, "characters": ["T", "o"]}]"#,
            second: ("crimson-av.ttf", try donor("A", "V", -120)),
            third: ("crimson-to.ttf", try donor("T", "o", -60)))
        #expect(try coreTextKerning(result.fontData, output, "AV") == otRound(-120 * 1000 / 1024.0), "the first step's pair")
        #expect(try coreTextKerning(result.fontData, output, "To") == otRound(-60 * 1000 / 1024.0), "the second step's pair")
    }

    /// A step without kerning to copy leaves GPOS as the target had it.
    @Test func nothingToCopyLeavesGPOS() throws {
        let source = try reference("GuanKiapTsingKhai.ttf")
        let (result, _) = try build(
            source, #"[{"op": "replace", "font": SECOND, "characters": ["導", "傳"]}]"#,
            second: try reference("LXGWWenKaiTC-Medium.ttf"))
        #expect(table("GPOS", in: [UInt8](result.fontData)) == table("GPOS", in: source.bytes))
    }
}

/// embolden widen moves outlines right; the anchors accents attach to move with them.
struct WidenAnchorTests {
    /// Base + combining mark with no precomposed glyph, so GPOS places the mark.
    static let crimsonMarks = ["B\u{301}", "D\u{308}", "F\u{301}", "R\u{308}", "q\u{301}", "K\u{308}"]

    /// Where CoreText puts the mark relative to the base: in the widened font
    /// it must be where plain embolden (outlines unmoved) puts it, plus the
    /// distance the base's outline moved. Before anchors moved, it stayed put
    /// and the accent sat that far left of the letter.
    private func expectMarksFollow(_ source: String, _ steps: String, _ texts: [String]) throws {
        let font = try reference(source)
        let (plain, plainFont) = try build(font, steps.replacingOccurrences(of: #", "widen": true"#, with: ""))
        let (widened, widenedFont) = try build(font, steps)
        var moved = 0
        for text in texts {
            let before = try coreTextLayout(plain.fontData, text, unitsPerEm: plainFont.unitsPerEm)
            let after = try coreTextLayout(widened.fontData, text, unitsPerEm: widenedFont.unitsPerEm)
            try #require(before.count == 2 && after.count == 2, "\(text) is a base and a mark")
            let base = before[0].glyph
            let shift =
                try #require(BoundingBox(try widenedFont.flattenedOutline(of: base).rounded().points)).xMin
                - #require(BoundingBox(try plainFont.flattenedOutline(of: base).rounded().points)).xMin
            #expect(shift != 0, "\(text): the base moved")
            let offset = (after[1].x - after[0].x) - (before[1].x - before[0].x)
            #expect(abs(offset - Double(shift)) < 0.01, "\(text): mark moved \(offset), base \(shift)")
            #expect(after[1].y == before[1].y)
            moved += 1
        }
        #expect(moved == texts.count)
        let report = try #require(
            widened.reports.lazy.compactMap { if case .embolden(_, let r) = $0 { r } else { nil } }.first)
        #expect(report.anchorsMoved > 0)
    }

    @Test func accentsFollowWidenedLetters() throws {
        try expectMarksFollow(
            "CrimsonText-Regular.ttf", #"[{"op": "embolden", "weight": 30, "widen": true}]"#,
            WidenAnchorTests.crimsonMarks)
    }

    /// Without widen an outline grows the same on both sides and does not
    /// move, so the anchors stay valid and GPOS is copied byte for byte.
    @Test func plainEmboldenLeavesGPOS() throws {
        let source = try reference("CrimsonText-Regular.ttf")
        let (plain, _) = try build(source, #"[{"op": "embolden", "weight": 30}]"#)
        #expect(table("GPOS", in: [UInt8](plain.fontData)) == table("GPOS", in: source.bytes))
    }

    /// Compilers share one anchor table between glyphs; moving one glyph's
    /// anchor must not move the other's. Cursive entry and exit anchors move too.
    @Test func sharedAndCursiveAnchors() throws {
        var subtable = ByteWriter()
        subtable.u16(1)  // CursivePos format 1
        subtable.u16(14)  // coverage
        subtable.u16(2)
        for offset: UInt16 in [22, 22, 22, 0] { subtable.u16(offset) }  // glyph 5 entry, exit; glyph 6 entry, none
        for value: UInt16 in [1, 2, 5, 6] { subtable.u16(value) }  // coverage: glyphs 5, 6
        subtable.u16(1)  // the one anchor, format 1
        subtable.i16(100)
        subtable.i16(200)
        let gpos = try GSUBLayout(
            scripts: GSUBLayout.withoutGSUB.scripts, features: [], lookups: [], source: [], tag: "GPOS"
        ).encoded(adding: [GSUBLayout.NewLookup(type: 3, subtables: [subtable.bytes])])

        #expect(try GPOSAnchors.moved(gpos, by: [7: 12]) == nil, "no anchor of glyph 7: GPOS untouched")
        let moved = try #require(try GPOSAnchors.moved(gpos, by: [5: 12]))
        #expect(moved.glyphs == [5])
        let layout = try GSUBLayout(parsing: moved.table, tag: "GPOS")
        #expect(layout.lookups.map(\.type) == [3])
        let (read, glyphs, _) = try GPOSAnchors.read(moved.table, at: layout.lookups[0].subtables[0], type: 3)
        guard case .cursive(_, let records) = read else {
            Issue.record("a cursive subtable")
            return
        }
        #expect(glyphs == [5, 6])
        #expect(records[0].entry?.x == 112 && records[0].exit?.x == 112 && records[0].entry?.y == 200)
        #expect(records[1].entry?.x == 100 && records[1].exit == nil)
    }
}

/// A monospaced font stays monospaced under embolden widen.
struct MonospaceWidenTests {
    static let source = "JetBrainsMono-Regular.ttf"

    @Test func everyAdvanceStaysEqual() throws {
        let font = try reference(MonospaceWidenTests.source)
        let sourceFont = try Font(bytes: font.bytes)
        #expect(sourceFont.monospacedAdvance == 600 && sourceFont.isFixedPitch == true)
        let (result, output) = try build(
            font, #"[{"op": "embolden", "weight": 30, "widen": true}, {"op": "tracking", "units": 10}]"#)
        let advances = Set(output.horizontalMetrics.map(\.advanceWidth).filter { $0 > 0 })
        #expect(advances == [640], "600 + weight 30 + tracking 10, every glyph")
        #expect(output.horizontalMetrics.filter { $0.advanceWidth == 0 }.count
            == sourceFont.horizontalMetrics.filter { $0.advanceWidth == 0 }.count, "marks stay zero-width")
        let report = try #require(result.reports.lazy.compactMap { if case .embolden(_, let r) = $0 { r } else { nil } }.first)
        let mono = try #require(report.monospace)
        #expect(mono.advanceBefore == 600 && mono.advanceAfter == 630 && mono.fixedPitchFlag == true)
        #expect(result.reports.contains { $0.summary.contains("monospaced: every advance 600 → 630") })
    }

    /// Each glyph keeps its place in its cell: the extra width goes half to
    /// each side. Box-drawing glyphs still meet their neighbours, a skipped
    /// glyph is the source's moved to the middle of the wider cell.
    @Test func glyphsKeepTheirPlaceInTheCell() throws {
        let font = try reference(MonospaceWidenTests.source)
        let source = try Font(bytes: font.bytes)
        let (_, output) = try build(font, #"[{"op": "embolden", "weight": 30, "widen": true, "skip": ["l"]}]"#)
        func box(_ font: Font, _ character: Character) throws -> BoundingBox {
            let glyph = Int(font.characterMap.mappings[character.unicodeScalars.first!.value]!)
            return try #require(BoundingBox(try font.flattenedOutline(of: glyph).rounded().points))
        }
        // Straight stems grow by the weight, 15 each side: same side bearings.
        #expect(try box(output, "i").xMin == box(source, "i").xMin)
        #expect(630 - (try box(output, "i").xMax) == 600 - (try box(source, "i").xMax))
        #expect(try box(output, "█").xMin == 0 && box(output, "█").xMax == 630, "full block fills the cell")
        #expect(try box(output, "─").xMin == -20 && box(output, "─").xMax == 650, "the line still overlaps its neighbours")
        let l = Int(source.characterMap.mappings[0x6C]!)
        #expect(
            try output.flattenedOutline(of: l).rounded().points
                == source.flattenedOutline(of: l).rounded().points.map { GlyphPoint(x: $0.x + 15, y: $0.y, onCurve: $0.onCurve) },
            "skipped l: unchanged, moved to the middle")
    }

    @Test func accentsFollow() throws {
        let font = try reference(MonospaceWidenTests.source)
        let (plain, plainFont) = try build(font, #"[{"op": "embolden", "weight": 30}]"#)
        let (widened, widenedFont) = try build(font, #"[{"op": "embolden", "weight": 30, "widen": true}]"#)
        for text in ["x\u{301}", "q\u{308}"] {
            let before = try coreTextLayout(plain.fontData, text, unitsPerEm: plainFont.unitsPerEm)
            let after = try coreTextLayout(widened.fontData, text, unitsPerEm: widenedFont.unitsPerEm)
            try #require(before.count == 2 && after.count == 2)
            let base = before[0].glyph
            let shift =
                try #require(BoundingBox(try widenedFont.flattenedOutline(of: base).rounded().points)).xMin
                - #require(BoundingBox(try plainFont.flattenedOutline(of: base).rounded().points)).xMin
            #expect(abs((after[1].x - after[0].x) - (before[1].x - before[0].x) - Double(shift)) < 0.01, "\(text)")
        }
    }

    @Test func previewMatchesTheBuild() throws {
        let font = try reference(MonospaceWidenTests.source)
        let steps = #"[{"op": "embolden", "weight": 24, "widen": true, "skip": ["l"]}]"#
        let (_, built) = try build(font, steps)
        let recipe = try Recipe(
            json: recipeJSON(
                sourceFile: "a.ttf", sha256: String(repeating: "0", count: 64), output: #"{"familyName": "P"}"#,
                steps: steps))
        let text = "il.W─█x"
        let preview = try Font(bytes: font.bytes).preview(of: text.unicodeScalars.map(\.value), steps: recipe.steps)
        for scalar in text.unicodeScalars {
            let glyph = try #require(preview.glyphs[scalar.value])
            let builtID = Int(built.characterMap.mappings[scalar.value]!)
            #expect(glyph.advanceWidth == Int(built.horizontalMetrics[builtID].advanceWidth), "\(scalar)")
            #expect(glyph.outline.points == (try built.flattenedOutline(of: builtID).rounded().points), "\(scalar)")
        }
    }
}

/// lineHeight keeps the line it sets, and Windows GDI clips no glyph.
struct LineHeightWinTests {
    /// Crimson Text at 1024 units: hhea and typo hold the tighter line, win
    /// reaches the top of Å and É and the bottom of every descender, and the
    /// font says (USE_TYPO_METRICS) to space lines by typo.
    @Test func winCoversTheGlyphsOfATighterLine() throws {
        let font = try reference("CrimsonText-Regular.ttf")
        let (result, output) = try build(font, #"[{"op": "lineHeight", "units": 1024}]"#)
        #expect(output.hhea == HheaFields(ascender: 819, descender: -205, lineGap: 0))
        let os2 = try #require(output.os2)
        #expect(os2.typoAscender == 819 && os2.typoDescender == -205)
        let extent = try #require(try output.verticalGlyphExtent())
        let winAscent = Int32(try #require(os2.winAscent))
        let winDescent = Int32(try #require(os2.winDescent))
        #expect(winAscent == extent.yMax && -winDescent == extent.yMin)
        for character in "ÅÉÇjgÿ".unicodeScalars {
            let glyph = Int(output.characterMap.mappings[character.value]!)
            let box = try #require(BoundingBox(try output.flattenedOutline(of: glyph).rounded().points))
            #expect(box.yMax <= Int32(os2.winAscent!) && -box.yMin <= Int32(os2.winDescent!), "\(character)")
        }
        #expect(try #require(output.flattenedOutline(of: Int(output.characterMap.mappings[0xC5]!)).ys.max()) > 819)
        #expect(os2.fsSelection & 0x80 != 0)
        let coreText = try coreTextFont(result.fontData, size: 1024)
        #expect(abs(CTFontGetAscent(coreText) + CTFontGetDescent(coreText) + CTFontGetLeading(coreText) - 1024) < 0.001)
        #expect(result.reports.contains { $0.summary.contains("win 1038/-231/0 (covers every glyph), USE_TYPO_METRICS already set") })
    }

    /// OS/2 version 3 has version 4's layout but not its bit 7: lineHeight
    /// raises the version and sets the bit, and changes no other OS/2 byte
    /// beyond the metrics it owns.
    @Test func useTypoMetricsOnAVersion3Table() throws {
        let source = ("ops.ttf", try Fixtures.bytes("ops.ttf"))
        let (result, output) = try build(source, #"[{"op": "lineHeight", "units": 1300}]"#)
        let os2 = try #require(output.os2)
        #expect(os2.version == 4 && os2.fsSelection == 0x40 | 0x80)
        let before = try #require(table("OS/2", in: source.1))
        let after = try #require(table("OS/2", in: [UInt8](result.fontData)))
        let owned = Set([0, 1, 62, 63]).union(68..<78)
        #expect(before.indices.filter { before[$0] != after[$0] }.allSatisfy(owned.contains))
        let report = try #require(result.reports.lazy.compactMap { if case .lineHeight(_, let r) = $0 { r } else { nil } }.first)
        #expect(report.typoMetrics == .setRaisingVersion(from: 3))
    }

    /// win is checked again when the font is written: a step after lineHeight
    /// that makes glyphs taller (embolden) is still covered.
    @Test func laterStepsStayCovered() throws {
        let font = try reference("CrimsonText-Regular.ttf")
        let (_, output) = try build(
            font, #"[{"op": "lineHeight", "units": 1024}, {"op": "embolden", "weight": 40}]"#)
        let extent = try #require(try output.verticalGlyphExtent())
        #expect(Int32(output.os2!.winAscent!) == extent.yMax && -Int32(output.os2!.winDescent!) == extent.yMin)
        #expect(extent.yMax > 1038, "embolden made the tallest glyph taller than lineHeight saw it")
    }
}
