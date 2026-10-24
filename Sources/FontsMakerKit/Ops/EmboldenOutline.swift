import CoreGraphics

/// One segment of a closed float contour; its start is the previous segment's end.
enum BezierSegment: Equatable {
    case line(Vec2)
    /// control, end
    case quad(Vec2, Vec2)
    /// control 1, control 2, end
    case cubic(Vec2, Vec2, Vec2)

    var end: Vec2 {
        switch self {
        case .line(let end), .quad(_, let end), .cubic(_, _, let end): return end
        }
    }

    /// Direction of travel leaving `start`; falls back along the control
    /// points when the first ones coincide with the start.
    func startTangent(from start: Vec2) -> Vec2 {
        let candidates: [Vec2]
        switch self {
        case .line(let end): candidates = [end]
        case .quad(let c, let end): candidates = [c, end]
        case .cubic(let c1, let c2, let end): candidates = [c1, c2, end]
        }
        return candidates.lazy.map { $0 - start }.first { $0 != .zero } ?? .zero
    }

    /// Direction of travel arriving at the end point.
    func endTangent(from start: Vec2) -> Vec2 {
        let candidates: [Vec2]
        switch self {
        case .line: candidates = [start]
        case .quad(let c, _): candidates = [c, start]
        case .cubic(let c1, let c2, _): candidates = [c2, c1, start]
        }
        return candidates.lazy.map { end - $0 }.first { $0 != .zero } ?? .zero
    }

    func isDegenerate(from start: Vec2) -> Bool {
        switch self {
        case .line(let end): return end == start
        case .quad(let c, let end): return c == start && end == start
        case .cubic(let c1, let c2, let end): return c1 == start && c2 == start && end == start
        }
    }

    /// Points along the segment after `start`, enough for debris area and extent.
    func samples(from start: Vec2) -> [Vec2] {
        switch self {
        case .line(let end):
            return [end]
        case .quad(let c, let end):
            return (1...4).map { step in
                let t = Double(step) / 4
                let u = 1 - t
                return u * u * start + 2 * u * t * c + t * t * end
            }
        case .cubic(let c1, let c2, let end):
            return (1...8).map { step in
                let t = Double(step) / 8
                let u = 1 - t
                return u * u * u * start + 3 * u * u * t * c1 + 3 * u * t * t * c2 + t * t * t * end
            }
        }
    }
}

/// A closed contour of float Bézier segments, as CGPath operations produce them.
struct BezierContour: Equatable {
    /// Never empty; the contour starts (and ends) at the last segment's end.
    var segments: [BezierSegment]

    func start(of index: Int) -> Vec2 { segments[(index + segments.count - 1) % segments.count].end }

    /// Contours of a path. Every subpath is treated as closed, as filling does.
    static func contours(of path: CGPath) -> [BezierContour] {
        var contours: [BezierContour] = []
        var segments: [BezierSegment] = []
        var subpathStart = Vec2.zero
        var current = Vec2.zero
        func finish() {
            if !segments.isEmpty {
                if current != subpathStart { segments.append(.line(subpathStart)) }
                contours.append(BezierContour(segments: segments))
            }
            segments.removeAll()
            current = subpathStart
        }
        func vec(_ p: CGPoint) -> Vec2 { Vec2(x: Double(p.x), y: Double(p.y)) }
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                finish()
                subpathStart = vec(e.points[0])
                current = subpathStart
            case .addLineToPoint:
                current = vec(e.points[0])
                segments.append(.line(current))
            case .addQuadCurveToPoint:
                current = vec(e.points[1])
                segments.append(.quad(vec(e.points[0]), current))
            case .addCurveToPoint:
                current = vec(e.points[2])
                segments.append(.cubic(vec(e.points[0]), vec(e.points[1]), current))
            case .closeSubpath:
                finish()
            @unknown default:
                break
            }
        }
        finish()
        return contours
    }

    mutating func removeDegenerateSegments() {
        var index = 0
        while segments.count > 1 && index < segments.count {
            if segments[index].isDegenerate(from: start(of: index)) {
                segments.remove(at: index)
            } else {
                index += 1
            }
        }
    }

    /// Removes back-tracking spurs: a short segment that runs back against both
    /// the segment before it and the one after it. CGPath's union leaves these
    /// where stroke edges meet (Phase 0: a 0.25-unit line stepping straight back
    /// between two curves). They are invisible, but rounding turns them into
    /// self-crossings. The following segment simply starts where the preceding
    /// one ends.
    ///
    /// "Back" means turning by more than `minTurn`: real spurs reverse by
    /// nearly 180°, while a short segment at about 90° to both neighbors is
    /// genuine geometry, such as the butt end of a thin slanted stroke.
    mutating func removeSpurs(maxLength: Double, minTurnCosine: Double = EmboldenGeometry.spurTurnCosine) {
        removeDegenerateSegments()
        func reverses(_ a: Vec2, _ b: Vec2) -> Bool { dot(a, b) < minTurnCosine * a.length * b.length }
        var index = 0
        while segments.count > 2 && index < segments.count {
            let count = segments.count
            let previousIndex = (index + count - 1) % count
            let nextIndex = (index + 1) % count
            let start = start(of: index)
            let chord = segments[index].end - start
            let incoming = segments[previousIndex].endTangent(from: self.start(of: previousIndex))
            let outgoing = segments[nextIndex].startTangent(from: segments[index].end)
            if chord.length <= maxLength && reverses(chord, incoming) && reverses(chord, outgoing) {
                segments.remove(at: index)
                // The neighbors changed; look at the previous segment again.
                index = max(0, index - 1)
            } else {
                index += 1
            }
        }
    }

    /// Debris: a contour that would collapse when rounded, or a sliver too
    /// thin to see (technical design §5.1: extent < 2 units or area < 4 units²).
    var isDebris: Bool {
        var polyline: [Vec2] = []
        for (index, segment) in segments.enumerated() {
            polyline.append(contentsOf: segment.samples(from: start(of: index)))
        }
        return isDebrisPolygon(polyline)
    }
}

