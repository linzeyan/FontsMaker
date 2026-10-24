import CoreGraphics
import CoreText
import Foundation

// Import normalization (plan Phase 4a): CFF/CFF2 outlines and variable fonts
// become the static TrueType font every operation works on. CoreText does
// the hard part (CFF charstrings, gvar/CFF2 blending, avar, HVAR) and hands
// back each glyph at the chosen instance; cu2qu turns its cubics into
// quadratics. Glyph IDs stay as they are, so cmap, GSUB, GPOS and GDEF carry
// over byte for byte; vmtx keeps its advances, and its side bearings follow
// the new outlines so every glyph keeps its vertical origin.

extension Font {
    /// Tables of outlines and variations the converted font no longer has,
    /// plus hinting, which belonged to the old outlines (design D5), and the
    /// old glyf/loca/hmtx, which are rebuilt from the converted glyphs.
    static let normalizationDroppedTables: Set<String> = Font.hintingTables.union([
        "CFF ", "CFF2", "VORG", "fvar", "gvar", "avar", "cvar", "HVAR", "VVAR", "MVAR", "STAT", "DSIG",
        "glyf", "loca", "hmtx",
    ])

    static func normalized(
        _ face: SFNTFace, format: OutlineFormat, sfnt: [UInt8], variation: [String: Double]
    ) throws -> Font {
        let axes = try face.tables["fvar"].map { try FvarTable.parse($0, names: []).axes }
        let coordinates = try resolveVariation(variation, axes: axes)
        guard let head = face.tables["head"] else { throw FontLoadError.missingTable("head") }
        guard let maxp = face.tables["maxp"] else { throw FontLoadError.missingTable("maxp") }
        guard head.count >= 54, maxp.count >= 6 else { throw FontLoadError.malformed("head or maxp table too short") }

        let numGlyphs = Int(maxp.readU16(at: 4))
        let outlines = try CoreTextOutlines.extract(
            sfnt: sfnt, head: head, numGlyphs: numGlyphs, unitsPerEm: head.readU16(at: 18),
            coordinates: coordinates,
            // CFF and CFF2 run counter-clockwise around ink, glyf clockwise.
            reversingDirection: format != .trueType,
            // Variable fonts keep overlapping contours, which Apple's
            // rasterizer draws seam-free only with OVERLAP_SIMPLE; fontTools'
            // instancer sets it on every glyph for the same reason.
            overlapping: axes != nil)

        var tables = face.tables.filter { !normalizationDroppedTables.contains($0.key) }
        tables["maxp"] = trueTypeMaxp(numGlyphs: maxp.readU16(at: 4))
        var font = try Font(
            sfntVersion: 0x0001_0000, tables: tables, outlines: (outlines.glyphs, outlines.metrics))
        if axes != nil { font.applyInstanceStyle(coordinates) }
        if let vertical = font.verticalMetrics {
            if format != .trueType, let vorg = face.tables["VORG"] {
                // A CFF font with VORG is set vertically from VORG, not from
                // tsb + top: its tools write tsb from their own rounding of
                // the top, which leaves the two up to 1 unit apart.
                font.keepVerticalOrigins(try vorgOrigins(vorg, numGlyphs: numGlyphs))
            } else {
                let atDefault = coordinates.allSatisfy { point in
                    axes?.first { $0.tag == point.tag }?.defaultValue == point.value
                }
                let sourceTops: [Double?]
                switch format {
                case .trueType:
                    sourceTops = try glyfTops(face.tables, numGlyphs: numGlyphs)
                case .cff,
                    .cff2 where atDefault:
                    sourceTops = outlines.curveTops
                case .cff, .cff2:
                    sourceTops = try CoreTextOutlines.curveTops(
                        sfnt: sfnt, head: head, numGlyphs: numGlyphs, unitsPerEm: head.readU16(at: 18),
                        coordinates: (axes ?? []).map { ($0.tag, $0.defaultValue) })
                }
                font.keepVerticalOrigins(
                    zip(sourceTops, vertical).map { top, metric in top.map { $0 + Double(metric.topSideBearing) } })
            }
        }
        return font
    }

