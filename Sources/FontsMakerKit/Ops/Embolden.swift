import CoreGraphics
import Foundation

/// Parameters of the embolden operation (technical design §5.1), keyed by glyph ID.
public struct EmboldenOptions: Equatable, Sendable {
    /// Total stem increase in font units: every edge moves out by weight/2.
    /// 1:1 with FontForge `changeWeight` (Phase 0).
    public var weight: Double
    public var miterLimit: Double
    /// Glyph IDs left untouched.
    public var skip: Set<Int>
    /// Glyph ID → weight replacing `weight` for that glyph.
    public var perGlyphWeight: [Int: Double]
    /// Each emboldened glyph's advance grows by as much as its outline did,
    /// and the outline moves so both side bearings stay the source's
    /// (`Font.embolden`). Off, advances stay as they are (design §5.1).
    public var widen: Bool

    public init(
        weight: Double, miterLimit: Double = 4, skip: Set<Int> = [], perGlyphWeight: [Int: Double] = [:],
        widen: Bool = false
    ) {
        self.weight = weight
        self.miterLimit = miterLimit
        self.skip = skip
        self.perGlyphWeight = perGlyphWeight
        self.widen = widen
    }

    /// 0 means the glyph stays as it is.
    func weight(for glyphID: Int) -> Double {
        if skip.contains(glyphID) { return 0 }
        return perGlyphWeight[glyphID] ?? weight
    }

    func validate(glyphCount: Int) throws {
        func check(_ value: Double, _ what: String) throws {
            guard value.isFinite, value >= 0 else {
                throw EmboldenError.invalidOption("\(what) must be a finite number ≥ 0, got \(value)")
            }
        }
        try check(weight, "weight")
        guard miterLimit.isFinite, miterLimit > 0 else {
            throw EmboldenError.invalidOption("miter limit must be a finite number > 0, got \(miterLimit)")
        }
        for (glyphID, value) in perGlyphWeight.sorted(by: { $0.key < $1.key }) {
            try check(value, "weight of glyph \(glyphID)")
        }
        // A glyph ID the font does not have means the caller resolved
        // characters against a different font; ignoring it would hide that.
        let unknown = (skip.union(perGlyphWeight.keys)).filter { !(0..<glyphCount).contains($0) }.sorted()
        if let first = unknown.first {
            throw EmboldenError.invalidOption("glyph \(first) does not exist; the font has \(glyphCount) glyphs")
        }
    }
}

public enum EmboldenError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    /// Composites must be decomposed first (technical design §4.1), or a
    /// component would be emboldened once per use and scaled with its parent.
    case compositeGlyph(glyphID: Int)
    case invalidOption(String)
    /// cu2qu found no quadratic spline within tolerance for some curve.
    case curveApproximationFailed(glyphID: Int)

    public var description: String {
        switch self {
        case .compositeGlyph(let glyphID):
            return "Glyph \(glyphID) is a composite; decompose composite glyphs before emboldening."
        case .invalidOption(let detail):
            return "Invalid embolden option: \(detail)"
        case .curveApproximationFailed(let glyphID):
            return "Glyph \(glyphID): a curve could not be converted to TrueType quadratics within tolerance."
        }
    }

    public var errorDescription: String? { description }
}

