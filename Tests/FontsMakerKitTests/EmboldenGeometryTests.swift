import CoreGraphics
import Foundation
import Testing

@testable import FontsMakerKit

/// The cleanup and conversion steps between CGPath's union and the TrueType
/// outline (technical design §5.1), on hand-built contours.
struct EmboldenGeometryTests {
    private func v(_ x: Double, _ y: Double) -> Vec2 { Vec2(x: x, y: y) }
    private func on(_ x: Int32, _ y: Int32) -> GlyphPoint { GlyphPoint(x: x, y: y, onCurve: true) }
    private func off(_ x: Int32, _ y: Int32) -> GlyphPoint { GlyphPoint(x: x, y: y, onCurve: false) }

    /// The Phase 0 shape: a curve ends, a 0.25-unit line steps back, the next
    /// curve carries on forward. Left alone, rounding turns it into a crossing.
    @Test func backTrackingSpurIsRemoved() {
        var contour = BezierContour(segments: [
            .cubic(v(30, 0), v(60, 0), v(100, 0)),
            .line(v(99.75, 0.05)),  // the spur
            .cubic(v(130, 0), v(170, 0), v(200, 0)),
            .line(v(200, 100)),
            .line(v(0, 100)),
            .line(v(0, 0)),
        ])
        contour.removeSpurs(maxLength: EmboldenGeometry.maxSpurLength)
        #expect(contour.segments.count == 5)
        #expect(!contour.segments.contains(.line(v(99.75, 0.05))))
        #expect(contour.start(of: 1) == v(100, 0), "the next curve now starts where the previous one ended")
    }

    /// Not every reversal is a spur: the tip of a thin wedge turns back and
    /// keeps going back, and a long back-step is real geometry.
    @Test func wedgeTipsAndLongReversalsStay() {
        let wedge = BezierContour(segments: [
            .line(v(100, 1)),
            .line(v(98.5, 1.5)),  // tip: against the incoming edge, along the outgoing one
            .line(v(0, 3)),
            .line(v(0, 0)),
        ])
        var cleaned = wedge
        cleaned.removeSpurs(maxLength: EmboldenGeometry.maxSpurLength)
        #expect(cleaned == wedge)

        let zigzag = BezierContour(segments: [
            .line(v(100, 0)),
            .line(v(95, 0.5)),  // 5 units back: longer than any spur
            .line(v(200, 1)),
            .line(v(200, 100)),
            .line(v(0, 0)),
        ])
        cleaned = zigzag
        cleaned.removeSpurs(maxLength: EmboldenGeometry.maxSpurLength)
        #expect(cleaned == zigzag)
    }

    @Test func degenerateSegmentsAreDropped() {
        var contour = BezierContour(segments: [
            .line(v(10, 0)), .line(v(10, 0)), .line(v(10, 10)), .cubic(v(10, 10), v(10, 10), v(10, 10)),
            .line(v(0, 10)), .line(v(0, 0)),
        ])
        contour.removeSpurs(maxLength: 3)
        #expect(contour.segments == [.line(v(10, 0)), .line(v(10, 10)), .line(v(0, 10)), .line(v(0, 0))])
    }

    @Test func debrisContoursAreRecognized() {
        func box(_ w: Double, _ h: Double) -> BezierContour {
            BezierContour(segments: [.line(v(w, 0)), .line(v(w, h)), .line(v(0, h)), .line(v(0, 0))])
        }
        #expect(box(1.9, 1.9).isDebris, "extent under 2 units")
        #expect(box(30, 0.1).isDebris, "3 units² sliver")
        #expect(!box(2, 2).isDebris)
        #expect(!box(30, 0.2).isDebris, "6 units² is kept")
        // A tiny curved blob: the extent is measured on the curve, not the control points.
        let blob = BezierContour(segments: [.cubic(v(1, 3), v(-1, 3), v(0, 0))])
        #expect(blob.isDebris)
    }

    @Test func impliedOnCurvePointsAreDroppedOnlyWhenExact() {
        let points = [on(0, 0), off(10, 10), on(15, 10), off(20, 10), on(30, 0), off(15, -10), on(1, -1), off(0, -2)]
        // (15, 10) is midway between (10, 10) and (20, 10); (1, -1) is not midway
        // between (15, -10) and (0, -2), and (0, 0)/(30, 0) have an on-curve neighbor.
        #expect(EmboldenGeometry.impliedOnCurveIndices(points) == [2])
    }