    /// `origins` are where the source puts each glyph's vertical origin, in
    /// y: VORG, or tsb + the glyph's top at the default instance (the
    /// curve's own bound for CFF, the glyf header's yMax for TrueType). A
    /// TrueType renderer puts the origin at tsb + yMax of the points, and
    /// that yMax moves wherever cu2qu puts an off-curve point above the curve
    /// or another instance moves the outline. The tsb moves with it, so the
    /// origin, and with it the ink in vertical text, stays where the source
    /// has it. VVAR is not applied: the origin is the default instance's.
    mutating func keepVerticalOrigins(_ origins: [Double?]) {
        guard var metrics = verticalMetrics else { return }
        for glyph in metrics.indices where glyph < glyphs.count && glyph < origins.count {
            guard let origin = origins[glyph], case .simple(let outline) = glyphs[glyph].outline,
                let top = outline.points.map(\.y).max()
            else { continue }
            metrics[glyph].topSideBearing = Int16(clamping: EmboldenGeometry.rounded(origin - Double(top)))
        }
        verticalMetrics = metrics
    }

    /// Each glyph's vertical origin from a VORG table.
    static func vorgOrigins(_ vorg: [UInt8], numGlyphs: Int) throws -> [Double?] {
        guard vorg.count >= 8 else { throw FontLoadError.malformed("VORG: table too short") }
        let count = Int(vorg.readU16(at: 6))
        guard vorg.count >= 8 + 4 * count else { throw FontLoadError.malformed("VORG: table too short") }
        var origins = [Double?](repeating: Double(vorg.readI16(at: 4)), count: numGlyphs)
        for record in 0..<count {
            let glyph = Int(vorg.readU16(at: 8 + 4 * record))
            if glyph < numGlyphs { origins[glyph] = Double(vorg.readI16(at: 10 + 4 * record)) }
        }
        return origins
    }

    /// yMax from each glyph's glyf header; nil for an empty glyph.
    static func glyfTops(_ tables: [String: [UInt8]], numGlyphs: Int) throws -> [Double?] {
        guard let head = tables["head"], let loca = tables["loca"], let glyf = tables["glyf"] else {
            throw FontLoadError.missingTable("glyf")
        }
        let longLoca = head.readI16(at: 50) == 1
        guard loca.count >= (numGlyphs + 1) * (longLoca ? 4 : 2) else {
            throw FontLoadError.malformed("loca: table too short")
        }
        func offset(_ index: Int) -> Int {
            longLoca
                ? Int(UInt32(loca.readU16(at: 4 * index)) << 16 | UInt32(loca.readU16(at: 4 * index + 2)))
                : Int(loca.readU16(at: 2 * index)) * 2
        }
        return (0..<numGlyphs).map { index in
            let start = offset(index)
            guard offset(index + 1) - start >= 10, start + 10 <= glyf.count else { return nil }
            return Double(glyf.readI16(at: start + 8))
        }
    }

    /// Every axis gets a value: the given one, or the axis default. CoreText
    /// must never choose: it sets opsz from the point size (here unitsPerEm,
    /// so the largest optical size), and a font created from data without
    /// axis values may come up at a named instance rather than the default.
    static func resolveVariation(
        _ variation: [String: Double], axes: [VariationAxis]?
    ) throws -> [(tag: String, value: Double)] {
        guard let axes else {
            guard variation.isEmpty else { throw FontLoadError.notVariable }
            return []
        }
        if let unknown = variation.keys.sorted().first(where: { tag in !axes.contains { $0.tag == tag } }) {
            throw FontLoadError.unknownAxis(tag: unknown, available: axes.map(\.tag))
        }
        return try axes.map { axis in
            let value = variation[axis.tag] ?? axis.defaultValue
            guard value.isFinite, value >= axis.minimum, value <= axis.maximum else {
                throw FontLoadError.axisValueOutOfRange(
                    tag: axis.tag, value: value, minimum: axis.minimum, maximum: axis.maximum)
            }
            return (axis.tag, value)
        }
    }

    /// A version 1.0 maxp (CFF fonts carry the 6-byte version 0.5). The
    /// writer recomputes the point and contour limits; hinting limits are
    /// those of a font without instructions.
    static func trueTypeMaxp(numGlyphs: UInt16) -> [UInt8] {
        var maxp = [UInt8](repeating: 0, count: 32)
        maxp.writeU32(0x0001_0000, at: 0)
        maxp.writeU16(numGlyphs, at: 4)
        maxp.writeU16(1, at: 14)  // maxZones: 1 means no twilight zone
        return maxp
    }

