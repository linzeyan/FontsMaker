import Testing

@testable import FontsMakerKit

/// Composite semantics the synthetic fixture cannot carry, because fontTools'
/// pen-based tooling ignores them: Apple-style scaled offsets and point anchoring.
struct ComponentTests {
    private func points(_ glyph: Glyph) -> [GlyphPoint] {
        guard case .simple(let outline) = glyph.outline else { return [] }
        return outline.points
    }

    private func replacingGlyph(_ name: String, with components: [GlyphComponent]) throws -> (Font, Int) {
        var font = try Fixtures.font("synthetic.ttf")
        let glyphID = try Fixtures.expectation().glyphID(name)
        font.glyphs[glyphID] = Glyph(outline: .composite(components))
        return (font, glyphID)
    }

    @Test func scaledComponentOffsetScalesTheOffsetToo() throws {
        let expectation = try Fixtures.expectation()
        let a = UInt16(expectation.glyphID("A"))
        let half: Int16 = 8192  // 0.5 in F2Dot14
        let microsoft = GlyphComponent(glyphID: a, placement: .offset(x: 100, y: 40), transform: .scale(half))
        let apple = GlyphComponent(
            glyphID: a, placement: .offset(x: 100, y: 40), transform: .scale(half),
            flags: GlyphComponent.scaledComponentOffset)

        var (font, glyphID) = try replacingGlyph("A.spaced", with: [microsoft])
        let source = points(font.glyphs[Int(a)])
        try font.decomposeComposites()
        #expect(
            points(font.glyphs[glyphID]).map(\.x)
                == source.map { Int32((Double($0.x) * 0.5 + 100 + 0.5).rounded(.down)) })

        (font, glyphID) = try replacingGlyph("A.spaced", with: [apple])
        try font.decomposeComposites()
        #expect(
            points(font.glyphs[glyphID]).map(\.x)
                == source.map { Int32((Double($0.x + 100) * 0.5 + 0.5).rounded(.down)) })
        #expect(
            points(font.glyphs[glyphID]).map(\.y)
                == source.map { Int32((Double($0.y + 40) * 0.5 + 0.5).rounded(.down)) })
    }

    @Test func anchoredComponentLandsOnParentPoint() throws {
        let expectation = try Fixtures.expectation()
        let a = UInt16(expectation.glyphID("A"))
        let ring = UInt16(expectation.glyphID("ring"))
        // A's point 1 is (240, 700); ring's point 0 is (0, 100).
        let (original, glyphID) = try replacingGlyph(
            "A.spaced",
            with: [
                GlyphComponent(glyphID: a, placement: .offset(x: 0, y: 0)),
                GlyphComponent(glyphID: ring, placement: .anchor(parentPoint: 1, childPoint: 0)),
            ])
        var font = original
        try font.decomposeComposites()
        let ringPoints = points(font.glyphs[Int(ring)])
        let result = points(font.glyphs[glyphID])
        let aCount = points(font.glyphs[Int(a)]).count
        #expect(
            Array(result[aCount...]) == ringPoints.map { GlyphPoint(x: $0.x + 240, y: $0.y + 600, onCurve: $0.onCurve) }
        )

        // The anchor form survives a write/read cycle unflattened.
        let reread = try Font(bytes: try original.serialize(options: WriteOptions()))
        #expect(reread.glyphs[glyphID] == original.glyphs[glyphID])
    }

    @Test func referenceCycleIsReportedNotRecursedForever() throws {
        let expectation = try Fixtures.expectation()
        let glyphID = expectation.glyphID("Aring")
        var font = try Fixtures.font("synthetic.ttf")
        font.glyphs[glyphID] = Glyph(
            outline: .composite([GlyphComponent(glyphID: UInt16(glyphID), placement: .offset(x: 0, y: 0))]))
        #expect(throws: FontWriteError.self) { try font.decomposeComposites() }
        #expect(throws: FontWriteError.self) { try font.serialize(options: WriteOptions()) }
    }

    @Test func outOfRangeCoordinateIsAnErrorNotAWrap() throws {
        var font = try Fixtures.font("synthetic.ttf")
        let glyphID = try Fixtures.expectation().glyphID("A")
        guard case .simple(var outline) = font.glyphs[glyphID].outline else {
            Issue.record("A should be simple")
            return
        }
        outline.points[0].x = 40_000
        font.glyphs[glyphID].outline = .simple(outline)
        #expect(throws: FontWriteError.self) { try font.serialize(options: WriteOptions()) }
    }

    @Test func inconsistentContoursAreAnErrorNotACorruptGlyph() throws {
        var font = try Fixtures.font("synthetic.ttf")
        let glyphID = try Fixtures.expectation().glyphID("A")
        guard case .simple(var outline) = font.glyphs[glyphID].outline else {
            Issue.record("A should be simple")
            return
        }
        outline.points.removeLast()
        font.glyphs[glyphID].outline = .simple(outline)
        #expect(throws: FontWriteError.self) { try font.serialize(options: WriteOptions()) }
    }
}
