/// One entry of the `glyf` table. Glyphs are addressed by glyph ID (their index
/// in `Font.glyphs`); see technical design §4.2.
public struct Glyph: Equatable, Sendable {
    public var outline: GlyphOutline
    /// TrueType bytecode attached to this glyph, kept verbatim so that a write
    /// without outline operations preserves hinting.
    public var instructions: [UInt8]

    public init(outline: GlyphOutline, instructions: [UInt8] = []) {
        self.outline = outline
        self.instructions = instructions
    }

    public static let empty = Glyph(outline: .simple(SimpleOutline()))

    public var isComposite: Bool {
        if case .composite = outline { return true }
        return false
    }
}

public enum GlyphOutline: Equatable, Sendable {
    /// Contours of quadratic points. A glyph without contours is a simple outline
    /// with no points (written as a zero-length glyf entry).
    case simple(SimpleOutline)
    case composite([GlyphComponent])
}

public struct GlyphPoint: Equatable, Sendable {
    // Int32 rather than Int16: operations may produce out-of-range values that
    // the writer must reject explicitly instead of silently wrapping.
    public var x: Int32
    public var y: Int32
    public var onCurve: Bool

    public init(x: Int32, y: Int32, onCurve: Bool) {
        self.x = x
        self.y = y
        self.onCurve = onCurve
    }
}

public struct SimpleOutline: Equatable, Sendable {
    /// Index of the last point of each contour.
    public var endPoints: [Int]
    public var points: [GlyphPoint]
    /// OVERLAP_SIMPLE flag; Apple rasterizers use it to pick the overlap-safe fill path.
    public var overlapping: Bool

    public init(endPoints: [Int] = [], points: [GlyphPoint] = [], overlapping: Bool = false) {
        self.endPoints = endPoints
        self.points = points
        self.overlapping = overlapping
    }

    public var isEmpty: Bool { points.isEmpty }
}

public struct GlyphComponent: Equatable, Sendable {
    public enum Placement: Equatable, Sendable {
        /// Component translated by (x, y) font units.
        case offset(x: Int32, y: Int32)
        /// Component moved so its point `childPoint` lands on the already
        /// assembled parent point `parentPoint`.
        case anchor(parentPoint: UInt16, childPoint: UInt16)
    }

    /// Transform coefficients as raw F2Dot14 values, so they round-trip exactly.
    public enum Transform: Equatable, Sendable {
        case identity
        case scale(Int16)
        case xyScale(x: Int16, y: Int16)
        case matrix(xx: Int16, xy: Int16, yx: Int16, yy: Int16)

        /// (xx, xy, yx, yy): x' = xx·x + yx·y, y' = xy·x + yy·y.
        var coefficients: (Double, Double, Double, Double) {
            switch self {
            case .identity: return (1, 0, 0, 1)
            case .scale(let s): return (f2dot14(s), 0, 0, f2dot14(s))
            case .xyScale(let x, let y): return (f2dot14(x), 0, 0, f2dot14(y))
            case .matrix(let xx, let xy, let yx, let yy):
                return (f2dot14(xx), f2dot14(xy), f2dot14(yx), f2dot14(yy))
            }
        }
    }

    public var glyphID: UInt16
    public var placement: Placement
    public var transform: Transform
    /// Only the semantic flag bits (`GlyphComponent.preservedFlags`); the
    /// encoding bits are derived from the other fields when writing.
    public var flags: UInt16

    public init(glyphID: UInt16, placement: Placement, transform: Transform = .identity, flags: UInt16 = 0) {
        self.glyphID = glyphID
        self.placement = placement
        self.transform = transform
        self.flags = flags & GlyphComponent.preservedFlags
    }

    static let argsAreWords: UInt16 = 0x0001
    static let argsAreXYValues: UInt16 = 0x0002
    static let roundXYToGrid: UInt16 = 0x0004
    static let weHaveAScale: UInt16 = 0x0008
    static let nonOverlapping: UInt16 = 0x0010
    static let moreComponents: UInt16 = 0x0020
    static let weHaveXYScale: UInt16 = 0x0040
    static let weHaveTwoByTwo: UInt16 = 0x0080
    static let weHaveInstructions: UInt16 = 0x0100
    static let useMyMetrics: UInt16 = 0x0200
    static let overlapCompound: UInt16 = 0x0400
    static let scaledComponentOffset: UInt16 = 0x0800
    static let unscaledComponentOffset: UInt16 = 0x1000

