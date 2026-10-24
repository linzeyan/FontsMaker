import CoreText
import Foundation
import Testing

@testable import FontsMakerKit

/// Pseudo-vertical layout (technical design §5.3) on ops.ttf. Typo ascender
/// 880 and descender −120, so the em-box centre is at y = 380.
struct PseudoVerticalTests {
    private let ascender: Int32 = 880
    private let descender: Int32 = -120

    /// The documented mapping, written out independently of the engine.
    private func turned(_ source: [GlyphPoint], advance: Int32, centered: Bool = false) -> [GlyphPoint] {
        var shiftX: Int32 = 0
        var shiftY: Int32 = 0
        if centered, !source.isEmpty {
            let xs = source.map(\.x)
            let ys = source.map(\.y)
            shiftX = Int32((Double(advance - xs.min()! - xs.max()!) / 2).rounded(.down))
            shiftY = Int32((Double(ascender + descender - ys.min()! - ys.max()!) / 2).rounded(.down))
        }
        let cross = Int32((Double(ascender + descender - advance) / 2).rounded(.down))
        return source.map {
            GlyphPoint(x: ascender - ($0.y + shiftY), y: $0.x + shiftX + cross, onCurve: $0.onCurve)
        }
    }

    private func apply(_ mode: PunctuationMode) throws -> (OpsFixture, Font, PseudoVerticalReport) {
        let ops = try OpsFixture()
        var font = ops.font
        let report = try font.applyPseudoVertical(PseudoVerticalOptions(punctuation: mode))
        return (ops, font, report)
    }

    private func mapped(_ font: Font, _ codePoint: UInt32) -> UInt16 {
        font.characterMap.mappings[codePoint]!
    }

    private func outline(_ font: Font, _ codePoint: UInt32) -> [GlyphPoint] {
        points(font.glyphs[Int(mapped(font, codePoint))])
    }

    @Test func bundledOrientationTableMatchesUAX50() throws {
        let table = try VerticalOrientationTable.bundled()
        let expected: [(UInt32, VerticalOrientation)] = [
            (0x6F22, .upright), (0x2F00, .upright), (0x30FB, .upright), (0x00D7, .upright), (0xFE41, .upright),
            (0x3001, .transformedUpright), (0xFF01, .transformedUpright), (0x3041, .transformedUpright),
            (0x300C, .transformedRotated), (0x30FC, .transformedRotated), (0x201C, .transformedRotated),
            (0x0041, .rotated), (0x00B7, .rotated), (0x2014, .rotated), (0x2026, .rotated),
            (0xE000, .upright), (0x2A6E0, .upright), (0xE0001, .rotated),
        ]
        for (codePoint, orientation) in expected {
            #expect(table.orientation(of: codePoint) == orientation, "U+\(hex(codePoint))")
        }
    }

    @Test func uprightGlyphTurnsAboutTheEmBoxCentre() throws {
        let (ops, font, _) = try apply(.centered)
        let han = ops.glyph("uni6F22")
        #expect(mapped(font, 0x6F22) == han, "turned in place: no other code point needs it upright")

        let source = points(ops.font.glyphs[Int(han)])
        // One point by hand: (100, −50) → (880 − (−50), 100 + (880 − 120 − 1000) / 2) = (930, −20).
        #expect(source[0].x == 100 && source[0].y == -50)
        #expect(outline(font, 0x6F22)[0].x == 930 && outline(font, 0x6F22)[0].y == -20)
        #expect(outline(font, 0x6F22) == turned(source, advance: 1000))
        // The turned advance is the em-box height 880 + 120, not 漢's vmtx
        // advance: a column of glyphs with mixed vmtx advances would be spaced unevenly.
        #expect(ops.font.verticalMetrics?[Int(han)].advanceHeight == 1120, "fixture: vmtx disagrees with the em box")
        #expect(font.horizontalMetrics[Int(han)].advanceWidth == 1000)
        #expect(font.horizontalMetrics[Int(ops.glyph("uni6C49"))].advanceWidth == 1000)
        // The clone of periodcentered appends one entry; existing entries stay as they were.
        let existing = font.verticalMetrics.map { Array($0.prefix(ops.font.glyphs.count)) }
        #expect(existing == ops.font.verticalMetrics, "vertical metrics of existing glyphs unchanged")
    }

