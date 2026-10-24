import CoreGraphics
import Foundation

/// A node in floating point, while an outline is converted or simplified;
/// rounded to `OutlineNode` only at the end, so the error does not compound.
struct CubicNode: Equatable {
    var point: Vec2
    var handleIn: Vec2?
    var handleOut: Vec2?
    var smooth = false
}

/// Cubic contours for the glyph editor (technical design §5.8): TrueType
/// quadratics elevated exactly, simplified to the few nodes a person edits.
enum CubicOutline {
    /// Nodes whose two tangents differ by less than this are smooth. Not 0:
    /// a TrueType outline stores its off-curve points rounded to integers, so
    /// a designer's smooth node can be off by a degree or two.
    static let smoothAngle = 3.0 * Double.pi / 180
    /// Points sampled along each original segment, to measure a fit against.
    static let samplesPerSegment = 24

    // MARK: Segments

    /// The segment from node `index` to the next one.
    static func segment(_ nodes: [CubicNode], _ index: Int) -> BezierSegment {
        let a = nodes[index]
        let b = nodes[(index + 1) % nodes.count]
        if a.handleOut == nil && b.handleIn == nil { return .line(b.point) }
        return .cubic(a.handleOut ?? a.point, b.handleIn ?? b.point, b.point)
    }

    static func isLine(_ nodes: [CubicNode], _ index: Int) -> Bool {
        if case .line = segment(nodes, index) { return true }
        return false
    }

    static func point(on segment: BezierSegment, from start: Vec2, at t: Double) -> Vec2 {
        let u = 1 - t
        switch segment {
        case .line(let end): return u * start + t * end
        case .quad(let c, let end): return u * u * start + 2 * u * t * c + t * t * end
        case .cubic(let c1, let c2, let end):
            return u * u * u * start + 3 * u * u * t * c1 + 3 * u * t * t * c2 + t * t * t * end
        }
    }

    /// `count + 1` points from the start of the segment to its end.
    static func samples(of segment: BezierSegment, from start: Vec2, count: Int = samplesPerSegment) -> [Vec2] {
        (0...count).map { point(on: segment, from: start, at: Double($0) / Double(count)) }
    }

    // MARK: TrueType → cubic

    /// One TrueType contour as cubic nodes, exactly: every on-curve point,
    /// implied ones included, becomes a node, and each quadratic P0 C P1
    /// becomes the cubic with handles P0 + ⅔(C − P0) and P1 + ⅔(C − P1),
    /// which is the same curve.
    static func elevated(_ contour: ArraySlice<GlyphPoint>) -> [CubicNode] {
        let points = contour.map { (Vec2(x: Double($0.x), y: Double($0.y)), $0.onCurve) }
        guard !points.isEmpty else { return [] }
        var expanded: [(Vec2, Bool)] = []
        for index in points.indices {
            let point = points[index]
            let next = points[(index + 1) % points.count]
            expanded.append(point)
            if !point.1 && !next.1 { expanded.append(((point.0 + next.0) * 0.5, true)) }
        }
        guard let firstOn = expanded.firstIndex(where: { $0.1 }) else { return [] }
        expanded = Array(expanded[firstOn...] + expanded[..<firstOn])

        let count = expanded.count
        var nodes = [CubicNode(point: expanded[0].0)]
        var index = 0
        while index < count {
            let next = expanded[(index + 1) % count]
            if next.1 {
                if index + 1 < count { nodes.append(CubicNode(point: next.0)) }
                index += 1
            } else {
                let control = next.0
                let end = expanded[(index + 2) % count].0
                let start = nodes[nodes.count - 1].point
                nodes[nodes.count - 1].handleOut = start + (control - start) * (2.0 / 3)
                let handleIn = end + (control - end) * (2.0 / 3)
                if index + 2 < count {
                    nodes.append(CubicNode(point: end, handleIn: handleIn))
                } else {
                    nodes[0].handleIn = handleIn
                }
                index += 2
            }
        }
        return classified(cleaned(nodes))
    }

