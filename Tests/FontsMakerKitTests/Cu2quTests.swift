import Testing

@testable import FontsMakerKit

/// The cu2qu port against fontTools 4.63. Expected values come from
/// scripts/cu2qu_vectors.py; if fontTools and the port disagree, curves
/// converted by our engine would differ from what fontTools tooling (and the
/// tolerance reasoning in technical design §5.1) assumes.
struct Cu2quTests {
    typealias Point = (Double, Double)

    static let fixed: [(String, [Point], Double, [Point])] = [
        ("exact quadratic", [(0, 0), (2, 2), (4, 2), (6, 0)], 0.1, [(0.0, 0.0), (3.0, 3.0), (6.0, 0.0)]),
        (
            "fontTools AllQuadraticFalse cubic", [(0, 0), (0, 1), (2, 1), (2, 0)], 0.1,
            [(0.0, 0.0), (0.0, 0.75), (2.0, 0.75), (2.0, 0.0)]
        ),
        (
            "fontTools docstring curve", [(50, 50), (100, 100), (150, 100), (200, 50)], 1.0,
            [(50.0, 50.0), (125.0, 125.0), (200.0, 50.0)]
        ),
        (
            "collinear handles", [(0, 0), (1, 0), (2, 0), (3, 0)], 1.0,
            [(0.0, 0.0), (0.75, 0.0), (2.25, 0.0), (3.0, 0.0)]
        ),
        ("all points equal", [(5, 5), (5, 5), (5, 5), (5, 5)], 1.0, [(5.0, 5.0), (5.0, 5.0), (5.0, 5.0)]),
        (
            "s-curve", [(0, 0), (400, 0), (-200, 600), (300, 700)], 1.0,
            [
                (0.0, 0.0), (66.66666666666666, 0.0), (132.9475308641975, 40.76646090534978),
                (151.0802469135802, 112.39711934156378), (138.3487654320988, 205.83847736625518),
                (112.03703703703692, 312.037037037037), (89.42901234567908, 421.9393004115227),
                (87.80864197530866, 526.4917695473251), (124.45987654320977, 616.6409465020574),
                (216.66666666666634, 683.3333333333335), (300.0, 700.0),
            ]
        ),
        (
            "tight loop", [(0, 0), (1000, 1000), (0, 1000), (1000, 0)], 1.0,
            [
                (0.0, 0.0), (136.36363636363637, 136.36363636363637), (317.28024042073633, 359.504132231405),
                (426.07062359128474, 533.0578512396694), (480.76634109691963, 657.0247933884298),
                (499.39894815927875, 731.404958677686), (499.9999999999999, 756.198347107438),
                (500.6010518407213, 731.404958677686), (519.2336589030805, 657.0247933884298),
                (573.9293764087154, 533.0578512396695), (682.7197595792638, 359.50413223140464),
                (863.6363636363633, 136.36363636363598), (1000.0, 0.0),
            ]
        ),
        (
            "font-like stroke edge",
            [(166.683, -13.867), (167.054, -13.681), (167.414, -13.487), (167.759, -13.281)], 1.0,
            [(166.683, -13.867), (167.27285851827668, -13.571275783289868), (167.759, -13.281)]
        ),
        (
            "font-like bowl", [(452.0, 386.5), (452.0, 512.75), (371.25, 600.0), (250.0, 600.0)], 1.0,
            [
                (452.0, 386.5), (452.0, 449.625), (401.52083333333337, 545.8541666666666), (310.625, 600.0),
                (250.0, 600.0),
            ]
        ),
    ]

    /// fontTools' segment count for each of 1000 SplitMix64 curves at
    /// tolerance 1, one base-36 digit per curve (0 would mean no fit).
    static let randomSegmentCounts =
        "9987aa799889888979887a769787787a9589989589a699767855796679796a979877987897a88678989aaa87897964a95888899a6773699a598849a989989a6887998565687899a98798a58866674897979788597888779a9a99867969798879868669998779a8596568788779a999788a786879957577976856a969a7a99a8987898a7a967a978a959965559889978a9898688a97798699689589a97978898868787687a87759749a89896979a797788879995a78a5298859a87a9988a8998a89979a8789987857676b797877799889899799a978757a7689896679687798a5688a89a8987868a9757687678588877867979a6898787aa9999787775a879789787889a99a9778a8868748699978698a88a876897b57a89a9594758896a8a56599879a8397869987968a889aa8698a9898a97974888a79998a7755677a6b8868687975a988987aa6865675a8a7999a8987766a798a79a899678989a68879896898889689798789779887969858a9849797886899a9888798a875978968989848677788a79867889789787889756a9a778966788776987789a49996777a8878688aaa877769689aa9a8989784988767866997a897a8877689a695a788766687a6899a868579a5a887a6589a9a7888a979a767675988685766969989899857a6877a8977586787978aa6b8867867a8788659a9a977"