    /// A proportional upright glyph keeps its position along the column and is
    /// centred across it; × has an odd advance (555), so the shift floors.
    @Test func proportionalGlyphIsCentredAcrossTheColumn() throws {
        let (ops, font, _) = try apply(.centered)
        let source = points(ops.font.glyphs[Int(ops.glyph("multiply"))])
        let result = outline(font, 0xD7)
        #expect(result == turned(source, advance: 555))
        #expect(result.map(\.y) == source.map { $0.x + 102 }, "⌊(880 − 120 − 555) / 2⌋ = 102")
        // Across the column it occupies a full em, like every other turned glyph.
        #expect(font.horizontalMetrics[Int(ops.glyph("multiply"))].advanceWidth == 1000)
    }

    /// Combining marks have advance 0 (design §5.3). Given the em-box height,
    /// every marked character would take two ems of the column. They turn like
    /// a full-width glyph, about (500, 380), as GuanKiapTsingKhai-90 turns them.
    @Test func zeroWidthMarkKeepsAdvanceZeroAndTurnsLikeFullWidth() throws {
        let ops = try OpsFixture()
        var font = ops.font
        let point = { (x: Int32, y: Int32) in GlyphPoint(x: x, y: y, onCurve: true) }
        // Boxes of 原俠's ゙ (above right, hanging over the preceding glyph) and 〪 (below left).
        let marks: [(UInt32, [GlyphPoint])] = [
            (0x3099, [point(-257, 605), point(-41, 605), point(-41, 795), point(-257, 795)]),
            (0x302A, [point(-1002, -304), point(-817, -304), point(-817, -118), point(-1002, -118)]),
        ]
        var ids: [UInt32: UInt16] = [:]
        for (codePoint, contour) in marks {
            let glyph = Glyph(outline: .simple(SimpleOutline(endPoints: [contour.count - 1], points: contour)))
            ids[codePoint] = try font.appendGlyph(
                glyph, horizontal: HorizontalMetric(advanceWidth: 0, leftSideBearing: Int16(contour[0].x)),
                vertical: VerticalMetric(advanceHeight: 1000, topSideBearing: 0))
            font.characterMap.mappings[codePoint] = ids[codePoint]
        }
        _ = try font.applyPseudoVertical(PseudoVerticalOptions())

        for (codePoint, contour) in marks {
            let id = try #require(ids[codePoint])
            #expect(mapped(font, codePoint) == id, "U+\(hex(codePoint)) turned in place")
            #expect(font.horizontalMetrics[Int(id)].advanceWidth == 0, "U+\(hex(codePoint))")
            #expect(outline(font, codePoint) == turned(contour, advance: 1000), "U+\(hex(codePoint))")
        }
        // One point by hand: (−257, 605) → (880 − 605, −257 + (880 − 120 − 1000) / 2) = (275, −377),
        // a corner of 原俠 -90's ゙. Centred on adv/2 = 0 it would land at (275, 123).
        #expect(outline(font, 0x3099)[0] == point(275, -377))
        let reread = try Font(data: try font.write(options: WriteOptions(stripHinting: true)))
        #expect(reread.horizontalMetrics[Int(ids[0x3099]!)].advanceWidth == 0, "hmtx keeps the 0")
    }