func isDebrisPolygon(_ points: [Vec2]) -> Bool {
    guard points.count >= 3 else { return true }
    var minX = Double.infinity
    var minY = Double.infinity
    var maxX = -Double.infinity
    var maxY = -Double.infinity
    var doubledArea = 0.0
    for index in points.indices {
        let p = points[index]
        doubledArea += cross(p, points[(index + 1) % points.count])
        minX = min(minX, p.x)
        maxX = max(maxX, p.x)
        minY = min(minY, p.y)
        maxY = max(maxY, p.y)
    }
    return max(maxX - minX, maxY - minY) < EmboldenGeometry.debrisExtent
        || abs(doubledArea) / 2 < EmboldenGeometry.debrisArea
}

/// A TrueType point before encoding; on-curve points between two off-curve
/// ones are still explicit here.
struct QuadraticPoint: Equatable {
    var x: Double
    var y: Double
    var onCurve: Bool
}

enum EmboldenGeometry {
    static let debrisExtent = 2.0
    static let debrisArea = 4.0
    /// Phase 0 found every spur at 3 units or shorter.
    static let maxSpurLength = 3.0
    /// cos 135°: a spur turns back by more than 135° at both of its ends.
    static let spurTurnCosine = -0.7071
    /// cu2qu tolerance (technical design §5.1).
    static let curveTolerance = 1.0

    struct CurveApproximationFailed: Error {}

    /// Quadratic TrueType points of a float contour, in the contour's own
    /// direction. Implied on-curve points are kept explicit for now; they are
    /// dropped after rounding, and only where they are exact midpoints.
    static func quadraticPoints(_ contour: BezierContour) throws -> [QuadraticPoint] {
        var points: [QuadraticPoint] = []
        for (index, segment) in contour.segments.enumerated() {
            switch segment {
            case .line(let end):
                points.append(QuadraticPoint(x: end.x, y: end.y, onCurve: true))
            case .quad(let c, let end):
                points.append(QuadraticPoint(x: c.x, y: c.y, onCurve: false))
                points.append(QuadraticPoint(x: end.x, y: end.y, onCurve: true))
            case .cubic(let c1, let c2, let end):
                guard
                    let spline = Cu2qu.quadraticSpline(
                        contour.start(of: index), c1, c2, end, tolerance: curveTolerance)
                else { throw CurveApproximationFailed() }
                let controls = spline[1..<(spline.count - 1)]
                var previous: Vec2?
                for control in controls {
                    if let previous {
                        let mid = (previous + control) * 0.5
                        points.append(QuadraticPoint(x: mid.x, y: mid.y, onCurve: true))
                    }
                    points.append(QuadraticPoint(x: control.x, y: control.y, onCurve: false))
                    previous = control
                }
                points.append(QuadraticPoint(x: end.x, y: end.y, onCurve: true))
            }
        }
        return points
    }

