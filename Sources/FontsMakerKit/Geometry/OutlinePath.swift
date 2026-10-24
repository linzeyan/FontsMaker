import CoreGraphics

extension SimpleOutline {
    /// The outline as a CGPath in font units (y up), decoded with TrueType's
    /// quadratic rules: two consecutive off-curve points imply an on-curve
    /// point midway, and a contour may consist of off-curve points only.
    var cgPath: CGPath {
        let path = CGMutablePath()
        for range in contourRanges {
            SimpleOutline.addContour(points[range], to: path)
        }
        return path
    }

    var contourRanges: [ClosedRange<Int>] {
        var start = 0
        return endPoints.map { end in
            defer { start = end + 1 }
            return start...end
        }
    }

    static func addContour(_ contour: ArraySlice<GlyphPoint>, to path: CGMutablePath) {
        guard !contour.isEmpty else { return }
        func point(_ p: GlyphPoint) -> CGPoint { CGPoint(x: Double(p.x), y: Double(p.y)) }
        func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }

        let points = Array(contour)
        let start: CGPoint
        let sequence: [GlyphPoint]
        if let firstOn = points.firstIndex(where: \.onCurve) {
            start = point(points[firstOn])
            sequence = Array(points[(firstOn + 1)...] + points[..<firstOn])
        } else {
            start = midpoint(point(points[points.count - 1]), point(points[0]))
            sequence = points
        }
        path.move(to: start)
        var control: CGPoint?
        for glyphPoint in sequence {
            let p = point(glyphPoint)
            if glyphPoint.onCurve {
                if let c = control {
                    path.addQuadCurve(to: p, control: c)
                } else {
                    path.addLine(to: p)
                }
                control = nil
            } else {
                if let c = control { path.addQuadCurve(to: midpoint(c, p), control: c) }
                control = p
            }
        }
        if let c = control { path.addQuadCurve(to: start, control: c) }
        path.closeSubpath()
    }
}