    /// 一 and ⼀ share a glyph: one transformation, no clone (design §4.2).
    @Test func sharedUprightGlyphIsTurnedOnce() throws {
        let (ops, font, _) = try apply(.centered)
        let shared = ops.glyph("uni4E00")
        #expect(mapped(font, 0x4E00) == shared && mapped(font, 0x2F00) == shared)
        #expect(outline(font, 0x4E00) == turned(points(ops.font.glyphs[Int(shared)]), advance: 1000))
    }

    /// 回 is a composite of 口; turning 口 in place must not turn 回's copy again.
    @Test func compositesAreFlattenedBeforeTurning() throws {
        let (ops, font, _) = try apply(.centered)
        #expect(!font.glyphs.contains { $0.isComposite })
        let flattened = try ops.font.flattenedOutline(of: Int(ops.glyph("uni56DE"))).rounded().points
        #expect(outline(font, 0x56DE) == turned(flattened, advance: 1000))
        #expect(outline(font, 0x53E3) == turned(points(ops.font.glyphs[Int(ops.glyph("uni53E3"))]), advance: 1000))
    }

    @Test func centeredPunctuationMovesToTheEmCentreThenTurns() throws {
        let (ops, font, report) = try apply(.centered)
        for (codePoint, name) in [(UInt32(0x3001), "uni3001"), (0x3002, "uni3002"), (0xFF01, "uniFF01")] {
            let source = points(ops.font.glyphs[Int(ops.glyph(name))])
            #expect(mapped(font, codePoint) == ops.glyph(name))
            #expect(outline(font, codePoint) == turned(source, advance: 1000, centered: true), "\(name)")
            // Centred in the turned em box too: x around (880 − (−120)) / 2 = 500, y around 380.
            let box = try #require(BoundingBox(outline(font, codePoint)))
            #expect(
                abs(Double(box.xMin + box.xMax) / 2 - 500) <= 0.5 && abs(Double(box.yMin + box.yMax) / 2 - 380) <= 0.5)
        }
        // U+FE11 is the presentation form 、's vert alternate is mapped from: turned, not centred.
        #expect(mapped(font, 0xFE11) == ops.glyph("uni3001.vert"))
        #expect(outline(font, 0xFE11) == turned(points(ops.font.glyphs[Int(ops.glyph("uni3001.vert"))]), advance: 1000))
        #expect(report.centered == 3)
    }

    @Test func verticalFormsPunctuationUsesTheAlternate() throws {
        let (ops, font, report) = try apply(.verticalForms)
        let alternate = ops.glyph("uni3001.vert")
        // 、 and U+FE11 now want the same thing: one glyph, turned once.
        #expect(mapped(font, 0x3001) == alternate && mapped(font, 0xFE11) == alternate)
        #expect(outline(font, 0x3001) == turned(points(ops.font.glyphs[Int(alternate)]), advance: 1000))
        // Without an alternate the fallback is upright: turned, not moved.
        #expect(outline(font, 0x3002) == turned(points(ops.font.glyphs[Int(ops.glyph("uni3002"))]), advance: 1000))
        #expect(font.glyphs[Int(ops.glyph("uni3001"))] == ops.font.glyphs[Int(ops.glyph("uni3001"))], "unused base")
        #expect(report.centered == 0)
        #expect(report.viaVerticalForms == 4)
        #expect(report.clonedGlyphs == 1)
    }

    /// Tu letters (small kana) are not punctuation: vertical form in either mode.
    @Test func smallKanaUsesItsVerticalFormInEitherMode() throws {
        for mode in PunctuationMode.allCases {
            let (ops, font, _) = try apply(mode)
            let alternate = ops.glyph("uni3041.vert")
            #expect(mapped(font, 0x3041) == alternate, "\(mode)")
            #expect(outline(font, 0x3041) == turned(points(ops.font.glyphs[Int(alternate)]), advance: 1000))
        }
    }

    @Test func transformedRotatedUsesTheAlternateOrStaysSideways() throws {
        let (ops, font, _) = try apply(.centered)
        // 「 and U+FE41 share the alternate; 」's alternate has no code point of its own.
        #expect(mapped(font, 0x300C) == ops.glyph("uniFE41") && mapped(font, 0xFE41) == ops.glyph("uniFE41"))
        #expect(outline(font, 0x300C) == turned(points(ops.font.glyphs[Int(ops.glyph("uniFE41"))]), advance: 1000))
        #expect(mapped(font, 0x300D) == ops.glyph("uni300D.vert"))
        #expect(outline(font, 0x300D) == turned(points(ops.font.glyphs[Int(ops.glyph("uni300D.vert"))]), advance: 1000))
        // ー has no vertical form: left sideways, which reads correctly once the page is turned.
        let bar = ops.glyph("uni30FC")
        #expect(mapped(font, 0x30FC) == bar && font.glyphs[Int(bar)] == ops.font.glyphs[Int(bar)])
    }

    @Test func rotatedCodePointsAreUntouched() throws {
        let (ops, font, _) = try apply(.centered)
        let a = ops.glyph("A")
        #expect(mapped(font, 0x41) == a)
        #expect(font.glyphs[Int(a)] == ops.font.glyphs[Int(a)])
        #expect(font.horizontalMetrics[Int(a)] == ops.font.horizontalMetrics[Int(a)])
    }

    /// Design §5.3 欄距: once turned, the line height is the column pitch.
    /// ops.ttf's hhea line (880 + 120) and win line (1100 + 300) are both
    /// shorter than 2.224 em, so each descender grows until its line is 2224
    /// units, by different amounts. The typo metrics that place the rotation
    /// centre must not move with them.
    @Test func shortLinesGrowOnTheDescenderSideToTheColumnPitch() throws {
        let (ops, font, report) = try apply(.centered)
        #expect(ops.font.hhea == HheaFields(ascender: 880, descender: -120, lineGap: 0), "fixture")
        #expect(ops.font.os2?.winAscent == 1100 && ops.font.os2?.winDescent == 300, "fixture")

        #expect(font.hhea == HheaFields(ascender: 880, descender: -1344, lineGap: 0))
        #expect(font.os2?.winAscent == 1100 && font.os2?.winDescent == 1124)
        #expect(report.hheaDescender == MetricChange(before: -120, after: -1344))
        #expect(report.winDescent == MetricChange(before: 300, after: 1124))
        let typo = { (font: Font) in [font.os2?.typoAscender, font.os2?.typoDescender, font.os2?.typoLineGap] }
        #expect(typo(font) == typo(ops.font) && typo(font) == [880, -120, 0])

        // Written where the spec puts them (hhea +6, OS/2 +76), and CoreText,
        // which spaces lines by hhea, sees the taller line.
        let data = try font.write(options: WriteOptions(stripHinting: true))
        let bytes = [UInt8](data)
        #expect(table("hhea", in: bytes)?.readI16(at: 6) == -1344)
        #expect(table("OS/2", in: bytes)?.readU16(at: 76) == 1124)
        #expect(table("OS/2", in: bytes)?.readI16(at: 70) == -120, "typo descender written unchanged")
        let coreText = try coreTextFont(data)
        #expect(abs(CTFontGetDescent(coreText) - 1344) < 0.5, "at 1000 pt, one unit is one point")
    }

    /// A line already at or above 2.224 em is left as it is: never shrunk.
    @Test func lineAtOrAboveTheColumnPitchIsLeftAsItIs() throws {
        var font = try OpsFixture().font
        font.hhea.descender = -1344  // 880 + 1344 = 2224: exactly the minimum
        font.os2?.winDescent = 1500  // 1100 + 1500 = 2600: taller
        let report = try font.applyPseudoVertical(PseudoVerticalOptions())
        #expect(font.hhea.descender == -1344 && font.os2?.winDescent == 1500)
        #expect(report.hheaDescender == nil && report.winDescent == nil)
    }

    /// · (R) and ・ (U) share a glyph: the original stays for ·, ・ gets a clone.
    @Test func glyphNeededBothWaysIsClonedAndTheCmapSplit() throws {
        let (ops, font, report) = try apply(.centered)
        let dot = ops.glyph("periodcentered")
        let clone = UInt16(ops.font.glyphs.count)
        #expect(font.glyphs.count == ops.font.glyphs.count + 1)
        #expect(mapped(font, 0xB7) == dot && font.glyphs[Int(dot)] == ops.font.glyphs[Int(dot)])
        #expect(mapped(font, 0x30FB) == clone)
        #expect(outline(font, 0x30FB) == turned(points(ops.font.glyphs[Int(dot)]), advance: 300))
        #expect(font.horizontalMetrics[Int(clone)].advanceWidth == 1000)
        #expect(font.verticalMetrics?[Int(clone)] == ops.font.verticalMetrics?[Int(dot)])
        #expect(report.clonedGlyphs == 1)
        #expect(report.transformedGlyphs == 25)
        #expect(report.codePoints == [.upright: 22, .rotated: 3, .transformedUpright: 4, .transformedRotated: 3])
        #expect(report.turned == 28 && report.leftSideways == 4 && report.viaVerticalForms == 3)
    }

    /// Adding a glyph must keep the file valid: hmtx/vmtx/maxp grow, post
    /// drops its now-wrong glyph names (format 3), CoreText follows the split cmap.
    @Test func fontWithClonesIsWrittenValid() throws {
        let (ops, font, _) = try apply(.centered)
        let data = try font.write(options: WriteOptions(stripHinting: true))
        let bytes = [UInt8](data)
        let count = ops.font.glyphs.count + 1

        let reread = try Font(bytes: bytes)
        #expect(reread.glyphs == font.glyphs)
        #expect(reread.horizontalMetrics.map(\.advanceWidth) == font.horizontalMetrics.map(\.advanceWidth))
        #expect(reread.verticalMetrics == font.verticalMetrics)
        #expect(reread.characterMap == font.characterMap)
        #expect(table("maxp", in: bytes)?.readU16(at: 4) == UInt16(count))
        let post = try #require(table("post", in: bytes))
        #expect(post.count == 32 && post.readU16(at: 0) == 3 && post.readU16(at: 2) == 0)
        let hhea = try #require(table("hhea", in: bytes))
        let vhea = try #require(table("vhea", in: bytes))
        #expect(
            table("hmtx", in: bytes)?.count == 4 * Int(hhea.readU16(at: 34)) + 2 * (count - Int(hhea.readU16(at: 34))))
        #expect(
            table("vmtx", in: bytes)?.count == 4 * Int(vhea.readU16(at: 34)) + 2 * (count - Int(vhea.readU16(at: 34))))
        let os2 = try #require(reread.os2)
        let widths = font.horizontalMetrics.map { Double($0.advanceWidth) }.filter { $0 > 0 }
        #expect(os2.xAvgCharWidth == Int16((widths.reduce(0, +) / Double(widths.count) + 0.5).rounded(.down)))
        #expect(os2.xAvgCharWidth != ops.font.os2?.xAvgCharWidth)

        let coreText = try coreTextFont(data)
        #expect(CTFontGetGlyphCount(coreText) == count)
        #expect(
            laidOutGlyphs(coreText, "・·漢") == [
                CGGlyph(count - 1), CGGlyph(ops.glyph("periodcentered")), CGGlyph(ops.glyph("uni6F22")),
            ])
    }

    @Test func noCloneNoPostChange() throws {
        // s2t alone keeps the glyph count, so post keeps its glyph names.
        var font = try OpsFixture().font
        _ = try font.convertSimplifiedToTraditional(S2TOptions())
        let bytes = [UInt8](try font.write())
        #expect(table("post", in: bytes) == font.tables["post"])
    }
}