    /// Rounds half up (fontTools otRound), like decomposition does.
    static func rounded(_ value: Double) -> Int32 { Int32((value + 0.5).rounded(.down)) }

    /// Integer contour cleanup after rounding: drops off-curve points that
    /// coincide with a neighbor (the curve has become a straight line), and
    /// on-curve duplicates. Returns nil when the contour degenerates to debris.
    static func cleanedIntegerContour(_ contour: [GlyphPoint]) -> [GlyphPoint]? {
        var points = contour
        var changed = true
        while changed && points.count >= 3 {
            changed = false
            var index = 0
            while index < points.count && points.count >= 3 {
                let count = points.count
                let point = points[index]
                let previous = points[(index + count - 1) % count]
                let next = points[(index + 1) % count]
                let samePlace = { (a: GlyphPoint, b: GlyphPoint) in a.x == b.x && a.y == b.y }
                let redundant =
                    point.onCurve
                    ? next.onCurve && samePlace(point, next)
                    // Off-curve on top of a neighbor, or a curve out and straight back.
                    : samePlace(point, previous) || samePlace(point, next)
                        || (previous.onCurve && next.onCurve && samePlace(previous, next))
                if redundant {
                    points.remove(at: index)
                    changed = true
                } else {
                    index += 1
                }
            }
        }
        guard points.count >= 3 else { return nil }
        let polygon = points.map { Vec2(x: Double($0.x), y: Double($0.y)) }
        if max(extent(polygon).width, extent(polygon).height) < debrisExtent { return nil }
        if abs(quadraticArea(points)) < debrisArea { return nil }
        return points
    }

    private static func extent(_ points: [Vec2]) -> (width: Double, height: Double) {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        return (xs.max()! - xs.min()!, ys.max()! - ys.min()!)
    }

    /// Exact signed area (y up, counter-clockwise positive) of a contour whose
    /// off-curve points are all isolated between on-curve points: the chord
    /// polygon plus 2/3 of each control triangle.
    static func quadraticArea(_ points: [GlyphPoint]) -> Double {
        guard let firstOn = points.firstIndex(where: \.onCurve) else { return 0 }
        let count = points.count
        func vec(_ p: GlyphPoint) -> Vec2 { Vec2(x: Double(p.x), y: Double(p.y)) }
        var doubled = 0.0
        var anchor = vec(points[firstOn])
        var control: Vec2?
        for step in 1...count {
            let point = points[(firstOn + step) % count]
            if !point.onCurve {
                control = vec(point)
                continue
            }
            let end = vec(point)
            doubled += cross(anchor, end)
            if let c = control { doubled += (2.0 / 3) * cross(c - anchor, end - anchor) }
            control = nil
            anchor = end
        }
        return doubled / 2
    }

    /// Indices of on-curve points that sit exactly midway between two
    /// off-curve neighbors; TrueType implies them, so writing them is waste.
    static func impliedOnCurveIndices(_ points: [GlyphPoint]) -> Set<Int> {
        var implied = Set<Int>()
        let count = points.count
        for (index, point) in points.enumerated() where point.onCurve {
            let previous = points[(index + count - 1) % count]
            let next = points[(index + 1) % count]
            if !previous.onCurve && !next.onCurve && previous.x + next.x == 2 * point.x
                && previous.y + next.y == 2 * point.y
            {
                implied.insert(index)
            }
        }
        return implied
    }

    /// Float contours → TrueType outline: cu2qu, optional reversal to
    /// clockwise outer contours, rounding, cleanup and dropping implied
    /// on-curve points.
    ///
    /// Union output and CFF outlines have counter-clockwise outer contours
    /// (y up), the opposite of TrueType, so they are reversed; outlines that
    /// come from glyf already run the TrueType way.
    static func trueTypeOutline(_ contours: [BezierContour], reversingDirection: Bool) throws -> SimpleOutline {
        var outline = SimpleOutline()
        for contour in contours {
            let points = try quadraticPoints(contour)
            let ordered = reversingDirection ? Array(points.reversed()) : points
            let integer = ordered.map { GlyphPoint(x: rounded($0.x), y: rounded($0.y), onCurve: $0.onCurve) }
            guard let cleaned = cleanedIntegerContour(integer) else { continue }
            let implied = impliedOnCurveIndices(cleaned)
            let kept = cleaned.indices.filter { !implied.contains($0) }.map { cleaned[$0] }
            outline.points.append(contentsOf: kept)
            outline.endPoints.append(outline.points.count - 1)
        }
        return outline
    }
}
