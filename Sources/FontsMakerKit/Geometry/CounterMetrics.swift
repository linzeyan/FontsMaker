import CoreGraphics

// Counter (enclosed hole) metrics behind the risk grades, ported from the
// Phase 0 spike (spikes/embolden/Sources/EmboldenSpike/Geometry.swift) where the
// thresholds were calibrated. Areas and containment are computed on polylines
// flattened at 0.2 units, the same as in the spike.

/// One closed subpath flattened to a polyline.
struct PolylineContour {
    var points: [CGPoint]
    /// Signed shoelace area in y-up font units; positive = counter-clockwise.
    var area: Double
    var bounds: CGRect

    init(_ points: [CGPoint]) {
        self.points = points
        var doubled = 0.0
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity
        for index in points.indices {
            let p = points[index]
            let q = points[(index + 1) % points.count]
            doubled += Double(p.x * q.y - q.x * p.y)
            minX = min(minX, Double(p.x))
            maxX = max(maxX, Double(p.x))
            minY = min(minY, Double(p.y))
            maxY = max(maxY, Double(p.y))
        }
        area = doubled / 2
        bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func contains(_ probe: CGPoint) -> Bool {
        guard bounds.contains(probe) else { return false }
        var inside = false
        var j = points.count - 1
        for i in points.indices {
            let a = points[i]
            let b = points[j]
            if (a.y > probe.y) != (b.y > probe.y) {
                let x = (b.x - a.x) * (probe.y - a.y) / (b.y - a.y) + a.x
                if probe.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}

func flattenedContours(_ path: CGPath, flatness: CGFloat = 0.2) -> [PolylineContour] {
    var contours: [PolylineContour] = []
    var current: [CGPoint] = []
    var lastMove = CGPoint.zero
    func finish() {
        if current.count >= 2 {
            if current.count > 2, current.first == current.last { current.removeLast() }
            contours.append(PolylineContour(current))
        }
        current.removeAll(keepingCapacity: true)
    }
    path.flattened(threshold: flatness).applyWithBlock { element in
        let e = element.pointee
        switch e.type {
        case .moveToPoint:
            finish()
            lastMove = e.points[0]
            current.append(lastMove)
        case .addLineToPoint:
            if current.isEmpty { current.append(lastMove) }
            current.append(e.points[0])
        case .closeSubpath:
            finish()
        default:
            // flattened(threshold:) emits only lines.
            break
        }
    }
    finish()
    return contours
}

/// Contours split into outer and hole by sign relative to the largest one.
/// Valid only for overlap-free paths: a normalized source or the union output.
struct OutlineStats {
    /// Collapses to a point once rounded to integer units.
    static let debrisExtent: CGFloat = 2
    /// Below 2×2 units: a sliver, not a stroke or a counter.
    static let tinyArea = 4.0

    var outer: [PolylineContour] = []
    var holes: [PolylineContour] = []
    var bounds = CGRect.null

    init(_ path: CGPath) {
        guard !path.isEmpty else { return }
        bounds = path.boundingBoxOfPath
        let contours = flattenedContours(path).filter {
            max($0.bounds.width, $0.bounds.height) >= OutlineStats.debrisExtent && abs($0.area) >= OutlineStats.tinyArea
        }
        guard let dominant = contours.max(by: { abs($0.area) < abs($1.area) }) else { return }
        let outerSign = dominant.area > 0 ? 1.0 : -1.0
        for contour in contours {
            if contour.area * outerSign > 0 { outer.append(contour) } else { holes.append(contour) }
        }
    }
}

/// Source holes smaller than this are hairline gaps where two stroke contours
/// almost abut (鈗, ♴ in Phase 0), not designed counters. Closing them is
/// harmless, so they must not count as "counter vanished" or drive the ratio.
let counterFloorArea = 400.0

/// New holes smaller than this read as a speck where strokes meet.
let pinholeArea = 100.0

struct HoleMatch {
    /// Source counters (≥ counterFloorArea) with no surviving hole inside them.
    var vanished = 0
    /// Source counters pinched into more than one hole.
    var split = 0
    /// Smallest per-counter surviving-area ratio; nil when the source has no counter.
    var minRatio: Double?
    /// Smallest hole that lies in no source counter (strokes merged around a gap).
    var newMinArea: Double?
    var counters = 0
}

/// Emboldened holes are the source counters inset by about weight/2, so any
/// vertex of a surviving hole lies inside the source counter it came from.
func matchHoles(before: [PolylineContour], after: [PolylineContour]) -> HoleMatch {
    var match = HoleMatch()
    var areaIn = [Double](repeating: 0, count: before.count)
    var countIn = [Int](repeating: 0, count: before.count)
    for hole in after {
        let probe = hole.points[0]
        // Counters nest (口 inside 囗 in 國), so attribute to the innermost one.
        var best: Int?
        for (index, candidate) in before.enumerated() where candidate.contains(probe) {
            if best == nil || abs(candidate.area) < abs(before[best!].area) { best = index }
        }
        if let best {
            areaIn[best] += abs(hole.area)
            countIn[best] += 1
        } else {
            match.newMinArea = min(match.newMinArea ?? .infinity, abs(hole.area))
        }
    }
    for (index, counter) in before.enumerated() where abs(counter.area) >= counterFloorArea {
        match.counters += 1
        if countIn[index] == 0 { match.vanished += 1 }
        if countIn[index] > 1 { match.split += 1 }
        match.minRatio = min(match.minRatio ?? .infinity, areaIn[index] / abs(counter.area))
    }
    return match
}
