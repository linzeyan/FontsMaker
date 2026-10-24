import CoreGraphics
import Foundation

struct EmboldenParams {
    var weight: CGFloat
    var join: CGLineJoin
    var miterLimit: CGFloat

    var label: String {
        join == .round ? "round" : String(format: "miter%g", Double(miterLimit))
    }
}

func parseJoin(_ s: String) -> CGLineJoin {
    switch s {
    case "miter": return .miter
    case "round": return .round
    case "bevel": return .bevel
    default: fail("unknown join \(s)")
    }
}

/// bold = outline ∪ stroke(outline). Stroking every contour (including the
/// internal edges of overlapping source contours) is safe: stroke(∂A) ⊂ A ⊕ D,
/// so the union equals the Minkowski offset of the filled region either way.
func embolden(_ path: CGPath, _ p: EmboldenParams) -> (bold: CGPath, stroke: CGPath) {
    let stroke = path.copy(strokingWithWidth: p.weight, lineCap: .butt, lineJoin: p.join,
                           miterLimit: p.miterLimit)
    return (path.union(stroke, using: .winding), stroke)
}

/// One closed subpath, flattened to a polyline for area/containment math.
struct Contour {
    var pts: [CGPoint]
    var area: Double  // signed shoelace area, y-up font units (> 0 = counter-clockwise)
    var perimeter: Double
    var bbox: CGRect
}