extension Font {
    /// Emboldens every glyph that has an outline, whether or not a character
    /// maps to it, each glyph ID exactly once (technical design §4.2). Advance
    /// widths stay unchanged (§5.1) unless `options.widen`: then a glyph with
    /// an advance grows by exactly what its bounding box gained, and moves
    /// right by what it gained on the left, so its side bearings, the space
    /// between letters, stay the source's. The bounding box rather than
    /// weight/2 per side: miter joins at sharp corners (V, A, serifs) reach
    /// further than weight/2, which would still crowd those letters.
    /// Zero-width glyphs (combining marks) keep advance 0 and do not move.
    /// A monospaced font stays monospaced (`widenPlan`), and GPOS anchors move
    /// with the outlines they belong to (`GPOSAnchors`). Glyphs whose weight
    /// is 0 or that are in `skip` keep their outline byte for byte, except
    /// that widen moves them to the middle of a monospaced font's wider cell.
    /// Emboldened glyphs lose their instructions, which no longer match the outline.
    ///
    /// Glyphs are processed in parallel; the result does not depend on scheduling.
    /// On any error, including cancellation, the font is left unchanged.
    ///
    /// - Parameters:
    ///   - maxConcurrency: worker threads; nil uses every active core. Only
    ///     affects speed (used for single-thread timing).
    ///   - progress: called after each batch of glyphs, from worker threads but
    ///     never concurrently, with a non-decreasing count. Return false to
    ///     cancel; the call then throws `CancellationError`.
    /// - Throws: `EmboldenError.compositeGlyph` unless composites were decomposed first.
    public mutating func embolden(
        _ options: EmboldenOptions,
        maxConcurrency: Int? = nil,
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Bool)? = nil
    ) throws -> EmboldenReport {
        try options.validate(glyphCount: glyphs.count)
        if let composite = glyphs.firstIndex(where: \.isComposite) {
            throw EmboldenError.compositeGlyph(glyphID: composite)
        }
        var jobs: [EmboldenJob] = []
        for (glyphID, glyph) in glyphs.enumerated() {
            guard case .simple(let outline) = glyph.outline, !outline.isEmpty else { continue }
            let weight = options.weight(for: glyphID)
            if weight > 0 { jobs.append(EmboldenJob(glyphID: glyphID, outline: outline, weight: weight)) }
        }
        let results = try EmboldenJob.runAll(
            jobs, miterLimit: options.miterLimit, maxConcurrency: maxConcurrency, progress: progress)

        var codePoints: [Int: [UInt32]] = [:]
        for (codePoint, glyphID) in characterMap.mappings { codePoints[Int(glyphID), default: []].append(codePoint) }
        var entries: [EmboldenGlyphReport] = []
        entries.reserveCapacity(jobs.count)
        // Widened first, into copies: a failure must leave the font unchanged.
        let plan =
            options.widen
            ? try widenPlan(zip(jobs, results).map { ($0.glyphID, $0.outline, $1.outline) }, options: options)
            : WidenPlan(metrics: horizontalMetrics, shifts: [:], monospace: nil)
        // Accents attach at GPOS anchors, which must move with the outlines.
        let gpos = try gposWithMovedAnchors(plan.shifts)
        for (job, result) in zip(jobs, results) {
            glyphs[job.glyphID] = Glyph(outline: .simple(result.outline.shifted(by: plan.shifts[job.glyphID] ?? 0)))
            entries.append(
                EmboldenGlyphReport(
                    glyphID: job.glyphID, codePoints: (codePoints[job.glyphID] ?? []).sorted(), weight: job.weight,
                    measurement: result.measurement))
        }
        // Monospaced fonts also move the glyphs left as they are (`widenPlan`).
        for (glyphID, shift) in plan.shifts where options.weight(for: glyphID) == 0 {
            if case .simple(let outline) = glyphs[glyphID].outline {
                glyphs[glyphID] = Glyph(outline: .simple(outline.shifted(by: shift)))
            }
        }
        if let gpos { tables["GPOS"] = gpos.table }
        if plan.metrics != horizontalMetrics {
            horizontalMetrics = plan.metrics
            // Design §4.3: an operation that changes advances owns xAvgCharWidth.
            let average = averageAdvanceWidth()
            os2?.xAvgCharWidth = average
        }
        return EmboldenReport(glyphs: entries, monospace: plan.monospace, anchorsMoved: gpos?.glyphs ?? 0)
    }
}

/// Counter metrics of one emboldened glyph (technical design §5.2).
struct EmboldenMeasurement: Equatable, Sendable {
    var counters: Int
    var minHoleRatio: Double?
    var holeVanished: Bool
    var holeSplit: Bool
    var pinhole: Bool
    var bboxGrowth: Double

    /// Source counters come from the normalized source, so overlapping
    /// strokes that enclose a counter count the same way as in the union output.
    init(source: CGPath, emboldened: CGPath, weight: Double) {
        let before = OutlineStats(source.normalized(using: .winding))
        let after = OutlineStats(emboldened)
        let match = matchHoles(before: before.holes, after: after.holes)
        counters = match.counters
        minHoleRatio = match.minRatio
        holeVanished = match.vanished > 0
        holeSplit = match.split > 0
        pinhole = (match.newMinArea ?? .infinity) < pinholeArea
        if before.bounds.isNull || after.bounds.isNull {
            bboxGrowth = 0
        } else {
            bboxGrowth =
                max(after.bounds.width - before.bounds.width, after.bounds.height - before.bounds.height) / weight
        }
    }
}

struct EmboldenJob: Sendable {
    var glyphID: Int
    var outline: SimpleOutline
    var weight: Double

    struct Output {
        var outline: SimpleOutline
        var measurement: EmboldenMeasurement
    }

