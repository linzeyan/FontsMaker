// Cubic-to-quadratic Bézier conversion, ported from fontTools.cu2qu
// (fontTools/cu2qu/cu2qu.py as shipped in fontTools 4.63).
//
// Original work: Copyright 2015 Google Inc. The cu2qu.py source carries the
// Apache License 2.0 header; fontTools as a whole is distributed under the MIT
// license. https://github.com/fonttools/fonttools
//
// The port keeps the original's operation order (complex numbers become Vec2),
// so it picks the same number of quadratic segments as fontTools for the same
// curve and tolerance. Only `curve_to_quadratic` with all_quadratic=True is
// ported; the multi-curve (interpolation-compatible) variant is not needed.

enum Cu2qu {
    /// fontTools' MAX_N: the most quadratic segments tried for one cubic.
    static let maxSegments = 100

    /// Approximates the cubic p0…p3 by a quadratic spline whose distance from
    /// the cubic never exceeds `tolerance`.
    ///
    /// Returns `[p0, q1, …, qn, p3]`: the n off-curve points sit between the end
    /// points, with an implied on-curve point midway between consecutive ones
    /// (TrueType convention). nil when no spline of up to `maxSegments` pieces
    /// fits, which fontTools reports as ApproxNotFoundError.
    static func quadraticSpline(_ p0: Vec2, _ p1: Vec2, _ p2: Vec2, _ p3: Vec2, tolerance: Double) -> [Vec2]? {
        let cubic = (p0, p1, p2, p3)
        for segments in 1...maxSegments {
            if let spline = approximateSpline(cubic, segments: segments, tolerance: tolerance) {
                return spline
            }
        }
        return nil
    }

    typealias Cubic = (Vec2, Vec2, Vec2, Vec2)

    /// `dot` in cu2qu.py: tiny results are flushed to zero because they feed a
    /// denominator, and pure-Python and compiled fontTools disagree in the last bits there.
    private static func flushedDot(_ a: Vec2, _ b: Vec2) -> Double {
        let result = a.x * b.x + a.y * b.y
        return abs(result) < 1e-15 ? 0 : result
    }

    /// `_complex_div_by_real`: two divisions, never a multiply by the reciprocal.
    private static func divided(_ z: Vec2, by den: Double) -> Vec2 { Vec2(x: z.x / den, y: z.y / den) }

    private static func cubicPoints(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2) -> Cubic {
        let p1 = divided(c, by: 3.0) + d
        let p2 = divided(b + c, by: 3.0) + p1
        let p3 = a + d + c + b
        return (d, p1, p2, p3)
    }

    private static func cubicParameters(_ p0: Vec2, _ p1: Vec2, _ p2: Vec2, _ p3: Vec2) -> (Vec2, Vec2, Vec2, Vec2) {
        let c = (p1 - p0) * 3.0
        let b = (p2 - p1) * 3.0 - c
        let d = p0
        let a = p3 - d - c - b
        return (a, b, c, d)
    }

    private static func split(_ cubic: Cubic, into n: Int) -> [Cubic] {
        let (p0, p1, p2, p3) = cubic
        switch n {
        case 2:
            return splitIntoTwo(p0, p1, p2, p3)
        case 3:
            return splitIntoThree(p0, p1, p2, p3)
        case 4:
            let halves = splitIntoTwo(p0, p1, p2, p3)
            return halves.flatMap { splitIntoTwo($0.0, $0.1, $0.2, $0.3) }
        case 6:
            let halves = splitIntoTwo(p0, p1, p2, p3)
            return halves.flatMap { splitIntoThree($0.0, $0.1, $0.2, $0.3) }
        default:
            let (a, b, c, d) = cubicParameters(p0, p1, p2, p3)
            let dt = 1 / Double(n)
            let delta2 = dt * dt
            let delta3 = dt * delta2
            return (0..<n).map { i in
                let t1 = Double(i) * dt
                let t1Squared = t1 * t1
                let a1 = a * delta3
                let b1 = (3 * a * t1 + b) * delta2
                let c1 = (2 * b * t1 + c + 3 * a * t1Squared) * dt
                let d1 = a * t1 * t1Squared + b * t1Squared + c * t1 + d
                return cubicPoints(a1, b1, c1, d1)
            }
        }
    }

    private static func splitIntoTwo(_ p0: Vec2, _ p1: Vec2, _ p2: Vec2, _ p3: Vec2) -> [Cubic] {
        let mid = (p0 + 3 * (p1 + p2) + p3) * 0.125
        let deriv3 = (p3 + p2 - p1 - p0) * 0.125
        return [
            (p0, (p0 + p1) * 0.5, mid - deriv3, mid),
            (mid, mid + deriv3, (p2 + p3) * 0.5, p3),
        ]
    }