    /// The style fields fontTools' instancer derives from the instance
    /// location, so the converted font sorts and names like a static font
    /// of that weight, width and slant. Line metrics varied by MVAR are not
    /// applied: they stay at the default instance.
    mutating func applyInstanceStyle(_ coordinates: [(tag: String, value: Double)]) {
        for (tag, value) in coordinates {
            switch tag {
            case "wght":
                os2?.weightClass = UInt16(EmboldenGeometry.rounded(min(max(value, 1), 1000)))
            case "wdth":
                if var table = tables["OS/2"], table.count >= 8 {
                    table.writeU16(Font.widthClass(wdth: value), at: 6)
                    tables["OS/2"] = table
                }
            case "slnt":
                if var table = tables["post"], table.count >= 8 {
                    let fixed = EmboldenGeometry.rounded(min(max(value, -90), 90) * 65536)
                    table.writeU32(UInt32(bitPattern: fixed), at: 4)
                    tables["post"] = table
                }
            default:
                break
            }
        }
        let average = averageAdvanceWidth()
        os2?.xAvgCharWidth = average
    }

    /// OS/2 usWidthClass for a wdth value: fontTools' piecewise-linear map
    /// from percent of normal width to the nine width classes.
    static func widthClass(wdth: Double) -> UInt16 {
        let stops: [(percent: Double, widthClass: Double)] = [
            (50, 1), (62.5, 2), (75, 3), (87.5, 4), (100, 5), (112.5, 6), (125, 7), (150, 8), (200, 9),
        ]
        let value = min(max(wdth, 50), 200)
        for (lower, upper) in zip(stops, stops.dropFirst()) where value <= upper.percent {
            let t = (value - lower.percent) / (upper.percent - lower.percent)
            return UInt16(EmboldenGeometry.rounded(lower.widthClass + t * (upper.widthClass - lower.widthClass)))
        }
        return 9
    }
}

enum CoreTextOutlines {
    /// Glyphs per work item: enough that scheduling costs nothing next to
    /// path extraction, small enough to balance a 65,535-glyph font.
    static let batchSize = 64

    /// Each glyph's outline and advance at the instance `coordinates`, in
    /// font units: CoreText at a point size of unitsPerEm uses one point per unit.
    static func extract(
        sfnt: [UInt8], head: [UInt8], numGlyphs: Int, unitsPerEm: UInt16,
        coordinates: [(tag: String, value: Double)], reversingDirection: Bool, overlapping: Bool
    ) throws -> (glyphs: [Glyph], metrics: [HorizontalMetric], curveTops: [Double?]) {
        let (font, bytes) = try instanceFont(
            sfnt: sfnt, head: head, numGlyphs: numGlyphs, unitsPerEm: unitsPerEm, coordinates: coordinates)
        defer { withExtendedLifetime(bytes) {} }

        var glyphIDs = (0..<numGlyphs).map { CGGlyph($0) }
        var advances = [CGSize](repeating: .zero, count: numGlyphs)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphIDs, &advances, numGlyphs)

        let slots = OutlineSlots(count: numGlyphs)
        nonisolated(unsafe) let shared = font
        let batches = (numGlyphs + batchSize - 1) / batchSize
        DispatchQueue.concurrentPerform(iterations: batches) { batch in
            for glyphID in batch * batchSize..<min(numGlyphs, (batch + 1) * batchSize) {
                // CoreGraphics autoreleases temporaries; drain them per glyph.
                slots.store(
                    glyphID,
                    autoreleasepool {
                        Result {
                            try outline(
                                of: glyphID, in: shared, reversingDirection: reversingDirection,
                                overlapping: overlapping)
                        }
                    })
            }
        }