    /// Handles on their node are no handles; a straight segment of length 0
    /// is no segment (its two nodes become one).
    static func cleaned(_ input: [CubicNode]) -> [CubicNode] {
        var nodes = input.map { node in
            var node = node
            if node.handleIn == node.point { node.handleIn = nil }
            if node.handleOut == node.point { node.handleOut = nil }
            return node
        }
        var index = 0
        while nodes.count > 1 && index < nodes.count {
            let next = (index + 1) % nodes.count
            if nodes[index].point == nodes[next].point && nodes[index].handleOut == nil && nodes[next].handleIn == nil {
                nodes[index].handleOut = nodes[next].handleOut
                nodes.remove(at: next)
                if next < index { index -= 1 }
            } else {
                index += 1
            }
        }
        return nodes.count >= 2 ? nodes : []
    }

    /// Unit tangents (arriving, leaving) at node `index`; nil where a side has no direction.
    static func tangents(_ nodes: [CubicNode], _ index: Int) -> (incoming: Vec2?, outgoing: Vec2?) {
        let count = nodes.count
        let previous = (index + count - 1) % count
        let incoming = segment(nodes, previous).endTangent(from: nodes[previous].point)
        let outgoing = segment(nodes, index).startTangent(from: nodes[index].point)
        return (unit(incoming), unit(outgoing))
    }

    static func unit(_ v: Vec2) -> Vec2? {
        let length = v.length
        return length > 1e-9 ? v * (1 / length) : nil
    }

    /// Marks the nodes where the curve passes through without a kink.
    static func classified(_ input: [CubicNode]) -> [CubicNode] {
        var nodes = input
        for index in nodes.indices {
            let previous = (index + nodes.count - 1) % nodes.count
            let bothLines = isLine(nodes, previous) && isLine(nodes, index)
            let (incoming, outgoing) = tangents(nodes, index)
            if !bothLines, let incoming, let outgoing {
                nodes[index].smooth = dot(incoming, outgoing) >= cos(smoothAngle)
            } else {
                nodes[index].smooth = false
            }
        }
        return nodes
    }

    // MARK: Simplification

    /// Removes smooth nodes between two curves wherever one cubic, keeping
    /// the tangent directions at its ends, stays within `tolerance` font
    /// units of the original curve. Corners, extrema and nodes next to a
    /// straight segment stay. Every fit is measured against the original
    /// outline, never against an earlier fit, so merges do not add up.
    /// Returns the largest distance between the result and the original.
    static func simplified(_ input: [CubicNode], tolerance: Double) -> (nodes: [CubicNode], maxError: Double) {
        var nodes = input
        guard nodes.count >= 3 else { return (nodes, 0) }
        var samples = nodes.indices.map { samples(of: segment(nodes, $0), from: nodes[$0].point) }
        var errors = [Double](repeating: 0, count: nodes.count)
        var changed = true
        while changed {
            changed = false
            var index = 0
            while index < nodes.count && nodes.count >= 3 {
                let count = nodes.count
                let previous = (index + count - 1) % count
                let next = (index + 1) % count
                guard nodes[index].smooth, !isLine(nodes, previous), !isLine(nodes, index),
                    !isExtremum(nodes, index),
                    let start = segment(nodes, previous).startTangent(from: nodes[previous].point).unitOrNil,
                    let end = segment(nodes, index).endTangent(from: nodes[index].point).unitOrNil
                else {
                    index += 1
                    continue
                }
                let merged = samples[previous] + samples[index].dropFirst()
                guard let fit = fitCubic(merged, startTangent: start, endTangent: end), fit.error <= tolerance else {
                    index += 1
                    continue
                }
                nodes[previous].handleOut = fit.c1
                nodes[next].handleIn = fit.c2
                samples[previous] = merged
                errors[previous] = fit.error
                nodes.remove(at: index)
                samples.remove(at: index)
                errors.remove(at: index)
                changed = true
            }
        }
        return (nodes, errors.max() ?? 0)
    }

    /// Extrema stay: type designers put a node at each one, and that is the
    /// node one expects to drag.
    ///
    /// The curve turns back in x or y at this node: just before and just
    /// after it, it lies on the same side. A tangent that is merely close to
    /// horizontal is not enough: cu2qu leaves several nodes along a flat
    /// stretch, and keeping all of them would keep the clutter.
    static func isExtremum(_ nodes: [CubicNode], _ index: Int) -> Bool {
        let count = nodes.count
        let previous = (index + count - 1) % count
        let p = nodes[index].point
        let before = point(on: segment(nodes, previous), from: nodes[previous].point, at: 0.95) - p
        let after = point(on: segment(nodes, index), from: p, at: 0.05) - p
        func sameSide(_ a: Double, _ b: Double) -> Bool { (a > 1e-6 && b > 1e-6) || (a < -1e-6 && b < -1e-6) }
        return sameSide(before.x, after.x) || sameSide(before.y, after.y)
    }

