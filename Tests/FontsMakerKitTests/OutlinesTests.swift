import CoreText
import Foundation
import Testing

@testable import FontsMakerKit

/// The outlines step and the editable cubic outlines behind it (Phase 4f,
/// technical design §5.8), on Crimson Text (composite é with USE_MY_METRICS
/// on its e), 原俠正楷 (the 61-point brush-drawn a) and ops.ttf (vmtx).
struct OutlinesTests {
    private static let crimson = "CrimsonText-Regular.ttf"
    private let output = #"{"familyName": "Edited Serif"}"#

    /// A box drawn as a person would with the pen: four corners, outer
    /// contour clockwise (y up), as TrueType fills it.
    private func box(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> [OutlineNode] {
        [OutlineNode(x: x0, y: y0), OutlineNode(x: x0, y: y1), OutlineNode(x: x1, y: y1), OutlineNode(x: x1, y: y0)]
    }

    private func build(_ steps: [Recipe.Step], source: String = OutlinesTests.crimson) throws -> (BuildResult, Font) {
        let bytes = try ReferenceFonts.bytes(source)
        let recipe = try Recipe(
            json: Recipe(
                source: Recipe.Source(file: source, sha256: sha256Hex(bytes)),
                output: Recipe.Output(familyName: "Edited Serif"), steps: steps
            ).canonicalJSON())
        let result = try RecipeBuilder.build(recipe, sourceData: Data(bytes), options: BuildOptions())
        return (result, try Font(data: result.fontData))
    }

    private func glyphID(_ font: Font, _ character: Character) -> Int {
        Int(font.characterMap.mappings[character.unicodeScalars.first!.value]!)
    }

    // MARK: Recipe

    /// The step is written whole and strictly: unknown keys, a key that is
    /// not one character, an empty step and the step anywhere but first are
    /// refused; a node without handles is just {"x","y"}, so the canonical
    /// bytes (and the hash in name ID 5) have one spelling per glyph.
    @Test func recipeFormat() throws {
        let glyph =
            #"{"advance": 600, "contours": [[{"x": 10, "y": 0}, {"x": 10, "y": 500, "out": [60, 560], "smooth": false}, {"x": 300, "y": 500, "in": [250, 560], "smooth": true}]]}"#
        func recipe(_ steps: String) throws -> Recipe {
            try Recipe(
                json: recipeJSON(
                    sourceFile: "a.ttf", sha256: String(repeating: "0", count: 64), output: output, steps: steps))
        }
        let decoded = try recipe(#"[{"op": "outlines", "glyphs": {"a": \#(glyph)}}, {"op": "embolden", "weight": 12}]"#)
        guard case .outlines(let step) = decoded.steps.first else {
            Issue.record("first step is \(decoded.steps.first?.op ?? "none")")
            return
        }
        #expect(
            step.glyphs["a"]?.contours[0][2]
                == OutlineNode(x: 300, y: 500, handleIn: OutlinePoint(x: 250, y: 560), smooth: true))
        let canonical = String(decoding: try decoded.canonicalJSON(), as: UTF8.self)
        #expect(
            canonical.contains(
                #"{"glyphs":{"a":{"advance":600,"contours":[[{"x":10,"y":0},{"out":[60,560],"x":10,"y":500},{"in":[250,560],"smooth":true,"x":300,"y":500}]]}},"op":"outlines"}"#
            ), "\(canonical)")
        #expect(try Recipe(json: decoded.canonicalJSON()) == decoded)

        func refused(_ steps: String, _ path: String) {
            let error = #expect(throws: RecipeError.self) { try recipe(steps) }
            #expect(error?.description.contains(path) == true, "\(error?.description ?? "no error")")
        }
        refused(#"[{"op": "embolden", "weight": 12}, {"op": "outlines", "glyphs": {"a": \#(glyph)}}]"#, "steps[1].op")
        refused(#"[{"op": "outlines", "glyphs": {"ab": \#(glyph)}}]"#, "steps[0].glyphs.ab")
        refused(#"[{"op": "outlines", "glyphs": {}}]"#, "steps[0].glyphs")
        refused(#"[{"op": "outlines", "glyphs": {"a": {"advance": 600, "contours": [], "lsb": 3}}}]"#, "glyphs.a.lsb")
        refused(
            #"[{"op": "outlines", "glyphs": {"a": {"advance": 600, "contours": [[{"x": 1, "y": 2, "type": "curve"}, {"x": 3, "y": 4}]]}}}]"#,
            "type")
        refused(#"[{"op": "outlines", "glyphs": {"a": {"advance": 70000, "contours": []}}}]"#, "glyphs.a.advance")
        refused(
            #"[{"op": "outlines", "glyphs": {"a": {"advance": 600, "contours": [[{"x": 40000, "y": 0}, {"x": 3, "y": 4}]]}}}]"#,
            "contours[0][0]")
        refused(
            #"[{"op": "outlines", "glyphs": {"a": {"advance": 600, "contours": [[{"x": 1, "y": 0}]]}}}]"#, "contours[0]"
        )

        // A recipe put together in code is held to the same order.
        let bytes = try ReferenceFonts.bytes(OutlinesTests.crimson)
        let misplaced = Recipe(
            source: Recipe.Source(file: "a.ttf", sha256: sha256Hex(bytes)), output: Recipe.Output(familyName: "Edited"),
            steps: decoded.steps.reversed())
        #expect(throws: RecipeError.self) {
            try RecipeBuilder.build(misplaced, sourceData: Data(bytes), options: BuildOptions())
        }
    }

    // MARK: Building

    /// The point of applying the step before composites are flattened: é is
    /// e plus an accent, so redrawing e redraws é, and é, which takes its
    /// metrics from e (USE_MY_METRICS), gets e's new advance too. A build
    /// that replaced e afterwards would leave the old e inside é.
    @Test func composedLettersFollowTheRedrawnGlyph() throws {
        let source = try Font(bytes: try ReferenceFonts.bytes(OutlinesTests.crimson))
        let e = glyphID(source, "e")
        let eAcute = glyphID(source, "é")
        guard case .composite(let components) = source.glyphs[eAcute].outline,
            case .offset(let dx, let dy) = components[0].placement
        else {
            Issue.record("fixture: é is a composite starting with e")
            return
        }
        #expect(Int(components[0].glyphID) == e && components[0].flags & GlyphComponent.useMyMetrics != 0)

        let square = EditedGlyph(advance: 640, contours: [box(60, 0, 420, 440)])
        let (result, built) = try build([.outlines(OutlinesStep(glyphs: ["e": square]))])
        #expect(result.reports.first?.summary.contains("1 glyphs redrawn (e)") == true)
        guard case .outlines(_, let report) = result.reports.first else { return }
        #expect(report.composites >= 2 && report.advances >= 2, "\(report)")

        let newE = try built.flattenedOutline(of: e).rounded()
        #expect(BoundingBox(newE.points) == BoundingBox(xMin: 60, yMin: 0, xMax: 420, yMax: 440))
        let eInside = try built.flattenedOutline(of: eAcute).rounded()
        let expected = newE.points.map { GlyphPoint(x: $0.x + dx, y: $0.y + dy, onCurve: $0.onCurve) }
        #expect(expected.allSatisfy { eInside.points.contains($0) }, "é is drawn with the new e")
        #expect(eInside.endPoints.count == newE.endPoints.count + 1, "the new e and the accent")
        #expect(built.horizontalMetrics[e].advanceWidth == 640)
        #expect(built.horizontalMetrics[eAcute].advanceWidth == 640, "USE_MY_METRICS follows e's advance")
        let o = glyphID(source, "o")
        #expect(built.horizontalMetrics[o] == source.horizontalMetrics[o], "other glyphs keep theirs")
        #expect(built.os2?.xAvgCharWidth != source.os2?.xAvgCharWidth, "advances changed, so xAvgCharWidth did")
        #expect(table("fpgm", in: [UInt8](result.fontData)) == nil, "outlines changed, hinting removed (D5)")
    }

    /// The later steps work on what was drawn: embolden thickens the
    /// redrawn e (a box grows by half the weight on every side, miter
    /// corners), not the source's e.
    @Test func emboldenThickensTheRedrawnGlyph() throws {
        let square = EditedGlyph(advance: 640, contours: [box(60, 0, 420, 440)])
        let (_, built) = try build([
            .outlines(OutlinesStep(glyphs: ["e": square])), .embolden(EmboldenStep(weight: 20)),
        ])
        let e = glyphID(built, "e")
        let outline = try built.flattenedOutline(of: e).rounded()
        #expect(BoundingBox(outline.points) == BoundingBox(xMin: 50, yMin: -10, xMax: 430, yMax: 450))
        #expect(outline.points.count == 4, "a thickened box is still a box")
    }

    /// The live preview draws what the build writes, for the redrawn glyph,
    /// a composite using it, and an untouched one; on top of embolden.
    @Test func previewMatchesTheBuild() throws {
        let source = try Font(bytes: try ReferenceFonts.bytes(OutlinesTests.crimson))
        let (edited, _) = try #require(try source.editableGlyph(for: 0x65))
        var moved = edited
        moved.translate(dx: 0, dy: 40)
        moved.advance += 30
        let steps: [Recipe.Step] = [
            .outlines(OutlinesStep(glyphs: ["e": moved])), .embolden(EmboldenStep(weight: 16, widen: true)),
        ]
        let (_, built) = try build(steps)
        let preview = try source.preview(of: "eéo".unicodeScalars.map(\.value), steps: steps)
        for character in "eéo" {
            let glyph = try #require(preview.glyphs[character.unicodeScalars.first!.value])
            let id = glyphID(built, character)
            #expect(glyph.outline.points == (try built.flattenedOutline(of: id).rounded().points), "\(character)")
            #expect(glyph.advanceWidth == Int(built.horizontalMetrics[id].advanceWidth), "\(character)")
        }
    }

    /// The output is an ordinary font: CoreText loads it and draws the
    /// redrawn glyph with the ink and advance the recipe gave it.
    @Test func coreTextDrawsTheRedrawnGlyph() throws {
        let square = EditedGlyph(advance: 640, contours: [box(60, 0, 420, 440)])
        let (result, _) = try build([.outlines(OutlinesStep(glyphs: ["e": square]))])
        let font = try coreTextFont(result.fontData, size: 1024)
        var units = Array("e".utf16)
        var glyph = CGGlyph(0)
        #expect(CTFontGetGlyphsForCharacters(font, &units, &glyph, 1))
        let path = try #require(CTFontCreatePathForGlyph(font, glyph, nil))
        #expect(path.boundingBoxOfPath == CGRect(x: 60, y: 0, width: 360, height: 440))
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        #expect(advance.width == 640)
    }

    /// Composites in the source keep working (回 is 口 twice), unmapped
    /// characters and two characters drawing one glyph two ways are refused,
    /// and the vertical origin stays where it was: a glyph drawn 50 units
    /// higher hangs 50 units less below the top in vmtx.
    @Test func glyphIdentityAndVerticalMetrics() throws {
        var font = try Fixtures.font("ops.ttf")
        let a = glyphID(font, "A")
        let mouth = glyphID(font, "口")
        let before = try #require(BoundingBox(try font.flattenedOutline(of: a).rounded().points))
        let tsb = try #require(font.verticalMetrics?[a].topSideBearing)
        let (edited, _) = try #require(try font.editableGlyph(for: 0x41))
        var raised = edited
        raised.translate(dx: 0, dy: 50)
        let report = try font.applyOutlines(
            OutlinesStep(glyphs: ["A": raised, "口": EditedGlyph(advance: 1000, contours: [box(100, 0, 900, 800)])]))
        #expect(report.characters == ["A", "口"] && report.composites == 1)
        let after = try #require(BoundingBox(try font.flattenedOutline(of: a).rounded().points))
        #expect(after.yMax == before.yMax + 50)
        #expect(font.verticalMetrics?[a].topSideBearing == tsb - 50)
        guard case .composite(let components) = font.glyphs[glyphID(font, "回")].outline else {
            Issue.record("回 is no longer a composite")
            return
        }
        #expect(components.allSatisfy { Int($0.glyphID) == mouth }, "回 still uses 口, now the redrawn one")

        var again = try Fixtures.font("ops.ttf")
        #expect(throws: OutlinesError.charactersNotInFont(["z"])) {
            try again.applyOutlines(OutlinesStep(glyphs: ["z": raised]))
        }
        // U+00B7 and U+30FB share periodcentered in this font.
        #expect(throws: OutlinesError.self) {
            try again.applyOutlines(
                OutlinesStep(glyphs: [
                    "·": EditedGlyph(advance: 300, contours: [box(0, 0, 100, 100)]),
                    "・": EditedGlyph(advance: 300, contours: [box(0, 0, 200, 200)]),
                ]))
        }
    }

    // MARK: Editable outlines

    /// Elevation is exact: every quadratic of the source becomes the cubic
    /// that traces the same points, so unsimplified, nothing moves.
    @Test func elevationTracesTheSameCurve() throws {
        let font = try Font(bytes: try ReferenceFonts.bytes(OutlinesTests.crimson))
        for character in "aegO0&" {
            let outline = try font.flattenedOutline(of: glyphID(font, character)).rounded()
            let quadratic = BezierContour.contours(of: outline.cgPath)
            for (index, range) in outline.contourRanges.enumerated() {
                let nodes = CubicOutline.elevated(outline.points[range])
                let cubic = BezierContour(segments: nodes.indices.map { CubicOutline.segment(nodes, $0) })
                let original = quadratic[index]
                #expect(cubic.segments.count == original.segments.count, "\(character): one node per on-curve point")
                // The two may start at different nodes of the same loop.
                let offset = try #require(
                    cubic.segments.indices.first { (cubic.start(of: $0) - original.start(of: 0)).length < 1e-9 })
                for q in original.segments.indices {
                    let c = (q + offset) % cubic.segments.count
                    for step in 0...8 {
                        let t = Double(step) / 8
                        let a = CubicOutline.point(on: original.segments[q], from: original.start(of: q), at: t)
                        let b = CubicOutline.point(on: cubic.segments[c], from: cubic.start(of: c), at: t)
                        #expect((a - b).length < 1e-9, "\(character) contour \(index) segment \(q)")
                    }
                }
            }
        }
    }

    /// 原俠正楷's a is 61 TrueType points; simplified, it is 22 nodes (R,
    /// with its corners, 82 → 30): at most half, within the tolerance of the source curve, and after a
    /// build converts it back (cu2qu, rounding) it lands within 2.5 units:
    /// the bound technical design §5.8 promises for the parts not edited.
    @Test func simplificationKeepsTheShapeWithFewerNodes() throws {
        let font = try Font(bytes: try ReferenceFonts.bytes("GuanKiapTsingKhai.ttf"))
        let tolerance = EditedGlyph.defaultTolerance(unitsPerEm: Int(font.unitsPerEm))
        #expect(tolerance == 1)
        for character in "a0eR" {
            let id = glyphID(font, character)
            let source = try font.flattenedOutline(of: id).rounded()
            let exact = try #require(try font.editableGlyph(for: character.unicodeScalars.first!.value, tolerance: 0))
            let (glyph, error) = try #require(try font.editableGlyph(for: character.unicodeScalars.first!.value))
            #expect(error <= tolerance, "\(character)")
            #expect(
                glyph.nodeCount * 2 <= source.points.count,
                "\(character): \(source.points.count) points → \(glyph.nodeCount) nodes")
            #expect(glyph.nodeCount < exact.glyph.nodeCount)
            var built = font
            _ = try built.applyOutlines(OutlinesStep(glyphs: [String(character): glyph]))
            guard case .simple(let result) = built.glyphs[id].outline else { continue }
            let distance = source.maxDistance(to: result)
            #expect(distance <= 2.5, "\(character): \(distance) units from the source after a build")
        }
        // Corners stay corners: the a's stem foot is not rounded off.
        let (a, _) = try #require(try font.editableGlyph(for: 0x61))
        #expect(a.contours.joined().contains { !$0.smooth })
    }