    /// Same set fontTools keeps after decompiling, so its component comparison
    /// sees exactly what we preserve.
    public static let preservedFlags: UInt16 =
        roundXYToGrid | nonOverlapping | useMyMetrics | overlapCompound
        | scaledComponentOffset | unscaledComponentOffset
}

func f2dot14(_ raw: Int16) -> Double { Double(raw) / 16384 }

// MARK: - Parsing

private let flagOnCurve: UInt8 = 0x01
private let flagXShort: UInt8 = 0x02
private let flagYShort: UInt8 = 0x04
private let flagRepeat: UInt8 = 0x08
private let flagXSameOrPositive: UInt8 = 0x10
private let flagYSameOrPositive: UInt8 = 0x20
private let flagOverlapSimple: UInt8 = 0x40

extension Glyph {
    static func parse(glyf: [UInt8], range: Range<Int>, numGlyphs: Int) throws -> Glyph {
        if range.isEmpty { return .empty }
        var reader = ByteReader(glyf, from: range.lowerBound, to: range.upperBound, context: "glyf")
        let contourCount = Int(try reader.i16())
        try reader.skip(8)  // bbox: recomputed on write
        if contourCount >= 0 {
            return try parseSimple(&reader, contourCount: contourCount)
        }
        return try parseComposite(&reader, numGlyphs: numGlyphs)
    }

    private static func parseSimple(_ reader: inout ByteReader, contourCount: Int) throws -> Glyph {
        if contourCount == 0 { return .empty }
        var endPoints: [Int] = []
        endPoints.reserveCapacity(contourCount)
        var previous = -1
        for _ in 0..<contourCount {
            let end = Int(try reader.u16())
            guard end >= previous else {
                throw FontLoadError.malformed("glyf: contour end points are not ascending")
            }
            endPoints.append(end)
            previous = end
        }
        let pointCount = previous + 1
        let instructions = try reader.read(Int(try reader.u16()))

        var flags: [UInt8] = []
        flags.reserveCapacity(pointCount)
        while flags.count < pointCount {
            let flag = try reader.u8()
            flags.append(flag)
            if flag & flagRepeat != 0 {
                let repeats = Int(try reader.u8())
                for _ in 0..<repeats { flags.append(flag) }
            }
        }
        guard flags.count == pointCount else {
            throw FontLoadError.malformed("glyf: flag repeat runs past the last point")
        }

        var points = [GlyphPoint](repeating: GlyphPoint(x: 0, y: 0, onCurve: false), count: pointCount)
        var x: Int32 = 0
        for index in 0..<pointCount {
            let flag = flags[index]
            if flag & flagXShort != 0 {
                let delta = Int32(try reader.u8())
                x += flag & flagXSameOrPositive != 0 ? delta : -delta
            } else if flag & flagXSameOrPositive == 0 {
                x += Int32(try reader.i16())
            }
            points[index].x = x
            points[index].onCurve = flag & flagOnCurve != 0
        }
        var y: Int32 = 0
        for index in 0..<pointCount {
            let flag = flags[index]
            if flag & flagYShort != 0 {
                let delta = Int32(try reader.u8())
                y += flag & flagYSameOrPositive != 0 ? delta : -delta
            } else if flag & flagYSameOrPositive == 0 {
                y += Int32(try reader.i16())
            }
            points[index].y = y
        }
        let outline = SimpleOutline(
            endPoints: endPoints, points: points, overlapping: flags[0] & flagOverlapSimple != 0)
        return Glyph(outline: .simple(outline), instructions: instructions)
    }

    private static func parseComposite(_ reader: inout ByteReader, numGlyphs: Int) throws -> Glyph {
        var components: [GlyphComponent] = []
        var hasInstructions = false
        var more = true
        while more {
            let flags = try reader.u16()
            let glyphID = try reader.u16()
            guard Int(glyphID) < numGlyphs else {
                throw FontLoadError.malformed("glyf: component references glyph \(glyphID) beyond numGlyphs")
            }
            let placement: GlyphComponent.Placement
            let words = flags & GlyphComponent.argsAreWords != 0
            if flags & GlyphComponent.argsAreXYValues != 0 {
                let x = words ? Int32(try reader.i16()) : Int32(try reader.i8())
                let y = words ? Int32(try reader.i16()) : Int32(try reader.i8())
                placement = .offset(x: x, y: y)
            } else {
                let parent = words ? try reader.u16() : UInt16(try reader.u8())
                let child = words ? try reader.u16() : UInt16(try reader.u8())
                placement = .anchor(parentPoint: parent, childPoint: child)
            }
            let transform: GlyphComponent.Transform
            if flags & GlyphComponent.weHaveAScale != 0 {
                transform = .scale(try reader.i16())
            } else if flags & GlyphComponent.weHaveXYScale != 0 {
                transform = .xyScale(x: try reader.i16(), y: try reader.i16())
            } else if flags & GlyphComponent.weHaveTwoByTwo != 0 {
                transform = .matrix(
                    xx: try reader.i16(), xy: try reader.i16(), yx: try reader.i16(), yy: try reader.i16())
            } else {
                transform = .identity
            }
            components.append(
                GlyphComponent(glyphID: glyphID, placement: placement, transform: transform, flags: flags))
            hasInstructions = hasInstructions || flags & GlyphComponent.weHaveInstructions != 0
            more = flags & GlyphComponent.moreComponents != 0
        }
        let instructions = hasInstructions ? try reader.read(Int(try reader.u16())) : []
        return Glyph(outline: .composite(components), instructions: instructions)
    }
}