    /// bold = outline ∪ stroke(outline): cleanup, cu2qu, TrueType direction,
    /// integer coordinates.
    func run(miterLimit: Double) throws -> Output {
        let source = EmboldenJob.strokableSource(outline).cgPath
        let stroke = source.copy(
            strokingWithWidth: weight, lineCap: .butt, lineJoin: .miter, miterLimit: miterLimit)
        let bold = source.union(stroke, using: .winding)
        var contours = BezierContour.contours(of: bold)
        for index in contours.indices {
            contours[index].removeSpurs(maxLength: EmboldenGeometry.maxSpurLength)
        }
        contours.removeAll { $0.isDebris }
        let result: SimpleOutline
        do {
            result = try EmboldenGeometry.trueTypeOutline(contours, reversingDirection: true)
        } catch is EmboldenGeometry.CurveApproximationFailed {
            throw EmboldenError.curveApproximationFailed(glyphID: glyphID)
        }
        return Output(
            outline: result, measurement: EmboldenMeasurement(source: source, emboldened: result.cgPath, weight: weight)
        )
    }

    /// Contours that enclose no area render nothing in TrueType, but stroking
    /// them would draw a visible line, so they are left out.
    static func strokableSource(_ outline: SimpleOutline) -> SimpleOutline {
        var kept = SimpleOutline()
        for range in outline.contourRanges {
            let points = outline.points[range]
            guard points.count >= 3, !isCollinear(points) else { continue }
            kept.points.append(contentsOf: points)
            kept.endPoints.append(kept.points.count - 1)
        }
        return kept
    }

    private static func isCollinear(_ points: ArraySlice<GlyphPoint>) -> Bool {
        guard let origin = points.first, let other = points.first(where: { $0.x != origin.x || $0.y != origin.y })
        else { return true }
        let dx = Int64(other.x - origin.x)
        let dy = Int64(other.y - origin.y)
        return points.allSatisfy { Int64($0.x - origin.x) * dy == Int64($0.y - origin.y) * dx }
    }

    /// Batches handed to workers; small enough to balance slow glyphs, large
    /// enough that locking and progress calls are negligible.
    static let batchSize = 16

    static func runAll(
        _ jobs: [EmboldenJob], miterLimit: Double, maxConcurrency: Int?,
        progress: (@Sendable (Int, Int) -> Bool)?
    ) throws -> [Output] {
        let state = RunState(total: jobs.count, progress: progress)
        let slots = ResultSlots(count: jobs.count)
        let batches = (jobs.count + batchSize - 1) / batchSize
        let workers = max(1, min(maxConcurrency ?? ProcessInfo.processInfo.activeProcessorCount, batches))
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            while let range = state.claim(batchSize) {
                for index in range {
                    // CoreGraphics autoreleases temporaries; drain them per glyph
                    // so memory stays flat across 25,000 glyphs.
                    slots.store(index, autoreleasepool { Swift.Result { try jobs[index].run(miterLimit: miterLimit) } })
                }
                state.finish(range.count)
            }
        }
        if state.isCancelled { throw CancellationError() }
        // Report the lowest failing glyph ID so the error is deterministic too.
        return try (0..<jobs.count).map { try slots.take($0).get() }
    }
}

/// Work queue and progress shared by the workers.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int
    private let progress: (@Sendable (Int, Int) -> Bool)?
    private var claimed = 0
    private var completed = 0
    private var cancelled = false

    init(total: Int, progress: (@Sendable (Int, Int) -> Bool)?) {
        self.total = total
        self.progress = progress
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func claim(_ size: Int) -> Range<Int>? {
        lock.withLock {
            guard !cancelled, claimed < total else { return nil }
            let range = claimed..<min(total, claimed + size)
            claimed = range.upperBound
            return range
        }
    }

    /// Under the lock, so the callback is never re-entered and counts only grow.
    func finish(_ count: Int) {
        lock.withLock {
            completed += count
            if !cancelled, let progress, !progress(completed, total) { cancelled = true }
        }
    }
}

/// One slot per job, each written by exactly one worker.
private final class ResultSlots: @unchecked Sendable {
    private let slots: UnsafeMutableBufferPointer<Result<EmboldenJob.Output, Error>?>

    init(count: Int) {
        slots = .allocate(capacity: count)
        slots.initialize(repeating: nil)
    }

    deinit {
        slots.deinitialize()
        slots.deallocate()
    }

    func store(_ index: Int, _ result: Result<EmboldenJob.Output, Error>) { slots[index] = result }

    func take(_ index: Int) -> Result<EmboldenJob.Output, Error> { slots[index]! }
}
