import Foundation

/// The outlines step (Phase 4f, technical design §5.8): glyphs redrawn by
/// hand, each stored whole, keyed by the character that shows it.
///
/// Whole outlines rather than edits to the source's: a different version of
/// the source is refused by its sha256 anyway, so a diff would buy nothing and
/// would make the recipe unreadable on its own.
public struct OutlinesStep: Equatable, Sendable {
    /// Keyed by character, each exactly one Unicode scalar.
    public var glyphs: [String: EditedGlyph]

    public init(glyphs: [String: EditedGlyph]) {
        self.glyphs = glyphs
    }
}

/// One glyph as the editor draws it: closed cubic contours and an advance.
///
/// There is no separate left side bearing: the contours are in absolute font
/// units, and TrueType's lsb is the outline's xMin (design §4.1), so moving
/// the outline is what changes it.
public struct EditedGlyph: Equatable, Hashable, Sendable {
    public var advance: Int
    /// Closed contours. Direction follows TrueType (outer contours clockwise
    /// with y up), because the fill is nonzero and no step reorients them.
    public var contours: [[OutlineNode]]

    public init(advance: Int, contours: [[OutlineNode]]) {
        self.advance = advance
        self.contours = contours
    }
}

/// A point in font units.
public struct OutlinePoint: Equatable, Hashable, Sendable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

/// An on-curve point with its handles, as Illustrator and Figma show them.
/// The segment to the next node is a straight line when this node has no
/// outgoing handle and the next has no incoming one, a cubic curve otherwise
/// (a missing handle sits on its node).
public struct OutlineNode: Equatable, Hashable, Sendable {
    public var x: Int
    public var y: Int
    /// The control point before this node, absolute; nil when retracted.
    public var handleIn: OutlinePoint?
    /// The control point after this node, absolute; nil when retracted.
    public var handleOut: OutlinePoint?
    /// The two handles stay in line when one is dragged. Only the editor
    /// reads it; the font has no such notion, so the build ignores it.
    public var smooth: Bool

    public init(x: Int, y: Int, handleIn: OutlinePoint? = nil, handleOut: OutlinePoint? = nil, smooth: Bool = false) {
        self.x = x
        self.y = y
        self.handleIn = handleIn
        self.handleOut = handleOut
        self.smooth = smooth
    }

    public var point: OutlinePoint {
        get { OutlinePoint(x: x, y: y) }
        set {
            x = newValue.x
            y = newValue.y
        }
    }
}

// MARK: - Coding

extension OutlinesStep: Codable {
    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(["op", "glyphs"])
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        glyphs = try container.decode([String: EditedGlyph].self, forKey: AnyCodingKey("glyphs"))
        guard !glyphs.isEmpty else { throw decoder.invalid("glyphs", "must not be empty; leave the step out instead") }
        for key in glyphs.keys.sorted() where singleScalar(key) == nil {
            throw RecipeError.invalidValue(
                path: keyPath(decoder.codingPath + [AnyCodingKey("glyphs"), AnyCodingKey(key)]),
                reason: "'\(key)' must be exactly one character (one Unicode code point)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(glyphs, forKey: AnyCodingKey("glyphs"))
    }
}

extension EditedGlyph: Codable {
    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(["advance", "contours"])
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        advance = try container.decode(Int.self, forKey: AnyCodingKey("advance"))
        guard (0...Int(UInt16.max)).contains(advance) else {
            throw decoder.invalid("advance", "\(advance) is outside 0...65535")
        }
        contours = try container.decode([[OutlineNode]].self, forKey: AnyCodingKey("contours"))
        for (index, contour) in contours.enumerated() where contour.count < 2 {
            throw RecipeError.invalidValue(
                path: keyPath(decoder.codingPath + [AnyCodingKey("contours"), AnyCodingKey(intValue: index)!]),
                reason: "a contour needs at least 2 points")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(advance, forKey: AnyCodingKey("advance"))
        try container.encode(contours, forKey: AnyCodingKey("contours"))
    }
}

/// `[x, y]`: a glyph has hundreds of these, and the pair reads as a point.
extension OutlinePoint: Codable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        guard container.count == 2 else { throw decoder.invalid(nil, "a point is [x, y]") }
        x = try container.decode(Int.self)
        y = try container.decode(Int.self)
        try OutlinePoint.checkRange(x, y, decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
    }

    /// glyf stores 16-bit coordinates.
    static func checkRange(_ x: Int, _ y: Int, _ decoder: Decoder) throws {
        guard Int16(exactly: x) != nil, Int16(exactly: y) != nil else {
            throw decoder.invalid(nil, "(\(x), \(y)) is outside the 16-bit range glyf can store")
        }
    }
}

extension OutlineNode: Codable {
    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(["x", "y", "in", "out", "smooth"])
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        x = try container.decode(Int.self, forKey: AnyCodingKey("x"))
        y = try container.decode(Int.self, forKey: AnyCodingKey("y"))
        try OutlinePoint.checkRange(x, y, decoder)
        handleIn = try container.decodeIfPresent(OutlinePoint.self, forKey: AnyCodingKey("in"))
        handleOut = try container.decodeIfPresent(OutlinePoint.self, forKey: AnyCodingKey("out"))
        smooth = try container.decodeIfPresent(Bool.self, forKey: AnyCodingKey("smooth")) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(x, forKey: AnyCodingKey("x"))
        try container.encode(y, forKey: AnyCodingKey("y"))
        // Left out when absent or off, so a corner of two lines is {"x":…,"y":…}
        // and the canonical encoding has one spelling for each node.
        try container.encodeIfPresent(handleIn, forKey: AnyCodingKey("in"))
        try container.encodeIfPresent(handleOut, forKey: AnyCodingKey("out"))
        if smooth { try container.encode(true, forKey: AnyCodingKey("smooth")) }
    }
}