    /// Editing keeps what it does not mean to change: a node added on a
    /// curve leaves the curve where it was; removing it refits the two
    /// segments, so the shape comes back within a unit.
    @Test func addingAndRemovingNodesKeepsTheCurve() throws {
        let font = try Font(bytes: try ReferenceFonts.bytes(OutlinesTests.crimson))
        let (o, _) = try #require(try font.editableGlyph(for: 0x6F))
        let before = try o.trueTypeOutline(overlapping: false)
        var edited = o
        let segment = try #require(
            o.contours[0].indices.first { o.contours[0][($0 + 1) % o.contours[0].count].handleIn != nil })
        let index = edited.insertNode(contour: 0, segment: segment, t: 0.4)
        #expect(edited.nodeCount == o.nodeCount + 1 && edited.contours[0][index].smooth)
        #expect(before.maxDistance(to: try edited.trueTypeOutline(overlapping: false)) < 1.5)
        edited.removeNode(contour: 0, index: index)
        #expect(edited.nodeCount == o.nodeCount)
        #expect(before.maxDistance(to: try edited.trueTypeOutline(overlapping: false)) < 1.5)

        // A corner made smooth gets handles in line; made a corner again, none.
        var corner = EditedGlyph(advance: 600, contours: [box(0, 0, 400, 400)])
        corner.setSmooth(true, contour: 0, index: 1)
        let node = corner.contours[0][1]
        let inArm = try #require(node.handleIn)
        let outArm = try #require(node.handleOut)
        #expect((inArm.x - node.x) * (outArm.y - node.y) == (inArm.y - node.y) * (outArm.x - node.x), "collinear")
        corner.setSmooth(false, contour: 0, index: 1)
        #expect(corner.contours[0][1] == OutlineNode(x: 0, y: 400))
    }

    /// A contour drawn with the pen gets the direction nonzero filling
    /// needs: outside any other, clockwise; inside one, counter-clockwise,
    /// so it cuts a hole whichever way it was drawn.
    @Test func penContoursAreOrientedForTheFill() throws {
        func clockwise(_ contour: [OutlineNode]) -> Bool {
            contour.indices.reduce(0) { sum, i in
                let a = contour[i]
                let b = contour[(i + 1) % contour.count]
                return sum + (a.x * b.y - b.x * a.y)
            } < 0
        }
        let counterClockwise = Array(box(100, 100, 300, 300).reversed())
        var glyph = EditedGlyph(advance: 600, contours: [box(0, 0, 400, 400), box(100, 100, 300, 300)])
        glyph.orientForFill(contour: 1)
        #expect(!clockwise(glyph.contours[1]), "a counter inside the outer contour runs the other way")
        glyph.contours.append(
            counterClockwise.map {
                var n = $0
                n.x += 500
                return n
            })
        glyph.orientForFill(contour: 2)
        #expect(clockwise(glyph.contours[2]), "a new outer contour runs clockwise")
    }
}