    /// The cubic from the first sample to the last, leaving along
    /// `startTangent` and arriving along `endTangent` (unit vectors, both in
    /// the direction of travel), that best fits the samples: Schneider's
    /// least squares for the two handle lengths, with Newton steps on the
    /// sample parameters. `error` is the larger of the two one-sided
    /// distances between the samples and the fitted curve.
    static func fitCubic(
        _ samples: [Vec2], startTangent: Vec2, endTangent: Vec2
    ) -> (c1: Vec2, c2: Vec2, error: Double)? {
        guard samples.count >= 3, let p0 = samples.first, let p3 = samples.last else { return nil }
        var lengths = [0.0]
        for index in 1..<samples.count {
            lengths.append(lengths[index - 1] + (samples[index] - samples[index - 1]).length)
        }
        guard let total = lengths.last, total > 1e-9 else { return nil }
        var parameters = lengths.map { $0 / total }

        func solve() -> (Vec2, Vec2) {
            var c00 = 0.0
            var c01 = 0.0
            var c11 = 0.0
            var x0 = 0.0
            var x1 = 0.0
            for (index, u) in parameters.enumerated() {
                let v = 1 - u
                let b0 = v * v * v
                let b1 = 3 * u * v * v
                let b2 = 3 * u * u * v
                let b3 = u * u * u
                let a1 = startTangent * b1
                let a2 = endTangent * (-b2)
                c00 += dot(a1, a1)
                c01 += dot(a1, a2)
                c11 += dot(a2, a2)
                let rest = samples[index] - (p0 * (b0 + b1) + p3 * (b2 + b3))
                x0 += dot(a1, rest)
                x1 += dot(a2, rest)
            }
            let determinant = c00 * c11 - c01 * c01
            var alpha = total / 3
            var beta = total / 3
            if abs(determinant) > 1e-12 {
                let a = (x0 * c11 - x1 * c01) / determinant
                let b = (c00 * x1 - c01 * x0) / determinant
                // Backward or vanishing handles fit points but not the shape
                // (a cusp or loop); the chord-thirds heuristic is the usual fallback.
                if a > 1e-6 * total && b > 1e-6 * total {
                    alpha = a
                    beta = b
                }
            }
            return (p0 + startTangent * alpha, p3 - endTangent * beta)
        }

        var (c1, c2) = solve()
        for _ in 0..<4 {
            parameters = zip(samples, parameters).map { sample, u in
                newtonStep(u, sample: sample, p0: p0, c1: c1, c2: c2, p3: p3)
            }
            (c1, c2) = solve()
        }
        let error = hausdorff(samples, BezierSegment.cubic(c1, c2, p3), from: p0)
        return (c1, c2, error)
    }

    private static func newtonStep(_ u: Double, sample: Vec2, p0: Vec2, c1: Vec2, c2: Vec2, p3: Vec2) -> Double {
        let v = 1 - u
        let q = v * v * v * p0 + 3 * v * v * u * c1 + 3 * v * u * u * c2 + u * u * u * p3
        let d1 = 3 * v * v * (c1 - p0) + 6 * v * u * (c2 - c1) + 3 * u * u * (p3 - c2)
        let d2 = 6 * v * (c2 - 2 * c1 + p0) + 6 * u * (p3 - 2 * c2 + c1)
        let numerator = dot(q - sample, d1)
        let denominator = dot(d1, d1) + dot(q - sample, d2)
        guard abs(denominator) > 1e-12 else { return u }
        return min(1, max(0, u - numerator / denominator))
    }

    /// Larger of: the farthest sample from the curve, the farthest point of
    /// the curve from the samples' polyline. Both are measured on polylines
    /// fine enough (≥ 24 points a segment) that the gap they leave is far
    /// below a font unit for glyph-sized curves.
    static func hausdorff(_ samples: [Vec2], _ segment: BezierSegment, from start: Vec2) -> Double {
        let curve = self.samples(of: segment, from: start, count: max(64, samples.count * 2))
        return max(farthest(samples, from: curve), farthest(curve, from: samples))
    }

    static func farthest(_ points: [Vec2], from polyline: [Vec2]) -> Double {
        points.map { distance($0, polyline) }.max() ?? 0
    }

