import Foundation
import Testing

@testable import FontsMakerKit

/// Shared helpers: outlines are built in code on top of synthetic.ttf.
enum EmboldenFixtures {
    static func decomposedSynthetic() throws -> Font {
        var font = try Fixtures.font("synthetic.ttf")
        try font.decomposeComposites()
        return font
    }

    static func glyphID(_ name: String) throws -> Int { try Fixtures.expectation().glyphID(name) }

    static func simple(_ glyph: Glyph) throws -> SimpleOutline {
        guard case .simple(let outline) = glyph.outline else {
            Issue.record("expected a simple glyph")
            throw CancellationError()
        }
        return outline
    }

    static func contours(_ outline: SimpleOutline) -> [[GlyphPoint]] {
        outline.contourRanges.map { Array(outline.points[$0]) }
    }

    static func bounds(_ outline: SimpleOutline) -> (Int32, Int32, Int32, Int32) {
        (
            outline.points.map(\.x).min()!, outline.points.map(\.y).min()!, outline.points.map(\.x).max()!,
            outline.points.map(\.y).max()!
        )
    }

    static func rect(_ x0: Int32, _ y0: Int32, _ x1: Int32, _ y1: Int32, clockwise: Bool = true) -> [GlyphPoint] {
        let points = [(x0, y0), (x0, y1), (x1, y1), (x1, y0)].map { GlyphPoint(x: $0.0, y: $0.1, onCurve: true) }
        return clockwise ? points : points.reversed()
    }

    static func outline(_ contours: [[GlyphPoint]]) -> SimpleOutline {
        var outline = SimpleOutline()
        for contour in contours {
            outline.points.append(contentsOf: contour)
            outline.endPoints.append(outline.points.count - 1)
        }
        return outline
    }

    /// The synthetic glyphs repeated up to `count`, for tests that need many batches.
    static func manyGlyphs(_ count: Int) throws -> Font {
        var font = try decomposedSynthetic()
        let glyphs = font.glyphs
        let metrics = font.horizontalMetrics
        font.glyphs = (0..<count).map { glyphs[$0 % glyphs.count] }
        font.horizontalMetrics = (0..<count).map { metrics[$0 % metrics.count] }
        // The writer checks every per-glyph table against the glyph count.
        if let vertical = font.verticalMetrics {
            font.verticalMetrics = (0..<count).map { vertical[$0 % vertical.count] }
        }
        return font
    }
}

/// Counts callback invocations across threads.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int, Int)] = []

    func record(_ completed: Int, _ total: Int) { lock.withLock { values.append((completed, total)) } }
    var calls: [(Int, Int)] { lock.withLock { values } }
}

struct EmboldenTests {
    typealias F = EmboldenFixtures