// MARK: - Encoding

struct BoundingBox: Equatable {
    var xMin: Int32
    var yMin: Int32
    var xMax: Int32
    var yMax: Int32

    static let zero = BoundingBox(xMin: 0, yMin: 0, xMax: 0, yMax: 0)

    init(xMin: Int32, yMin: Int32, xMax: Int32, yMax: Int32) {
        self.xMin = xMin
        self.yMin = yMin
        self.xMax = xMax
        self.yMax = yMax
    }

    /// nil for an outline without points.
    init?(_ points: [GlyphPoint]) {
        guard let first = points.first else { return nil }
        var box = BoundingBox(xMin: first.x, yMin: first.y, xMax: first.x, yMax: first.y)
        for point in points {
            box.xMin = min(box.xMin, point.x)
            box.yMin = min(box.yMin, point.y)
            box.xMax = max(box.xMax, point.x)
            box.yMax = max(box.yMax, point.y)
        }
        self = box
    }

    func union(_ other: BoundingBox) -> BoundingBox {
        BoundingBox(
            xMin: min(xMin, other.xMin), yMin: min(yMin, other.yMin),
            xMax: max(xMax, other.xMax), yMax: max(yMax, other.yMax))
    }
}

func checkedInt16(_ value: Int32, _ what: @autoclosure () -> String) throws -> Int16 {
    guard let narrow = Int16(exactly: value) else {
        throw FontWriteError.unencodable("\(what()) value \(value) does not fit in 16 bits")
    }
    return narrow
}

extension Glyph {
    /// Serializes one glyf entry. `bounds` is the glyph's bounding box (for
    /// composites, of the flattened outline); nil means the glyph has no points.
    /// Returns an empty array for glyphs without contours, which loca encodes
    /// as a zero-length entry.
    func encoded(bounds: BoundingBox?, keepInstructions: Bool, glyphID: Int) throws -> [UInt8] {
        let instructions = keepInstructions ? self.instructions : []
        guard instructions.count <= Int(UInt16.max) else {
            throw FontWriteError.unencodable("glyph \(glyphID): instructions longer than 65535 bytes")
        }
        var writer = ByteWriter()
        switch outline {
        case .simple(let simple):
            if simple.isEmpty { return [] }
            // Operations build outlines in memory; an inconsistent contour
            // list would otherwise be written as a silently corrupt glyph.
            guard simple.endPoints.last == simple.points.count - 1,
                zip(simple.endPoints, simple.endPoints.dropFirst()).allSatisfy({ $0 <= $1 })
            else {
                throw FontWriteError.unencodable("glyph \(glyphID): contour end points do not match its points")
            }
            guard let contourCount = Int16(exactly: simple.endPoints.count) else {
                throw FontWriteError.unencodable("glyph \(glyphID): more than 32767 contours")
            }
            try writeHeader(&writer, contours: contourCount, bounds: bounds, glyphID)
            for end in simple.endPoints {
                guard let value = UInt16(exactly: end) else {
                    throw FontWriteError.unencodable("glyph \(glyphID): more than 65535 points")
                }
                writer.u16(value)
            }
            writer.u16(UInt16(instructions.count))
            writer.append(instructions)
            try Glyph.writePoints(simple, into: &writer, glyphID: glyphID)
        case .composite(let components):
            try writeHeader(&writer, contours: -1, bounds: bounds, glyphID)
            for (index, component) in components.enumerated() {
                let isLast = index == components.count - 1
                try Glyph.writeComponent(
                    component, more: !isLast, instructions: isLast && !instructions.isEmpty,
                    into: &writer, glyphID: glyphID)
            }
            if !instructions.isEmpty {
                writer.u16(UInt16(instructions.count))
                writer.append(instructions)
            }
        }
        return writer.bytes
    }

