import Foundation

/// A point or vector in font units. Plain Doubles rather than CGPoint so the
/// cu2qu port can mirror fontTools' complex arithmetic operation by operation.
struct Vec2: Equatable, Sendable {
    var x: Double
    var y: Double

    static let zero = Vec2(x: 0, y: 0)

    /// Python's `abs(complex)`, which is hypot.
    var length: Double { hypot(x, y) }

    static func + (lhs: Vec2, rhs: Vec2) -> Vec2 { Vec2(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
    static func - (lhs: Vec2, rhs: Vec2) -> Vec2 { Vec2(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
    static func * (lhs: Vec2, rhs: Double) -> Vec2 { Vec2(x: lhs.x * rhs, y: lhs.y * rhs) }
    static func * (lhs: Double, rhs: Vec2) -> Vec2 { Vec2(x: lhs * rhs.x, y: lhs * rhs.y) }
}

/// z-component of the 2D cross product; positive when `b` is counter-clockwise from `a`.
func cross(_ a: Vec2, _ b: Vec2) -> Double { a.x * b.y - a.y * b.x }

func dot(_ a: Vec2, _ b: Vec2) -> Double { a.x * b.x + a.y * b.y }