    /// Every edge moves out by weight/2; the counter shrinks by the same amount.
    /// Outer contours come out clockwise and counters counter-clockwise (y up),
    /// TrueType's convention, although CGPath's union returns the opposite.
    @Test func squareWithCounterGrowsByHalfTheWeightAndKeepsTrueTypeDirection() throws {
        var font = try F.decomposedSynthetic()
        let notdef = 0
        #expect(
            F.contours(try F.simple(font.glyphs[notdef])) == [
                F.rect(50, 0, 450, 700), F.rect(100, 50, 400, 650, clockwise: false),
            ])
        _ = try font.embolden(EmboldenOptions(weight: 12))
        let result = F.contours(try F.simple(font.glyphs[notdef]))
        #expect(result.count == 2)
        let byArea = result.map { ($0, EmboldenGeometry.quadraticArea($0)) }.sorted { abs($0.1) > abs($1.1) }
        let outer = try #require(byArea.first)
        let counter = try #require(byArea.last)
        #expect(outer.1 == -Double(412 * 712), "outer: clockwise 44…456 × -6…706")
        #expect(counter.1 == Double(288 * 588), "counter: counter-clockwise 106…394 × 56…644")
        #expect(Set(outer.0.map { [$0.x, $0.y] }) == [[44, -6], [44, 706], [456, 706], [456, -6]])
        #expect(Set(counter.0.map { [$0.x, $0.y] }) == [[106, 56], [106, 644], [394, 644], [394, 56]])
        #expect(result.joined().allSatisfy { $0.onCurve }, "a rectangle stays straight lines")
    }

    @Test func curvesBecomeQuadraticsWithinOneUnit() throws {
        var font = try F.decomposedSynthetic()
        let ring = try F.glyphID("ring")
        let source = try F.simple(font.glyphs[ring])
        _ = try font.embolden(EmboldenOptions(weight: 12))
        let result = try F.simple(font.glyphs[ring])
        // The ring is a quadratic "circle" around (100, 100): radius 100 at its
        // four on-curve extremes, about 106 midway between them.
        #expect(F.bounds(source) == (0, 0, 200, 200))
        let box = result.cgPath.boundingBoxOfPath
        for (actual, expected) in [(box.minX, -6.0), (box.minY, -6), (box.maxX, 206), (box.maxY, 206)] {
            #expect(abs(actual - expected) <= 1, "bounds \(box)")
        }
        #expect(result.points.contains { !$0.onCurve }, "curves stay curves")
        for point in result.points where point.onCurve {
            // Offset by 6, then cu2qu (≤ 1 unit) and rounding (≤ 0.71).
            let radius = hypot(Double(point.x) - 100, Double(point.y) - 100)
            #expect((104...114).contains(radius), "on-curve point \(point) at radius \(radius)")
        }
        let contours = flattenedContours(result.cgPath)
        #expect(contours.count == 1)
        #expect(contours.allSatisfy { $0.area < 0 }, "clockwise")
    }

    /// Design §4.2: a glyph shared by several code points is emboldened once.
    @Test func sharedGlyphIsEmboldenedOnce() throws {
        var font = try F.decomposedSynthetic()
        let shared = try F.glyphID("uni4E00")
        #expect(
            [0x4E00, 0x2F00, 0x31D0].map { font.characterMap.mappings[UInt32($0)].map(Int.init) } == [
                shared, shared, shared,
            ])
        let report = try font.embolden(EmboldenOptions(weight: 12))
        // rect(60, 330, 940, 430) grows by 6 per side once, not three times.
        #expect(F.bounds(try F.simple(font.glyphs[shared])) == (54, 324, 946, 436))
        let entries = report.glyphs.filter { $0.glyphID == shared }
        #expect(entries.count == 1)
        #expect(entries.first?.codePoints == [0x2F00, 0x31D0, 0x4E00])
        #expect(Set(report.glyphs.map(\.glyphID)).count == report.glyphs.count, "one entry per glyph ID")
    }

    /// Unencoded glyphs (vertical forms, alternates) are emboldened too.
    @Test func everyGlyphWithAnOutlineIsEmboldenedAndAdvancesStay() throws {
        let source = try F.decomposedSynthetic()
        var font = source
        let report = try font.embolden(EmboldenOptions(weight: 12))
        let withOutline = source.glyphs.indices.filter {
            if case .simple(let outline) = source.glyphs[$0].outline { return !outline.isEmpty }
            return false
        }
        #expect(report.glyphs.map(\.glyphID) == withOutline)
        #expect(report.glyphs.contains { $0.codePoints.isEmpty }, "fixture has unencoded glyphs")
        #expect(font.horizontalMetrics.map(\.advanceWidth) == source.horizontalMetrics.map(\.advanceWidth))
        for glyphID in source.glyphs.indices where !withOutline.contains(glyphID) {
            #expect(font.glyphs[glyphID] == source.glyphs[glyphID], "empty glyph \(glyphID) untouched")
        }
        for glyphID in withOutline {
            #expect(font.glyphs[glyphID].instructions.isEmpty, "stale instructions dropped from \(glyphID)")
        }
    }

    @Test func skipAndPerGlyphWeight() throws {
        let source = try F.decomposedSynthetic()
        let skipped = try F.glyphID("uni3001")
        let heavier = try F.glyphID("uni3002")
        let zero = try F.glyphID("uniFF08")
        var font = source
        let report = try font.embolden(
            EmboldenOptions(weight: 12, skip: [skipped], perGlyphWeight: [heavier: 30, zero: 0]))
        #expect(font.glyphs[skipped] == source.glyphs[skipped], "skipped glyph keeps its bytes")
        #expect(font.glyphs[zero] == source.glyphs[zero], "weight 0 keeps its bytes")
        // rect(100, 0, 300, 200) at weight 30: 15 per side.
        #expect(F.bounds(try F.simple(font.glyphs[heavier])) == (85, -15, 315, 215))
        #expect(report.glyphs.first { $0.glyphID == heavier }?.weight == 30)
        #expect(!report.glyphs.contains { $0.glyphID == skipped || $0.glyphID == zero })
        // rect(100, 0, 250, 150) elsewhere at the default weight.
        let other = try F.glyphID("uni3001.vert")
        #expect(F.bounds(try F.simple(font.glyphs[other])) == (644, 644, 806, 806))
    }

    @Test func zeroWeightLeavesTheFontUntouched() throws {
        let source = try F.decomposedSynthetic()
        var font = source
        let report = try font.embolden(EmboldenOptions(weight: 0))
        #expect(report.glyphs.isEmpty)
        #expect(font.glyphs == source.glyphs)
        #expect(try font.serialize(options: WriteOptions()) == source.serialize(options: WriteOptions()))
    }

    @Test func compositesMustBeDecomposedFirst() throws {
        var font = try Fixtures.font("synthetic.ttf")
        let firstComposite = try #require(font.glyphs.firstIndex { $0.isComposite })
        let before = font.glyphs
        #expect(throws: EmboldenError.compositeGlyph(glyphID: firstComposite)) {
            try font.embolden(EmboldenOptions(weight: 12))
        }
        #expect(font.glyphs == before)
    }

    @Test func invalidOptionsAreRejected() throws {
        var font = try F.decomposedSynthetic()
        let count = font.glyphs.count
        for options in [
            EmboldenOptions(weight: -1), EmboldenOptions(weight: .nan), EmboldenOptions(weight: 12, miterLimit: 0),
            EmboldenOptions(weight: 12, skip: [count]), EmboldenOptions(weight: 12, perGlyphWeight: [-1: 4]),
            EmboldenOptions(weight: 12, perGlyphWeight: [1: .infinity]),
        ] {
            #expect(throws: EmboldenError.self) { try font.embolden(options) }
        }
    }

    @Test func progressReachesTheTotalInOrder() throws {
        var font = try F.manyGlyphs(100)
        let log = ProgressLog()
        let report = try font.embolden(EmboldenOptions(weight: 12)) { completed, total in
            log.record(completed, total)
            return true
        }
        let total = report.glyphs.count
        #expect(total > 80, "most synthetic glyphs have outlines")
        let calls = log.calls
        #expect(calls.allSatisfy { $0.1 == total })
        #expect(calls.last?.0 == total)
        #expect(zip(calls, calls.dropFirst()).allSatisfy { $0.0 < $1.0 }, "counts only grow")
        #expect(calls.count == (total + 15) / 16, "one call per batch of 16")
    }

    @Test(arguments: [1, 4])
    func returningFalseFromProgressCancels(maxConcurrency: Int) throws {
        let source = try F.manyGlyphs(200)
        var font = source
        let log = ProgressLog()
        #expect(throws: CancellationError.self) {
            try font.embolden(EmboldenOptions(weight: 12), maxConcurrency: maxConcurrency) { completed, total in
                log.record(completed, total)
                return false
            }
        }
        #expect(font.glyphs == source.glyphs, "a cancelled run leaves the font unchanged")
        #expect(log.calls.count == 1, "no further callbacks after cancelling")
        if maxConcurrency == 1 {
            #expect(log.calls.first?.0 == 16, "single worker stops after its first batch")
        }
    }

    /// Design §8: output independent of thread scheduling.
    @Test func resultDoesNotDependOnConcurrency() throws {
        var serial = try F.manyGlyphs(240)
        var parallel = serial
        let serialReport = try serial.embolden(EmboldenOptions(weight: 12), maxConcurrency: 1)
        let parallelReport = try parallel.embolden(EmboldenOptions(weight: 12))
        #expect(serial.glyphs == parallel.glyphs)
        #expect(serialReport == parallelReport)
        let options = WriteOptions(stripHinting: true)
        #expect(try serial.serialize(options: options) == parallel.serialize(options: options))
        // The same input glyph on different workers gives the same output.
        let period = try F.decomposedSynthetic().glyphs.count
        #expect(parallel.glyphs.indices.allSatisfy { parallel.glyphs[$0] == parallel.glyphs[$0 % period] })
    }

    @Test func emboldenedFontReadsBackIdentically() throws {
        var font = try F.decomposedSynthetic()
        _ = try font.embolden(EmboldenOptions(weight: 12))
        let bytes = try font.serialize(options: WriteOptions(stripHinting: true))
        let reread = try Font(bytes: bytes)
        #expect(reread.glyphs == font.glyphs)
        #expect(reread.tables["fpgm"] == nil && reread.tables["prep"] == nil)
    }
}