        var glyphs: [Glyph] = []
        var metrics: [HorizontalMetric] = []
        var tops: [Double?] = []
        glyphs.reserveCapacity(numGlyphs)
        metrics.reserveCapacity(numGlyphs)
        tops.reserveCapacity(numGlyphs)
        for glyphID in 0..<numGlyphs {
            // In glyph order, so the first failing glyph is reported, however threads ran.
            let (outline, top) = try slots.take(glyphID).get()
            let advance = EmboldenGeometry.rounded(Double(advances[glyphID].width))
            guard let width = UInt16(exactly: advance) else {
                throw FontLoadError.outlineConversion("glyph \(glyphID) has advance width \(advance)")
            }
            glyphs.append(Glyph(outline: .simple(outline)))
            let lsb = outline.points.map(\.x).min() ?? 0
            metrics.append(HorizontalMetric(advanceWidth: width, leftSideBearing: Int16(clamping: lsb)))
            tops.append(top)
        }
        return (glyphs, metrics, tops)
    }

    /// Each glyph's top at `coordinates` as the curve itself reaches it
    /// (control points excluded); nil for an empty glyph.
    static func curveTops(
        sfnt: [UInt8], head: [UInt8], numGlyphs: Int, unitsPerEm: UInt16, coordinates: [(tag: String, value: Double)]
    ) throws -> [Double?] {
        let (font, bytes) = try instanceFont(
            sfnt: sfnt, head: head, numGlyphs: numGlyphs, unitsPerEm: unitsPerEm, coordinates: coordinates)
        defer { withExtendedLifetime(bytes) {} }
        return (0..<numGlyphs).map { glyphID in
            autoreleasepool { CTFontCreatePathForGlyph(font, CGGlyph(glyphID), nil).flatMap(top) }
        }
    }

    private static func top(_ path: CGPath) -> Double? {
        path.isEmpty ? nil : Double(path.boundingBoxOfPath.maxY)
    }

    /// The font at the instance, checked to be the one in the file.
    /// Returned with the bytes it reads from: CoreText does not keep them
    /// alive for the font, so the caller holds them while it uses the font.
    /// Released as soon as the font was made, they were read after being
    /// freed (CTFontGetAdvancesForGlyphs crashed on the iOS Simulator).
    private static func instanceFont(
        sfnt: [UInt8], head: [UInt8], numGlyphs: Int, unitsPerEm: UInt16, coordinates: [(tag: String, value: Double)]
    ) throws -> (font: CTFont, bytes: CFData) {
        let bytes = Data(sfnt) as CFData
        guard
            let descriptors = CTFontManagerCreateFontDescriptorsFromData(bytes) as? [CTFontDescriptor],
            var descriptor = descriptors.first
        else { throw FontLoadError.outlineConversion("CoreText cannot load the font") }
        if !coordinates.isEmpty {
            var variation: [NSNumber: NSNumber] = [:]
            for (tag, value) in coordinates { variation[NSNumber(value: tagNumber(tag))] = NSNumber(value: value) }
            // CoreText drops a value equal to the axis default and then lets
            // automatic optical sizing pick opsz from the point size (72 at
            // 1000 pt), so the explicit opsz only holds with that turned off.
            descriptor = CTFontDescriptorCreateCopyWithAttributes(
                descriptor,
                [kCTFontVariationAttribute: variation, kCTFontOpticalSizeAttribute: "none"] as CFDictionary)
        }
        let font = CTFontCreateWithFontDescriptor(descriptor, CGFloat(unitsPerEm), nil)
        try verify(font, head: head, numGlyphs: numGlyphs, coordinates: coordinates)
        return (font, bytes)
    }

    /// CoreText falls back quietly: an installed font of the same name, or
    /// axis values it ignores, would give plausible glyphs of the wrong font.
    private static func verify(
        _ font: CTFont, head: [UInt8], numGlyphs: Int, coordinates: [(tag: String, value: Double)]
    ) throws {
        let loadedHead = (CTFontCopyTable(font, CTFontTableTag(tagNumber("head")), []) as Data?).map { [UInt8]($0) }
        // checkSumAdjustment (offset 8) is rewritten when a collection member
        // is assembled into a standalone font; the rest identifies the font.
        func identity(_ head: [UInt8]) -> [UInt8] { head.count >= 12 ? Array(head[..<8] + head[12...]) : head }
        guard CTFontGetGlyphCount(font) == numGlyphs, loadedHead.map(identity) == identity(head) else {
            throw FontLoadError.outlineConversion("CoreText opened a different font than the one in the file")
        }
        guard !coordinates.isEmpty else { return }
        // CoreText lists only the axes away from their default.
        let applied = (CTFontCopyVariation(font) as? [NSNumber: NSNumber]) ?? [:]
        guard let axes = CTFontCopyVariationAxes(font) as? [[CFString: Any]] else {
            throw FontLoadError.outlineConversion("CoreText does not see the font's variation axes")
        }
        var defaults: [UInt32: Double] = [:]
        for axis in axes {
            guard let identifier = axis[kCTFontVariationAxisIdentifierKey] as? NSNumber,
                let value = axis[kCTFontVariationAxisDefaultValueKey] as? NSNumber
            else { continue }
            defaults[identifier.uint32Value] = value.doubleValue
        }
        for (tag, value) in coordinates {
            let key = tagNumber(tag)
            guard let actual = applied[NSNumber(value: key)]?.doubleValue ?? defaults[key] else {
                throw FontLoadError.outlineConversion("CoreText does not know axis '\(tag)'")
            }
            // CoreText keeps axis values in 16.16 fixed point.
            guard abs(actual - value) <= 1.0 / 32768 else {
                throw FontLoadError.outlineConversion(
                    "CoreText applied \(tag) \(formatNumber(actual)) instead of \(formatNumber(value))")
            }
        }
    }

    private static func outline(
        of glyphID: Int, in font: CTFont, reversingDirection: Bool, overlapping: Bool
    ) throws -> (SimpleOutline, top: Double?) {
        guard let path = CTFontCreatePathForGlyph(font, CGGlyph(glyphID), nil) else { return (SimpleOutline(), nil) }
        var outline = SimpleOutline()
        for contour in BezierContour.contours(of: path) {
            let points: [QuadraticPoint]
            do {
                points = try trueTypePoints(contour)
            } catch is EmboldenGeometry.CurveApproximationFailed {
                throw FontLoadError.outlineConversion(
                    "glyph \(glyphID): a curve could not be approximated by quadratics within tolerance")
            }
            guard let start = points.last else { continue }
            // Both orders begin at the contour's start point, as the source
            // and fontTools' converters do: reversal keeps it first.
            let kept = integerPoints(reversingDirection ? points.reversed() : [start] + points.dropLast())
            guard !kept.isEmpty else { continue }
            outline.points.append(contentsOf: kept)
            outline.endPoints.append(outline.points.count - 1)
        }
        outline.overlapping = overlapping && !outline.isEmpty
        return (outline, top(path))
    }

    /// Float TrueType points of one contour, in its direction, ending with its
    /// start point. As in fontTools' converters (cu2qu pen, instancer), every
    /// segment end point is explicit except two kinds, which stay implied:
    /// those cu2qu puts between the controls of one spline, and those
    /// CoreText puts back between two quadratics of a glyf outline. Implied,
    /// they stay midway between the controls once these are rounded; made
    /// explicit and rounded, glyf's half-unit midpoints would move every such
    /// curve by up to 0.7 u.
    static func trueTypePoints(_ contour: BezierContour) throws -> [QuadraticPoint] {
        let segments = contour.segments
        var points: [QuadraticPoint] = []
        func add(_ point: Vec2, onCurve: Bool) {
            points.append(QuadraticPoint(x: point.x, y: point.y, onCurve: onCurve))
        }
        for (index, segment) in segments.enumerated() {
            switch segment {
            case .line(let end):
                add(end, onCurve: true)
            case .quad(let control, let end):
                add(control, onCurve: false)
                if segments.count > 1, case .quad(let next, _) = segments[(index + 1) % segments.count],
                    isMidpoint(end, control, next)
                {
                    continue
                }
                add(end, onCurve: true)
            case .cubic(let c1, let c2, let end):
                guard
                    let spline = Cu2qu.quadraticSpline(
                        contour.start(of: index), c1, c2, end, tolerance: EmboldenGeometry.curveTolerance)
                else { throw EmboldenGeometry.CurveApproximationFailed() }
                for control in spline.dropFirst().dropLast() { add(control, onCurve: false) }
                add(end, onCurve: true)
            }
        }
        return points
    }

    /// CoreText computes the midpoint of two glyf controls exactly; the
    /// slack only absorbs its fixed-point blending of variable outlines.
    private static func isMidpoint(_ point: Vec2, _ a: Vec2, _ b: Vec2) -> Bool {
        abs(a.x + b.x - 2 * point.x) <= 1.0 / 1024 && abs(a.y + b.y - 2 * point.y) <= 1.0 / 1024
    }

    /// Rounded half up (fontTools otRound). Nothing is cleaned up beyond a
    /// repeated on-curve point: these are the designer's contours, not the
    /// debris a union leaves.
    static func integerPoints(_ points: [QuadraticPoint]) -> [GlyphPoint] {
        var kept: [GlyphPoint] = []
        for point in points {
            let rounded = GlyphPoint(
                x: EmboldenGeometry.rounded(point.x), y: EmboldenGeometry.rounded(point.y), onCurve: point.onCurve)
            if rounded.onCurve, let last = kept.last, last == rounded { continue }
            kept.append(rounded)
        }
        if kept.count > 1, let first = kept.first, first.onCurve, kept.last == first { kept.removeLast() }
        return kept
    }

    static func tagNumber(_ tag: String) -> UInt32 {
        tag.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// One slot per glyph, each written by exactly one worker.
private final class OutlineSlots: @unchecked Sendable {
    private var slots: [Result<(SimpleOutline, top: Double?), Error>?]
    private let lock = NSLock()

    init(count: Int) { slots = Array(repeating: nil, count: count) }

    func store(_ index: Int, _ result: Result<(SimpleOutline, top: Double?), Error>) {
        lock.withLock { slots[index] = result }
    }

    func take(_ index: Int) -> Result<(SimpleOutline, top: Double?), Error> { slots[index]! }
}