    private func writeHeader(
        _ writer: inout ByteWriter, contours: Int16, bounds: BoundingBox?, _ glyphID: Int
    ) throws {
        let box = bounds ?? .zero
        writer.i16(contours)
        writer.i16(try checkedInt16(box.xMin, "glyph \(glyphID) xMin"))
        writer.i16(try checkedInt16(box.yMin, "glyph \(glyphID) yMin"))
        writer.i16(try checkedInt16(box.xMax, "glyph \(glyphID) xMax"))
        writer.i16(try checkedInt16(box.yMax, "glyph \(glyphID) yMax"))
    }

    private static func writePoints(_ outline: SimpleOutline, into writer: inout ByteWriter, glyphID: Int) throws {
        let count = outline.points.count
        var flags = [UInt8](repeating: 0, count: count)
        var xBytes = ByteWriter()
        var yBytes = ByteWriter()
        var previous = GlyphPoint(x: 0, y: 0, onCurve: false)
        for (index, point) in outline.points.enumerated() {
            _ = try checkedInt16(point.x, "glyph \(glyphID) x coordinate")
            _ = try checkedInt16(point.y, "glyph \(glyphID) y coordinate")
            var flag: UInt8 = point.onCurve ? flagOnCurve : 0
            if index == 0 && outline.overlapping { flag |= flagOverlapSimple }
            let dx = point.x - previous.x
            if dx == 0 {
                flag |= flagXSameOrPositive
            } else if abs(dx) <= 255 {
                flag |= flagXShort | (dx > 0 ? flagXSameOrPositive : 0)
                xBytes.u8(UInt8(abs(dx)))
            } else {
                xBytes.i16(try checkedInt16(dx, "glyph \(glyphID) x delta"))
            }
            let dy = point.y - previous.y
            if dy == 0 {
                flag |= flagYSameOrPositive
            } else if abs(dy) <= 255 {
                flag |= flagYShort | (dy > 0 ? flagYSameOrPositive : 0)
                yBytes.u8(UInt8(abs(dy)))
            } else {
                yBytes.i16(try checkedInt16(dy, "glyph \(glyphID) y delta"))
            }
            flags[index] = flag
            previous = point
        }
        // Run-length encode flags; a run of two costs the same either way, so
        // only longer runs use the repeat byte.
        var index = 0
        while index < count {
            let flag = flags[index]
            var run = 1
            while index + run < count && flags[index + run] == flag && run < 256 { run += 1 }
            if run > 2 {
                writer.u8(flag | flagRepeat)
                writer.u8(UInt8(run - 1))
            } else {
                for _ in 0..<run { writer.u8(flag) }
            }
            index += run
        }
        writer.append(xBytes.bytes)
        writer.append(yBytes.bytes)
    }

    private static func writeComponent(
        _ component: GlyphComponent, more: Bool, instructions: Bool,
        into writer: inout ByteWriter, glyphID: Int
    ) throws {
        var flags = component.flags & GlyphComponent.preservedFlags
        if more { flags |= GlyphComponent.moreComponents }
        if instructions { flags |= GlyphComponent.weHaveInstructions }
        var args = ByteWriter()
        switch component.placement {
        case .offset(let x, let y):
            flags |= GlyphComponent.argsAreXYValues
            if let x8 = Int8(exactly: x), let y8 = Int8(exactly: y) {
                args.i8(x8)
                args.i8(y8)
            } else {
                flags |= GlyphComponent.argsAreWords
                args.i16(try checkedInt16(x, "glyph \(glyphID) component x offset"))
                args.i16(try checkedInt16(y, "glyph \(glyphID) component y offset"))
            }
        case .anchor(let parent, let child):
            if let p8 = UInt8(exactly: parent), let c8 = UInt8(exactly: child) {
                args.u8(p8)
                args.u8(c8)
            } else {
                flags |= GlyphComponent.argsAreWords
                args.u16(parent)
                args.u16(child)
            }
        }
        switch component.transform {
        case .identity:
            break
        case .scale(let s):
            flags |= GlyphComponent.weHaveAScale
            args.i16(s)
        case .xyScale(let x, let y):
            flags |= GlyphComponent.weHaveXYScale
            args.i16(x)
            args.i16(y)
        case .matrix(let xx, let xy, let yx, let yy):
            flags |= GlyphComponent.weHaveTwoByTwo
            args.i16(xx)
            args.i16(xy)
            args.i16(yx)
            args.i16(yy)
        }
        writer.u16(flags)
        writer.u16(component.glyphID)
        writer.append(args.bytes)
    }
}