private func makeContour(_ pts: [CGPoint]) -> Contour {
    var a = 0.0, per = 0.0
    var minX = Double.infinity, minY = Double.infinity
    var maxX = -Double.infinity, maxY = -Double.infinity
    let n = pts.count
    for i in 0..<n {
        let p = pts[i], q = pts[(i + 1) % n]
        a += Double(p.x * q.y - q.x * p.y)
        per += Double(hypot(q.x - p.x, q.y - p.y))
        minX = min(minX, Double(p.x)); maxX = max(maxX, Double(p.x))
        minY = min(minY, Double(p.y)); maxY = max(maxY, Double(p.y))
    }
    return Contour(pts: pts, area: a / 2, perimeter: per,
                   bbox: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
}

func flattenContours(_ path: CGPath, flatness: CGFloat = 0.2) -> [Contour] {
    var out: [Contour] = []
    var cur: [CGPoint] = []
    var lastMove = CGPoint.zero
    func finish() {
        if cur.count >= 2 {
            if cur.count > 2, cur.first == cur.last { cur.removeLast() }
            out.append(makeContour(cur))
        }
        cur.removeAll(keepingCapacity: true)
    }
    path.flattened(threshold: flatness).applyWithBlock { el in
        let e = el.pointee
        switch e.type {
        case .moveToPoint:
            finish()
            lastMove = e.points[0]
            cur.append(lastMove)
        case .addLineToPoint:
            if cur.isEmpty { cur.append(lastMove) }
            cur.append(e.points[0])
        case .closeSubpath:
            finish()
        default:
            fail("flattened path still contains curves")
        }
    }
    finish()
    return out
}

struct SegCounts {
    var moves = 0, lines = 0, quads = 0, cubics = 0
    /// TrueType-like point count: on-curve start + on/off points per segment.
    var points: Int { moves + lines + 2 * quads + 3 * cubics }
}

func segCounts(_ path: CGPath) -> SegCounts {
    var c = SegCounts()
    path.applyWithBlock { el in
        switch el.pointee.type {
        case .moveToPoint: c.moves += 1
        case .addLineToPoint: c.lines += 1
        case .addQuadCurveToPoint: c.quads += 1
        case .addCurveToPoint: c.cubics += 1
        case .closeSubpath: break
        @unknown default: break
        }
    }
    return c
}

/// Contours split into outer/hole by sign relative to the largest contour.
/// Only valid on weakly-simple paths (normalized source, union output).
struct OutlineStats {
    static let debrisExtent: CGFloat = 2  // collapses to a point when rounded to integer units
    static let tinyArea = 4.0  // < 2x2 units: a sliver, not a real stroke or counter
    static let smallArea = 100.0

    var empty: Bool
    var contours: [Contour] = []
    var outer: [Contour] = []
    var holes: [Contour] = []
    var debris = 0
    var tiny = 0
    var small = 0
    var dominantSign = 0.0
    var bbox = CGRect.null

    var holeArea: Double { holes.reduce(0) { $0 + abs($1.area) } }
    var filledArea: Double { outer.reduce(0) { $0 + abs($1.area) } - holeArea }
    var perimeter: Double { contours.reduce(0) { $0 + $1.perimeter } }

    init(_ path: CGPath) {
        empty = path.isEmpty
        if empty { return }
        bbox = path.boundingBoxOfPath
        let all = flattenContours(path)
        for c in all {
            if max(c.bbox.width, c.bbox.height) < Self.debrisExtent { debris += 1; continue }
            if abs(c.area) < Self.tinyArea { tiny += 1; continue }
            if abs(c.area) < Self.smallArea { small += 1 }
            contours.append(c)
        }
        guard let dom = contours.max(by: { abs($0.area) < abs($1.area) }) else { return }
        dominantSign = dom.area > 0 ? 1 : -1
        for c in contours {
            if c.area * dominantSign > 0 { outer.append(c) } else { holes.append(c) }
        }
    }
}

/// Approximates what a TrueType writer would emit: every point rounded to
/// integer font units, zero-length segments and collapsed subpaths dropped.
/// (cu2qu is not ported yet, so curves stay cubic; only quantization is modeled.)
func quantized(_ path: CGPath) -> CGPath {
    func r(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x.rounded(), y: p.y.rounded()) }
    let out = CGMutablePath()
    var sub: [(CGPathElementType, [CGPoint])] = []
    var cur = CGPoint.zero
    func flush() {
        let distinct = Set(sub.flatMap { $0.1 }.map { Int64($0.x) << 32 | (Int64($0.y) & 0xFFFF_FFFF) })
        if distinct.count >= 3 {
            for (t, pts) in sub {
                switch t {
                case .moveToPoint: out.move(to: pts[0])
                case .addLineToPoint: out.addLine(to: pts[0])
                case .addCurveToPoint: out.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
                case .addQuadCurveToPoint: out.addQuadCurve(to: pts[1], control: pts[0])
                default: break
                }
            }
            out.closeSubpath()
        }
        sub.removeAll()
    }
    path.applyWithBlock { el in
        let e = el.pointee
        switch e.type {
        case .moveToPoint:
            flush()
            cur = r(e.points[0])
            sub.append((.moveToPoint, [cur]))
        case .addLineToPoint:
            let p = r(e.points[0])
            if p != cur { sub.append((.addLineToPoint, [p])); cur = p }
        case .addQuadCurveToPoint:
            let pts = [r(e.points[0]), r(e.points[1])]
            if pts.contains(where: { $0 != cur }) { sub.append((.addQuadCurveToPoint, pts)); cur = pts[1] }
        case .addCurveToPoint:
            let pts = [r(e.points[0]), r(e.points[1]), r(e.points[2])]
            if pts.contains(where: { $0 != cur }) { sub.append((.addCurveToPoint, pts)); cur = pts[2] }
        case .closeSubpath:
            flush()
        @unknown default: break
        }
    }
    flush()
    return out
}

func pointInPolygon(_ poly: [CGPoint], _ p: CGPoint) -> Bool {
    var inside = false
    var j = poly.count - 1
    for i in 0..<poly.count {
        let a = poly[i], b = poly[j]
        if (a.y > p.y) != (b.y > p.y) {
            let x = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
            if p.x < x { inside.toggle() }
        }
        j = i
    }
    return inside
}

struct HoleMatch {
    var vanished = 0  // source counters with no surviving counter inside them
    var new = 0  // counters that did not exist before (strokes merged around a gap)
    var split = 0  // source counters pinched into more than one
    var minRatio = Double.nan  // worst per-counter area ratio (0 when one vanished)
    var matchedArea = 0.0  // area of surviving counters, excluding new ones
    var newMinArea = Double.nan  // smallest new counter: a tiny one reads as a pinhole speck
    var slivers = 0  // source "counters" below the counter floor (hairline gaps between abutting strokes)
}