    /// Rounding comes first: a float midpoint can stop being a midpoint.
    @Test func impliedPointsAreJudgedAfterRounding() throws {
        // Two quadratics joined at their controls' float midpoint, as cu2qu
        // splines arrive before the implied points are dropped.
        func outline(_ a: Double, _ b: Double) throws -> SimpleOutline {
            try EmboldenGeometry.trueTypeOutline(
                [
                    BezierContour(segments: [
                        .quad(v(a, 40), v((a + b) / 2, 40)), .quad(v(b, 40), v(30, 0)), .line(v(0, 0)),
                    ])
                ], reversingDirection: true)
        }
        #expect(try outline(10.4, 20.4).points.count == 4, "10 + 20 = 2 × 15: implied, dropped")
        #expect(try outline(10.6, 20.4).points.count == 5, "11 + 20 ≠ 2 × 16 (15.5 rounds up): kept")
    }

    @Test func integerCleanupRemovesCollapsedPoints() {
        // Off-curve on top of its on-curve neighbor: the curve is a straight line.
        #expect(
            EmboldenGeometry.cleanedIntegerContour([on(0, 0), off(0, 0), on(10, 0), on(10, 10), on(0, 10)])
                == [on(0, 0), on(10, 0), on(10, 10), on(0, 10)])
        // Duplicate on-curve points, and a curve out and straight back.
        #expect(
            EmboldenGeometry.cleanedIntegerContour([on(0, 0), on(0, 0), on(10, 0), off(12, 3), on(10, 0), on(10, 10)])
                == [on(0, 0), on(10, 0), on(10, 10)])
        #expect(EmboldenGeometry.cleanedIntegerContour([on(0, 0), on(1, 0), on(1, 1), on(0, 1)]) == nil, "1×1 debris")
        #expect(EmboldenGeometry.cleanedIntegerContour([on(0, 0), on(100, 0), on(200, 0)]) == nil, "no area")
    }

    @Test func quadraticAreaIsExact() {
        // Under y = 4t(1-t), x = 2t: the curve encloses 4/3 with the chord, traversed clockwise.
        #expect(EmboldenGeometry.quadraticArea([on(0, 0), off(1, 2), on(2, 0)]) == -4.0 / 3)
        #expect(EmboldenGeometry.quadraticArea([on(0, 0), on(0, 10), on(10, 10), on(10, 0)]) == -100)
    }

    /// Union output runs counter-clockwise around ink; TrueType wants
    /// clockwise. Holes run the other way in both.
    @Test func contoursAreReversedToTrueTypeDirection() throws {
        let unionStyle = [
            BezierContour(segments: [.line(v(100, 0)), .line(v(100, 100)), .line(v(0, 100)), .line(v(0, 0))]),
            BezierContour(segments: [.line(v(20, 80)), .line(v(80, 80)), .line(v(80, 20)), .line(v(20, 20))]),
        ]
        let outline = try EmboldenGeometry.trueTypeOutline(unionStyle, reversingDirection: true)
        let contours = EmboldenFixtures.contours(outline)
        #expect(contours.count == 2)
        #expect(EmboldenGeometry.quadraticArea(contours[0]) == -10_000, "outer clockwise")
        #expect(EmboldenGeometry.quadraticArea(contours[1]) == 3_600, "hole counter-clockwise")
        #expect(contours[0].first == on(0, 0), "starts at the contour's start point")

        // Outlines read back from glyf already run clockwise; turning them
        // would make the outer contour a hole.
        let kept = EmboldenFixtures.contours(
            try EmboldenGeometry.trueTypeOutline(unionStyle, reversingDirection: false))
        #expect(EmboldenGeometry.quadraticArea(kept[0]) == 10_000 && EmboldenGeometry.quadraticArea(kept[1]) == -3_600)
    }

    @Test func trueTypeOutlineRoundsHalfUpAndDropsDebrisAfterRounding() throws {
        let outline = try EmboldenGeometry.trueTypeOutline(
            [
                BezierContour(segments: [
                    .line(v(10.5, -0.5)), .line(v(10.5, 9.49)), .line(v(-0.5, 9.49)), .line(v(-0.5, -0.5)),
                ]),
                // 1.45 × 2.8 = 4.06 units² in float, 1 × 3 once rounded.
                BezierContour(segments: [
                    .line(v(51.45, 50)), .line(v(51.45, 52.8)), .line(v(50, 52.8)), .line(v(50, 50)),
                ]),
            ], reversingDirection: true)
        #expect(Set(outline.points.map { [$0.x, $0.y] }) == [[11, 0], [11, 9], [0, 9], [0, 0]])
        #expect(outline.endPoints == [3], "the second contour became debris when rounded")
    }
}