    static func distance(_ point: Vec2, _ polyline: [Vec2]) -> Double {
        guard polyline.count > 1 else { return polyline.first.map { (point - $0).length } ?? .infinity }
        var best = Double.infinity
        for index in 1..<polyline.count {
            let a = polyline[index - 1]
            let ab = polyline[index] - a
            let lengthSquared = dot(ab, ab)
            let t = lengthSquared > 0 ? min(1, max(0, dot(point - a, ab) / lengthSquared)) : 0
            best = min(best, (point - (a + ab * t)).length)
        }
        return best
    }

    // MARK: Rounding

    static func rounded(_ node: CubicNode) -> OutlineNode {
        func round(_ v: Vec2) -> OutlinePoint {
            OutlinePoint(x: Int(EmboldenGeometry.rounded(v.x)), y: Int(EmboldenGeometry.rounded(v.y)))
        }
        let point = round(node.point)
        let handleIn = node.handleIn.map(round)
        let handleOut = node.handleOut.map(round)
        return OutlineNode(
            x: point.x, y: point.y, handleIn: handleIn == point ? nil : handleIn,
            handleOut: handleOut == point ? nil : handleOut, smooth: node.smooth)
    }

    static func float(_ node: OutlineNode) -> CubicNode {
        func vec(_ p: OutlinePoint) -> Vec2 { Vec2(x: Double(p.x), y: Double(p.y)) }
        return CubicNode(
            point: vec(node.point), handleIn: node.handleIn.map(vec), handleOut: node.handleOut.map(vec),
            smooth: node.smooth)
    }
}

extension Vec2 {
    var unitOrNil: Vec2? { CubicOutline.unit(self) }
}

// MARK: - Public API for the editor

extension EditedGlyph {
    /// Default simplification tolerance: 1 unit per 1000 units of em. The
    /// build then converts each cubic back within another unit (cu2qu,
    /// design §5.1), so an untouched part of an edited glyph moves at most
    /// about 2.5 units at UPM 1000 (with rounding): 0.03 px at 12 pt on a
    /// 300 ppi screen.
    public static func defaultTolerance(unitsPerEm: Int) -> Double { Double(unitsPerEm) / 1000 }

    /// A TrueType outline as editable cubic contours: exact elevation, then
    /// simplification within `tolerance` font units (none for 0), then
    /// rounding to integers. `maxError` is the simplification's largest
    /// distance from the source curve, before rounding (which adds at most
    /// 0.71 units).
    public static func editable(
        _ outline: SimpleOutline, advance: Int, tolerance: Double
    ) -> (glyph: EditedGlyph, maxError: Double) {
        var maxError = 0.0
        var contours: [[OutlineNode]] = []
        for range in outline.contourRanges {
            var nodes = CubicOutline.elevated(outline.points[range])
            guard !nodes.isEmpty else { continue }
            if tolerance > 0 {
                let result = CubicOutline.simplified(nodes, tolerance: tolerance)
                nodes = result.nodes
                maxError = max(maxError, result.maxError)
            }
            contours.append(nodes.map(CubicOutline.rounded))
        }
        return (EditedGlyph(advance: advance, contours: contours), maxError)
    }

    /// The outline as float Bézier contours, in its own direction.
    func bezierContours() -> [BezierContour] {
        contours.compactMap { contour in
            guard contour.count >= 2 else { return nil }
            let nodes = contour.map(CubicOutline.float)
            return BezierContour(segments: nodes.indices.map { CubicOutline.segment(nodes, $0) })
        }
    }

    /// The glyph for glyf: cu2qu at the engine's tolerance, rounding, and
    /// the cleanup every outline operation gets (design §5.1).
    func trueTypeOutline(overlapping: Bool) throws -> SimpleOutline {
        var outline = try EmboldenGeometry.trueTypeOutline(bezierContours(), reversingDirection: false)
        outline.overlapping = overlapping
        return outline
    }

    /// The cubic outline for drawing, y up in font units.
    public var path: CGPath {
        let path = CGMutablePath()
        for contour in contours where contour.count >= 2 {
            path.move(to: cgPoint(contour[0].point))
            for index in contour.indices {
                let a = contour[index]
                let b = contour[(index + 1) % contour.count]
                if a.handleOut == nil && b.handleIn == nil {
                    path.addLine(to: cgPoint(b.point))
                } else {
                    path.addCurve(
                        to: cgPoint(b.point), control1: cgPoint(a.handleOut ?? a.point),
                        control2: cgPoint(b.handleIn ?? b.point))
                }
            }
            path.closeSubpath()
        }
        return path
    }