    /// Same generator as scripts/cu2qu_vectors.py.
    struct SplitMix64 {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func randomCurves() -> [[Vec2]] {
        var rng = SplitMix64(state: 0x2E2E_C0DE)
        return (0..<1000).map { _ in
            (0..<4).map { _ in
                let x = Double(rng.next() % 1001)
                let y = Double(rng.next() % 1001)
                return Vec2(x: x, y: y)
            }
        }
    }

    private func convert(_ c: [Vec2], tolerance: Double) -> [Vec2]? {
        Cu2qu.quadraticSpline(c[0], c[1], c[2], c[3], tolerance: tolerance)
    }

    @Test(arguments: Cu2quTests.fixed.indices)
    func matchesFontToolsOnFixedCurves(index: Int) throws {
        let (name, input, tolerance, expected) = Cu2quTests.fixed[index]
        let spline = try #require(convert(input.map { Vec2(x: $0.0, y: $0.1) }, tolerance: tolerance), "\(name)")
        #expect(spline.count == expected.count, "\(name): segment count")
        for (actual, wanted) in zip(spline, expected) {
            // Compiled fontTools may fuse multiply-adds, so allow last-bit noise.
            #expect(
                abs(actual.x - wanted.0) < 1e-9 && abs(actual.y - wanted.1) < 1e-9, "\(name): \(actual) vs \(wanted)")
        }
    }

    /// The analogue of fontTools' test_results_unchanged: the same segment
    /// count as fontTools for every one of 1000 random curves.
    @Test func picksTheSameSegmentCountsAsFontTools() {
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let actual = String(
            Cu2quTests.randomCurves().map { curve in digits[(convert(curve, tolerance: 1)?.count ?? 2) - 2] })
        #expect(actual.count == 1000)
        let firstDifference = zip(actual, Cu2quTests.randomSegmentCounts).enumerated().first {
            $0.element.0 != $0.element.1
        }
        #expect(firstDifference == nil, "first differing curve: \(String(describing: firstDifference))")
    }

    /// The point of cu2qu: the quadratic spline never strays more than the
    /// tolerance from the cubic (design §5.1: 1 font unit). Spline piece k
    /// covers cubic time [(k-1)/n, k/n], so the distance is checked pointwise.
    @Test(arguments: [1.0, 0.25, 5.0])
    func staysWithinTolerance(tolerance: Double) throws {
        var worst = 0.0
        for curve in Cu2quTests.randomCurves() {
            let spline = try #require(convert(curve, tolerance: tolerance))
            worst = max(worst, maximumDistance(curve, spline))
        }
        #expect(worst <= tolerance + 1e-9, "max error \(worst) exceeds tolerance \(tolerance)")
        #expect(worst > tolerance / 4, "the check samples finely enough to see the error")
    }

    private func maximumDistance(_ cubic: [Vec2], _ spline: [Vec2]) -> Double {
        let n = spline.count - 2
        let controls = Array(spline[1...n])
        var onCurve = [spline[0]]
        for k in 1..<n { onCurve.append((controls[k - 1] + controls[k]) * 0.5) }
        onCurve.append(spline[n + 1])
        var worst = 0.0
        for k in 0..<n {
            for step in 0...50 {
                let s = Double(step) / 50
                let t = (Double(k) + s) / Double(n)
                let u = 1 - t
                let onCubic =
                    u * u * u * cubic[0] + 3 * u * u * t * cubic[1] + 3 * u * t * t * cubic[2] + t * t * t * cubic[3]
                let v = 1 - s
                let onSpline = v * v * onCurve[k] + 2 * v * s * controls[k] + s * s * onCurve[k + 1]
                worst = max(worst, (onCubic - onSpline).length)
            }
        }
        return worst
    }
}