/// Source holes smaller than this are hairline gaps where two stroke contours
/// almost abut (e.g. 鈗, ♴), not designed counters; closing them is harmless,
/// so they must not drive "counter vanished" or the worst per-counter ratio.
let counterFloorArea = 400.0  // ≈ 20×20 units

/// Bold counters are the source counters inset by ~weight/2, so any vertex of
/// a surviving counter lies strictly inside the source counter it came from.
func matchHoles(before: [Contour], after: [Contour]) -> HoleMatch {
    var m = HoleMatch()
    var areaIn = [Double](repeating: 0, count: before.count)
    var countIn = [Int](repeating: 0, count: before.count)
    for h in after {
        let probe = h.pts[0]
        // Counters nest (口 inside 囗 in 國), so attribute to the innermost one.
        var best: Int?
        for (i, b) in before.enumerated() where b.bbox.contains(probe) && pointInPolygon(b.pts, probe) {
            if best == nil || abs(b.area) < abs(before[best!].area) { best = i }
        }
        if let i = best {
            areaIn[i] += abs(h.area)
            countIn[i] += 1
            m.matchedArea += abs(h.area)
        } else {
            m.new += 1
            m.newMinArea = m.newMinArea.isNaN ? abs(h.area) : min(m.newMinArea, abs(h.area))
        }
    }
    for (i, b) in before.enumerated() {
        if abs(b.area) < counterFloorArea {
            m.slivers += 1
            continue
        }
        if countIn[i] == 0 { m.vanished += 1 }
        if countIn[i] > 1 { m.split += 1 }
        let r = areaIn[i] / abs(b.area)
        m.minRatio = m.minRatio.isNaN ? r : min(m.minRatio, r)
    }
    return m
}

/// Counts pairs of polyline edges that cross transversally. Union output should
/// be a planar arrangement, so any crossing is a self-intersection or overlap.
/// Touching at a vertex (weakly simple) is deliberately not counted.
struct Crossing {
    var at: CGPoint
    var c1: Int
    var c2: Int
}

func properCrossings(_ cs: [Contour]) -> [Crossing] {
    struct Edge { var a: CGPoint; var b: CGPoint; var minX, maxX, minY, maxY: CGFloat; var c: Int; var i: Int; var n: Int }
    var edges: [Edge] = []
    for (ci, c) in cs.enumerated() {
        let n = c.pts.count
        for i in 0..<n {
            let a = c.pts[i], b = c.pts[(i + 1) % n]
            if a == b { continue }
            edges.append(Edge(a: a, b: b, minX: min(a.x, b.x), maxX: max(a.x, b.x),
                              minY: min(a.y, b.y), maxY: max(a.y, b.y), c: ci, i: i, n: n))
        }
    }
    edges.sort { $0.minX < $1.minX }
    func orient(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> Double {
        Double((q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x))
    }
    let eps = 1e-6
    var found: [Crossing] = []
    for i in 0..<edges.count {
        let e = edges[i]
        var j = i + 1
        while j < edges.count, edges[j].minX <= e.maxX {
            let f = edges[j]
            j += 1
            if f.maxY < e.minY || f.minY > e.maxY { continue }
            if e.c == f.c {
                let d = abs(e.i - f.i)
                if d == 1 || d == e.n - 1 { continue }
            }
            let o1 = orient(e.a, e.b, f.a), o2 = orient(e.a, e.b, f.b)
            let o3 = orient(f.a, f.b, e.a), o4 = orient(f.a, f.b, e.b)
            if abs(o1) < eps || abs(o2) < eps || abs(o3) < eps || abs(o4) < eps { continue }
            if (o1 > 0) != (o2 > 0) && (o3 > 0) != (o4 > 0) {
                let t = o3 / (o3 - o4)
                let at = CGPoint(x: e.a.x + CGFloat(t) * (e.b.x - e.a.x), y: e.a.y + CGFloat(t) * (e.b.y - e.a.y))
                found.append(Crossing(at: at, c1: e.c, c2: f.c))
            }
        }
    }
    return found
}
