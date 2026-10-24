/// A glyph's points with every component resolved, still in floating point:
/// nested transforms must compose before rounding, or the error compounds
/// (same order of operations as fontTools `Glyph.getCoordinates`).
struct FlatOutline {
    var endPoints: [Int] = []
    var xs: [Double] = []
    var ys: [Double] = []
    var onCurve: [Bool] = []
    var overlapping = false

    mutating func append(_ other: FlatOutline) {
        let base = xs.count
        endPoints.append(contentsOf: other.endPoints.map { $0 + base })
        xs.append(contentsOf: other.xs)
        ys.append(contentsOf: other.ys)
        onCurve.append(contentsOf: other.onCurve)
        overlapping = overlapping || other.overlapping
    }

    mutating func translate(_ dx: Double, _ dy: Double) {
        for index in xs.indices {
            xs[index] += dx
            ys[index] += dy
        }
    }

    mutating func apply(_ transform: GlyphComponent.Transform) {
        if transform == .identity { return }
        let (xx, xy, yx, yy) = transform.coefficients
        for index in xs.indices {
            let x = xs[index]
            let y = ys[index]
            xs[index] = xx * x + yx * y
            ys[index] = xy * x + yy * y
        }
    }

    /// Rounds half up, like fontTools `otRound`, so decomposed coordinates
    /// match what fontTools produces for the same composite.
    func rounded() -> SimpleOutline {
        var points: [GlyphPoint] = []
        points.reserveCapacity(xs.count)
        for index in xs.indices {
            points.append(
                GlyphPoint(
                    x: Int32((xs[index] + 0.5).rounded(.down)),
                    y: Int32((ys[index] + 0.5).rounded(.down)),
                    onCurve: onCurve[index]))
        }
        return SimpleOutline(endPoints: endPoints, points: points, overlapping: overlapping)
    }
}

extension Font {
    /// Deeper nesting than this can only come from a reference cycle.
    private static let maxComponentNesting = 64

    func flattenedOutline(of glyphID: Int) throws -> FlatOutline {
        try flattenedOutline(of: glyphID, depth: 0)
    }

    private func flattenedOutline(of glyphID: Int, depth: Int) throws -> FlatOutline {
        guard depth <= Font.maxComponentNesting else {
            throw FontWriteError.unencodable("glyph \(glyphID): composite references form a cycle")
        }
        switch glyphs[glyphID].outline {
        case .simple(let simple):
            var flat = FlatOutline()
            flat.endPoints = simple.endPoints
            flat.xs = simple.points.map { Double($0.x) }
            flat.ys = simple.points.map { Double($0.y) }
            flat.onCurve = simple.points.map(\.onCurve)
            flat.overlapping = simple.overlapping
            return flat
        case .composite(let components):
            var result = FlatOutline()
            for component in components {
                var child = try flattenedOutline(of: Int(component.glyphID), depth: depth + 1)
                switch component.placement {
                case .anchor(let parentPoint, let childPoint):
                    // Transform first, then align the anchor points.
                    child.apply(component.transform)
                    let parent = Int(parentPoint)
                    let own = Int(childPoint)
                    guard parent < result.xs.count, own < child.xs.count else {
                        throw FontWriteError.unencodable(
                            "glyph \(glyphID): component anchor point \(parentPoint)/\(childPoint) does not exist")
                    }
                    child.translate(result.xs[parent] - child.xs[own], result.ys[parent] - child.ys[own])
                case .offset(let x, let y):
                    // Without SCALED_COMPONENT_OFFSET the offset is applied after
                    // the transform (Microsoft behavior, fontTools default).
                    if component.flags & GlyphComponent.scaledComponentOffset != 0 {
                        child.translate(Double(x), Double(y))
                        child.apply(component.transform)
                    } else {
                        child.apply(component.transform)
                        child.translate(Double(x), Double(y))
                    }
                }
                if component.flags & GlyphComponent.overlapCompound != 0 { child.overlapping = true }
                result.append(child)
            }
            return result
        }
    }

    /// Replaces every composite glyph with a simple glyph holding its flattened
    /// outline, so later outline operations transform each contour exactly
    /// once (technical design §4.1 step 4). The composite's own instructions are
    /// dropped: they were written for hinted components that no longer exist.
    public mutating func decomposeComposites() throws {
        var decomposed = glyphs
        for glyphID in glyphs.indices where glyphs[glyphID].isComposite {
            decomposed[glyphID] = Glyph(outline: .simple(try flattenedOutline(of: glyphID).rounded()))
        }
        glyphs = decomposed
    }
}