/// Risk grades and report output (technical design §5.2).
struct EmboldenReportTests {
    @Test func gradeThresholdsFollowTheDesign() {
        func grade(
            _ ratio: Double?, vanished: Bool = false, split: Bool = false, pinhole: Bool = false, growth: Double = 1
        )
            -> EmboldenGrade
        {
            EmboldenGrade.grade(
                minHoleRatio: ratio, holeVanished: vanished, holeSplit: split, pinhole: pinhole, bboxGrowth: growth)
        }
        #expect(grade(0.8, vanished: true) == .a)
        #expect(grade(0.39) == .a)
        #expect(grade(0.40) == .b)
        #expect(grade(0.54) == .b)
        #expect(grade(0.9, pinhole: true) == .b)
        #expect(grade(nil, growth: 2.01) == .b)
        #expect(grade(0.55) == .c)
        #expect(grade(0.69) == .c)
        #expect(grade(0.9, split: true) == .c)
        #expect(grade(0.70) == .d)
        #expect(grade(nil) == .d, "no counters, nothing to lose")
    }

    /// A counter narrower than the weight closes: the glyph must surface as A.
    @Test func closingCounterIsGradeA() throws {
        var font = try EmboldenFixtures.decomposedSynthetic()
        let narrow = try EmboldenFixtures.glyphID("uni4E00.alt")
        let open = try EmboldenFixtures.glyphID("u20000")
        font.glyphs[narrow] = Glyph(
            outline: .simple(
                EmboldenFixtures.outline([
                    EmboldenFixtures.rect(0, 0, 300, 300), EmboldenFixtures.rect(140, 50, 150, 250, clockwise: false),
                ])))
        font.glyphs[open] = Glyph(
            outline: .simple(
                EmboldenFixtures.outline([
                    EmboldenFixtures.rect(0, 0, 300, 300), EmboldenFixtures.rect(50, 50, 250, 250, clockwise: false),
                ])))
        let report = try font.embolden(EmboldenOptions(weight: 12))
        let closed = try #require(report.glyphs.first { $0.glyphID == narrow })
        #expect(closed.holeVanished)
        #expect(closed.minHoleRatio == 0)
        #expect(closed.grade == .a)
        #expect(EmboldenFixtures.contours(try EmboldenFixtures.simple(font.glyphs[narrow])).count == 1)
        let kept = try #require(report.glyphs.first { $0.glyphID == open })
        // 200² → 188²: ratio 0.8836.
        #expect(abs(kept.minHoleRatio! - 188.0 * 188 / (200 * 200)) < 0.001)
        #expect(kept.grade == .d)
        #expect(abs(kept.bboxGrowth - 1) < 0.001)
    }

    @Test func csvHasOneEscapedRowPerGlyph() throws {
        let measurement = EmboldenMeasurement(
            source: CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil),
            emboldened: CGPath(rect: CGRect(x: -6, y: -6, width: 22, height: 22), transform: nil), weight: 12)
        let report = EmboldenReport(glyphs: [
            EmboldenGlyphReport(glyphID: 7, codePoints: [0x2C, 0x4E00], weight: 12, measurement: measurement),
            EmboldenGlyphReport(glyphID: 9, codePoints: [], weight: 6.5, measurement: measurement),
        ])
        let lines = report.csv().split(separator: "\n", omittingEmptySubsequences: false)
        #expect(
            lines[0]
                == "glyph_id,code_points,text,weight,grade,counters,min_hole_ratio,hole_vanished,hole_split,pinhole,bbox_growth"
        )
        #expect(lines[1] == "7,U+002C U+4E00,\",一\",12,D,0,,0,0,0,1.0000")
        #expect(lines[2] == "9,,,6.5,D,0,,0,0,0,1.0000")
        #expect(lines.count == 4 && lines[3].isEmpty, "newline-terminated")
        #expect(report.count(of: .d) == 2)
    }

    @Test func riskSheetIsPNG() throws {
        let source = try EmboldenFixtures.decomposedSynthetic()
        var emboldened = source
        let report = try emboldened.embolden(EmboldenOptions(weight: 12))
        let pages = try report.riskSheet(
            source: source, emboldened: emboldened, grades: Set(EmboldenGrade.allCases), title: "test", perPage: 10)
        #expect(pages.count == (report.glyphs.count + 9) / 10)
        for page in pages {
            #expect(Array(page.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        }
    }
}