    /// Tight horizontal extent of the ink (curve extrema, not handles), as
    /// the editor shows side bearings; nil without contours.
    public var inkBounds: CGRect? {
        let box = path.boundingBoxOfPath
        return box.isNull || contours.isEmpty ? nil : box
    }

    public var nodeCount: Int { contours.reduce(0) { $0 + $1.count } }

    /// Moves every node and handle.
    public mutating func translate(dx: Int, dy: Int) {
        for c in contours.indices {
            for n in contours[c].indices {
                contours[c][n].x += dx
                contours[c][n].y += dy
                contours[c][n].handleIn?.x += dx
                contours[c][n].handleIn?.y += dy
                contours[c][n].handleOut?.x += dx
                contours[c][n].handleOut?.y += dy
            }
        }
    }

    /// The closest point on any segment: (contour, segment from node
    /// `segment` to the next, curve parameter, distance in font units).
    public func nearestSegment(toX x: Double, y: Double) -> (contour: Int, segment: Int, t: Double, distance: Double)? {
        let target = Vec2(x: x, y: y)
        var best: (Int, Int, Double, Double)?
        for (c, contour) in contours.enumerated() where contour.count >= 2 {
            let nodes = contour.map(CubicOutline.float)
            for s in nodes.indices {
                let segment = CubicOutline.segment(nodes, s)
                let steps = 48
                for step in 0...steps {
                    let t = Double(step) / Double(steps)
                    let distance = (CubicOutline.point(on: segment, from: nodes[s].point, at: t) - target).length
                    if best == nil || distance < best!.3 { best = (c, s, t, distance) }
                }
            }
        }
        return best.map { (contour: $0.0, segment: $0.1, t: $0.2, distance: $0.3) }
    }

    /// Adds a node on the segment after node `segment`, at parameter `t`,
    /// without changing the curve (de Casteljau); a straight segment gets a
    /// corner node. Returns the new node's index.
    @discardableResult
    public mutating func insertNode(contour c: Int, segment s: Int, t: Double) -> Int {
        var nodes = contours[c].map(CubicOutline.float)
        let next = (s + 1) % nodes.count
        let p0 = nodes[s].point
        switch CubicOutline.segment(nodes, s) {
        case .line(let end):
            nodes.insert(CubicNode(point: p0 + (end - p0) * t), at: s + 1)
        case .cubic(let c1, let c2, let p3):
            let a = p0 + (c1 - p0) * t
            let b = c1 + (c2 - c1) * t
            let d = c2 + (p3 - c2) * t
            let e = a + (b - a) * t
            let f = b + (d - b) * t
            let m = e + (f - e) * t
            nodes[s].handleOut = a
            nodes[next].handleIn = d
            nodes.insert(CubicNode(point: m, handleIn: e, handleOut: f, smooth: true), at: s + 1)
        case .quad:
            preconditionFailure("editor segments are lines or cubics")
        }
        contours[c] = nodes.map(CubicOutline.rounded)
        return s + 1
    }

    /// Removes a node, refitting one cubic over the two segments it joined
    /// so the shape changes as little as it can (a contour keeps at least 2
    /// nodes; with fewer left, the whole contour goes).
    public mutating func removeNode(contour c: Int, index: Int) {
        let nodes = contours[c].map(CubicOutline.float)
        guard nodes.count > 2 else {
            contours.remove(at: c)
            return
        }
        let count = nodes.count
        let previous = (index + count - 1) % count
        let next = (index + 1) % count
        var result = nodes
        if !(CubicOutline.isLine(nodes, previous) && CubicOutline.isLine(nodes, index)),
            let start = CubicOutline.segment(nodes, previous).startTangent(from: nodes[previous].point).unitOrNil,
            let end = CubicOutline.segment(nodes, index).endTangent(from: nodes[index].point).unitOrNil,
            let fit = CubicOutline.fitCubic(
                CubicOutline.samples(of: CubicOutline.segment(nodes, previous), from: nodes[previous].point)
                    + CubicOutline.samples(of: CubicOutline.segment(nodes, index), from: nodes[index].point)
                    .dropFirst(),
                startTangent: start, endTangent: end)
        {
            result[previous].handleOut = fit.c1
            result[next].handleIn = fit.c2
        }
        result.remove(at: index)
        contours[c] = result.map(CubicOutline.rounded)
    }