    private static func splitIntoThree(_ p0: Vec2, _ p1: Vec2, _ p2: Vec2, _ p3: Vec2) -> [Cubic] {
        let mid1 = (8 * p0 + 12 * p1 + 6 * p2 + p3) * (1.0 / 27)
        let deriv1 = (p3 + 3 * p2 - 4 * p0) * (1.0 / 27)
        let mid2 = (p0 + 6 * p1 + 12 * p2 + 8 * p3) * (1.0 / 27)
        let deriv2 = (4 * p3 - 3 * p1 - p0) * (1.0 / 27)
        return [
            (p0, divided(2 * p0 + p1, by: 3.0), mid1 - deriv1, mid1),
            (mid1, mid1 + deriv1, mid2 - deriv2, mid2),
            (mid2, mid2 + deriv2, divided(p2 + 2 * p3, by: 3.0), p3),
        ]
    }

    /// Control point of the quadratic that approximates the cubic, sliding
    /// between the two tangent-line candidates as t goes 0 → 1.
    private static func approximateControl(_ t: Double, _ cubic: Cubic) -> Vec2 {
        let (p0, p1, p2, p3) = cubic
        let q1 = p0 + (p1 - p0) * 1.5
        let q2 = p3 + (p2 - p3) * 1.5
        return q1 + (q2 - q1) * t
    }

    /// Intersection of line ab with line cd; nil (fontTools: NaN) when parallel.
    private static func intersection(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2) -> Vec2? {
        let ab = b - a
        let cd = d - c
        let p = Vec2(x: -ab.y, y: ab.x)  // ab * 1j
        let denominator = flushedDot(p, cd)
        guard denominator != 0 else {
            // Three or four coincident points still intersect: return an
            // off-curve so a one-quadratic fit can be attempted (kurbo#484).
            if b == c && (a == b || c == d) { return b }
            return nil
        }
        let h = flushedDot(p, a - c) / denominator
        return c + cd * h
    }

    /// Whether the cubic p0…p3 lies entirely within `tolerance` of the origin.
    /// End points are not checked; callers check them separately.
    private static func farthestFitInside(_ p0: Vec2, _ p1: Vec2, _ p2: Vec2, _ p3: Vec2, _ tolerance: Double) -> Bool {
        // p2 first: it carries the larger error early on.
        if p2.length <= tolerance && p1.length <= tolerance { return true }
        let mid = (p0 + 3 * (p1 + p2) + p3) * 0.125
        if mid.length > tolerance { return false }
        let deriv3 = (p3 + p2 - p1 - p0) * 0.125
        return farthestFitInside(p0, (p0 + p1) * 0.5, mid - deriv3, mid, tolerance)
            && farthestFitInside(mid, mid + deriv3, (p2 + p3) * 0.5, p3, tolerance)
    }

    private static func approximateQuadratic(_ cubic: Cubic, tolerance: Double) -> [Vec2]? {
        let (c0, cubic1, cubic2, c3) = cubic
        guard let q1 = intersection(c0, cubic1, cubic2, c3) else { return nil }
        let c1 = c0 + (q1 - c0) * (2.0 / 3)
        let c2 = c3 + (q1 - c3) * (2.0 / 3)
        guard farthestFitInside(.zero, c1 - cubic1, c2 - cubic2, .zero, tolerance) else { return nil }
        return [c0, q1, c3]
    }

    private static func approximateSpline(_ cubic: Cubic, segments n: Int, tolerance: Double) -> [Vec2]? {
        if n == 1 { return approximateQuadratic(cubic, tolerance: tolerance) }
        let pieces = split(cubic, into: n)

        // Build the spline and check its error at the same time.
        var nextCubic = pieces[0]
        var nextQ1 = approximateControl(0, nextCubic)
        var q2 = cubic.0
        var d1 = Vec2.zero
        var spline = [cubic.0, nextQ1]
        for i in 1...n {
            let (_, c1, c2, c3) = nextCubic
            let q0 = q2
            let q1 = nextQ1
            if i < n {
                nextCubic = pieces[i]
                nextQ1 = approximateControl(Double(i) / Double(n - 1), nextCubic)
                spline.append(nextQ1)
                q2 = (q1 + nextQ1) * 0.5
            } else {
                q2 = c3
            }
            let d0 = d1
            d1 = q2 - c3
            if d1.length > tolerance
                || !farthestFitInside(
                    d0, q0 + (q1 - q0) * (2.0 / 3) - c1, q2 + (q1 - q2) * (2.0 / 3) - c2, d1, tolerance)
            {
                return nil
            }
        }
        spline.append(cubic.3)
        return spline
    }
}