    /// Smooth: the handles are lined up (a node without handles gets a pair
    /// along the line through its neighbours, a third of the way to each, as
    /// Illustrator's convert-anchor tool does). Corner: the handles are
    /// retracted, so both segments meet at a point, as in Illustrator and Figma.
    public mutating func setSmooth(_ smooth: Bool, contour c: Int, index: Int) {
        var nodes = contours[c].map(CubicOutline.float)
        let count = nodes.count
        let p = nodes[index].point
        let previous = nodes[(index + count - 1) % count].point
        let next = nodes[(index + 1) % count].point
        if smooth {
            let inArm = nodes[index].handleIn.map { $0 - p }
            let outArm = nodes[index].handleOut.map { $0 - p }
            let direction: Vec2? =
                switch (inArm, outArm) {
                case (let i?, let o?): (o.unitOrNil ?? .zero) - (i.unitOrNil ?? .zero)
                case (nil, let o?): o
                case (let i?, nil): Vec2.zero - i
                case (nil, nil): next - previous
                }
            guard let unit = direction?.unitOrNil else { return }
            let inLength = inArm?.length ?? (p - previous).length / 3
            let outLength = outArm?.length ?? (next - p).length / 3
            nodes[index].handleIn = p - unit * inLength
            nodes[index].handleOut = p + unit * outLength
            nodes[index].smooth = true
        } else {
            nodes[index].handleIn = nil
            nodes[index].handleOut = nil
            nodes[index].smooth = false
        }
        contours[c] = nodes.map(CubicOutline.rounded)
    }

    /// Turns contour `c` to run the way nonzero filling needs for where it
    /// sits: clockwise (y up) when it is inside an even number of the other
    /// contours, as an outer contour; counter-clockwise inside an odd
    /// number, to cut a hole. For a contour just drawn with the pen.
    public mutating func orientForFill(contour c: Int) {
        let polygon = polyline(contours[c])
        guard let probe = polygon.first else { return }
        let depth = contours.indices.filter { $0 != c && contains(polyline(contours[$0]), probe) }.count
        let clockwise = signedArea(polygon) < 0
        if clockwise != depth.isMultiple(of: 2) { reverseContour(c) }
    }

    public mutating func reverseContour(_ c: Int) {
        contours[c] = contours[c].reversed().map { node in
            var node = node
            swap(&node.handleIn, &node.handleOut)
            return node
        }
    }

    private func polyline(_ contour: [OutlineNode]) -> [Vec2] {
        let nodes = contour.map(CubicOutline.float)
        return nodes.indices.flatMap { index in
            CubicOutline.samples(of: CubicOutline.segment(nodes, index), from: nodes[index].point, count: 8).dropLast()
        }
    }

    private func signedArea(_ polygon: [Vec2]) -> Double {
        polygon.indices.reduce(0.0) { $0 + cross(polygon[$1], polygon[($1 + 1) % polygon.count]) } / 2
    }

    private func contains(_ polygon: [Vec2], _ point: Vec2) -> Bool {
        var inside = false
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            if (a.y > point.y) != (b.y > point.y), point.x < a.x + (point.y - a.y) / (b.y - a.y) * (b.x - a.x) {
                inside.toggle()
            }
        }
        return inside
    }
}

private func cgPoint(_ p: OutlinePoint) -> CGPoint { CGPoint(x: Double(p.x), y: Double(p.y)) }

extension SimpleOutline {
    /// Symmetric distance between two outlines in font units: the farthest
    /// any point of either is from the other, measured on polylines of 24
    /// points per curve. For checking that a conversion kept the shape.
    public func maxDistance(to other: SimpleOutline) -> Double {
        func polylines(_ outline: SimpleOutline) -> [[Vec2]] {
            BezierContour.contours(of: outline.cgPath).map { contour in
                contour.segments.indices.flatMap { index in
                    CubicOutline.samples(of: contour.segments[index], from: contour.start(of: index))
                }
            }
        }
        let mine = polylines(self)
        let theirs = polylines(other)
        func farthest(_ from: [[Vec2]], _ to: [[Vec2]]) -> Double {
            from.flatMap { $0 }.map { point in to.map { CubicOutline.distance(point, $0) }.min() ?? .infinity }.max()
                ?? 0
        }
        return max(farthest(mine, theirs), farthest(theirs, mine))
    }
}
