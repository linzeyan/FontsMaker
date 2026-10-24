import CoreText
import Foundation
import Testing

@testable import FontsMakerKit

/// Import normalization (plan Phase 4a): CFF outlines, variable fonts and
/// collections are read as the static TrueType font every operation edits.
/// The oracles are fontTools' own conversions, computed when the fixtures
/// were generated (scripts/make-test-fonts.py): the cu2qu pen for CFF and
/// varLib.instancer for variable fonts.
struct NormalizeTests {
    /// One point of a fontTools contour as stored in the JSON: [x, y, onCurve].
    struct ExpectedPoint: Decodable {
        let point: GlyphPoint

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            point = GlyphPoint(
                x: try container.decode(Int32.self), y: try container.decode(Int32.self),
                onCurve: try container.decode(Bool.self))
        }
    }

    struct CFFExpectation: Decodable {
        let glyphs: [[[ExpectedPoint]]]
        let advances: [UInt16]
        let verticalAdvances: [UInt16]
        /// The source's vertical origin (VORG), nil for an empty glyph.
        let verticalOrigins: [Double?]
        let cmap: [String: UInt16]
        let vert: [String: UInt16]
        let tables: [String]
    }

    struct VariableExpectation: Decodable {
        struct Axis: Decodable {
            let tag: String
            let minimum: Double
            let `default`: Double
            let maximum: Double
        }

        struct Instance: Decodable {
            let location: [String: Double]
            let glyphs: [[[ExpectedPoint]]]
            let advances: [UInt16]
            let weightClass: UInt16
            let xAvgCharWidth: Int16
        }

        let axes: [Axis]
        let tables: [String]
        let instances: [Instance]

        func instance(_ location: [String: Double]) -> Instance { instances.first { $0.location == location }! }
    }

    static func expectation<T: Decodable>(_ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: Fixtures.directory.appendingPathComponent(name)))
    }

    static let droppedTables: Set<String> = [
        "CFF ", "CFF2", "VORG", "fvar", "gvar", "avar", "cvar", "HVAR", "VVAR", "MVAR", "STAT", "DSIG",
    ]

    private func contours(_ glyph: Glyph) -> [[GlyphPoint]] {
        guard case .simple(let outline) = glyph.outline else { return [] }
        return outline.contourRanges.map { Array(outline.points[$0]) }
    }

    /// Same contours, each possibly starting at another point and listed in
    /// another order: CoreText chooses where a contour starts and in which
    /// order it hands contours over, and neither changes the glyph.
    private func sameGlyph(_ ours: [[GlyphPoint]], _ expected: [[ExpectedPoint]]) -> Bool {
        var remaining = expected.map { $0.map(\.point) }
        guard ours.count == remaining.count else { return false }
        for contour in ours {
            guard
                let match = remaining.firstIndex(where: { other in
                    other.count == contour.count
                        && (other.isEmpty
                            || contour.indices.contains { Array(contour[$0...] + contour[..<$0]) == other })
                })
            else { return false }
            remaining.remove(at: match)
        }
        return true
    }

    private func differingGlyphs(_ font: Font, _ expected: [[[ExpectedPoint]]]) -> [Int] {
        font.glyphs.indices.filter { !sameGlyph(contours(font.glyphs[$0]), expected[$0]) }
    }

    @Test func cffOutlinesConvertLikeFontTools() throws {
        let expected: CFFExpectation = try Self.expectation("cff-expected.json")
        let font = try Fixtures.font("cff.otf")

        #expect(font.glyphs.count == expected.glyphs.count)
        // Point order included, so this also pins the TrueType (clockwise) direction.
        #expect(differingGlyphs(font, expected.glyphs) == [], "points equal fontTools' cu2qu pen at 1 unit")
        #expect(font.horizontalMetrics.map(\.advanceWidth) == expected.advances)
        // Glyph IDs do not move, so cmap, vertical advances and GSUB carry over as they are.
        #expect(font.characterMap.mappings == Dictionary(uniqueKeysWithValues: expected.cmap.map { (UInt32($0)!, $1) }))
        let vertical = try #require(font.verticalMetrics)
        #expect(vertical.map(\.advanceHeight) == expected.verticalAdvances)
        // Vertical text places a glyph by tsb + yMax; without VORG that must
        // still be the source's origin, to rounding.
        let misplaced = font.glyphs.indices.filter { glyph in
            guard let origin = expected.verticalOrigins[glyph] else { return false }
            let top = contours(font.glyphs[glyph]).joined().map(\.y).max()!
            return abs(Double(Int32(vertical[glyph].topSideBearing) + top) - origin) > 0.5
        }
        #expect(misplaced == [])
        #expect(
            font.verticalSubstitutions == Dictionary(uniqueKeysWithValues: expected.vert.map { (UInt16($0)!, $1) }))

        let bytes = try font.serialize(options: WriteOptions())
        let tags = Set(tableRecords(bytes).map(\.tag))
        #expect(bytes.prefix(4) == [0, 1, 0, 0], "sfntVersion 0x00010000, not 'OTTO'")
        #expect(tags.isSuperset(of: ["glyf", "loca", "GSUB", "vhea", "vmtx", "post", "OS/2"]))
        #expect(tags.isDisjoint(with: Self.droppedTables), "no CFF or VORG left: \(tags.sorted())")
        let maxp = try #require(table("maxp", in: bytes))
        #expect(maxp.count == 32 && maxp.readU16(at: 0) == 1, "maxp 1.0 replaces the CFF font's 0.5")
        #expect(try Font(bytes: bytes).glyphs == font.glyphs)
    }

    /// A converted glyph whose top moved (an off-curve point above a CFF
    /// curve, or another instance's outline) keeps its vertical origin:
    /// the tsb takes up the difference. Empty glyphs keep theirs.
    @Test func topSideBearingKeepsTheVerticalOrigin() throws {
        var font = try Fixtures.font("synthetic.ttf")
        let before = try #require(font.verticalMetrics)
        let glyph = try #require(
            font.glyphs.indices.first { glyph in
                if case .simple(let outline) = font.glyphs[glyph].outline { return !outline.isEmpty }
                return false
            })
        let tops = try Font.glyfTops(font.tables, numGlyphs: font.glyphs.count)
        guard case .simple(var outline) = font.glyphs[glyph].outline else { return }
        outline.points = outline.points.map { GlyphPoint(x: $0.x, y: $0.y + 7, onCurve: $0.onCurve) }
        font.glyphs[glyph].outline = .simple(outline)

        font.keepVerticalOrigins(
            zip(tops, before).map { top, metric in top.map { $0 + Double(metric.topSideBearing) } })
        let after = try #require(font.verticalMetrics)
        #expect(after[glyph].topSideBearing == before[glyph].topSideBearing - 7)
        #expect(after[glyph].advanceHeight == before[glyph].advanceHeight)
        let others = after.indices.filter { $0 != glyph && after[$0] != before[$0] }
        #expect(others == [], "glyphs whose top did not move keep their tsb")
    }

    @Test(arguments: [
        ["wght": 400.0, "opsz": 12.0], ["wght": 700, "opsz": 12], ["wght": 400, "opsz": 72],
        ["wght": 650, "opsz": 30], ["wght": 250, "opsz": 12],
    ])
    func variableInstanceMatchesTheInstancer(location: [String: Double]) throws {
        let expected = try (Self.expectation("variable-expected.json") as VariableExpectation).instance(location)
        let font = try Font(bytes: try Fixtures.bytes("variable.ttf"), variation: location)

        #expect(differingGlyphs(font, expected.glyphs) == [])
        #expect(font.horizontalMetrics.map(\.advanceWidth) == expected.advances, "HVAR advances")
        // The style fields the instancer derives from the location.
        #expect(font.os2?.weightClass == expected.weightClass)
        #expect(font.os2?.xAvgCharWidth == expected.xAvgCharWidth)

        let bytes = try font.serialize(options: WriteOptions())
        let tags = Set(tableRecords(bytes).map(\.tag))
        #expect(tags.isDisjoint(with: Self.droppedTables), "no variation tables left: \(tags.sorted())")
        // Overlapping contours of a variable font need OVERLAP_SIMPLE on Apple's rasterizers.
        let flagged = font.glyphs.allSatisfy { glyph in
            guard case .simple(let outline) = glyph.outline else { return false }
            return outline.isEmpty || outline.overlapping
        }
        #expect(flagged)
    }

    /// CoreText sets opsz from the point size unless told otherwise, and
    /// outlines are read at 1000 pt: an axis left to CoreText comes out at
    /// opsz 72. Every axis the recipe leaves out must be its default.
    @Test func axesLeftOutTakeTheirDefaultNotCoreTextsChoice() throws {
        let oracle: VariableExpectation = try Self.expectation("variable-expected.json")
        let source = try Fixtures.bytes("variable.ttf")
        let regular = oracle.instance(["wght": 400, "opsz": 12])
        let display = oracle.instance(["wght": 400, "opsz": 72])

        #expect(differingGlyphs(try Font(bytes: source, variation: ["wght": 400]), regular.glyphs) == [])
        #expect(differingGlyphs(try Font(bytes: source), regular.glyphs) == [], "no variation: the default instance")

        // The trap this guards against, seen directly in CoreText: the "l"
        // stem is 80 units at opsz 12 and 60 at opsz 72.
        let descriptor = try #require(
            (CTFontManagerCreateFontDescriptorsFromData(Data(source) as CFData) as? [CTFontDescriptor])?.first)
        let wghtOnly = CTFontDescriptorCreateCopyWithAttributes(
            descriptor,
            [kCTFontVariationAttribute: [NSNumber(value: CoreTextOutlines.tagNumber("wght")): 400]] as CFDictionary)
        let path = try #require(CTFontCreatePathForGlyph(CTFontCreateWithFontDescriptor(wghtOnly, 1000, nil), 2, nil))
        let stem = { (glyph: [[ExpectedPoint]]) in
            let xs = glyph.flatMap { $0.map { CGFloat($0.point.x) } }
            return xs.max()! - xs.min()!
        }
        #expect(stem(regular.glyphs[2]) == 80 && stem(display.glyphs[2]) == 60)
        #expect(path.boundingBoxOfPath.width == 60, "CoreText picked opsz 72 by itself")
    }

    @Test func variationAndFaceIndexErrorsSayWhatIsWrong() throws {
        let variable = try Fixtures.bytes("variable.ttf")
        let unknown = #expect(throws: FontLoadError.self) { try Font(bytes: variable, variation: ["wdth": 100]) }
        #expect(unknown == .unknownAxis(tag: "wdth", available: ["wght", "opsz"]))
        #expect(unknown?.description.contains("'wght', 'opsz'") == true)

        let outside = #expect(throws: FontLoadError.self) { try Font(bytes: variable, variation: ["wght": 1000]) }
        #expect(outside == .axisValueOutOfRange(tag: "wght", value: 1000, minimum: 100, maximum: 900))
        #expect(outside?.description.contains("100–900") == true)

        for file in ["synthetic.ttf", "cff.otf"] {
            #expect(throws: FontLoadError.notVariable) {
                try Font(bytes: try Fixtures.bytes(file), variation: ["wght": 400])
            }
        }
        #expect(throws: FontLoadError.faceIndexOutOfRange(index: 1, faceCount: 1)) {
            try Font(bytes: try Fixtures.bytes("synthetic.ttf"), faceIndex: 1)
        }
        let beyond = #expect(throws: FontLoadError.self) {
            try Font(bytes: try Fixtures.bytes("collection.ttc"), faceIndex: 2)
        }
        #expect(beyond == .faceIndexOutOfRange(index: 2, faceCount: 2))
        #expect(beyond?.description.contains("0–1") == true)
    }

    @Test func collectionMembersAreReadByIndex() throws {
        let collection = try Fixtures.bytes("collection.ttc")
        let faces = try Font.faces(in: collection)
        #expect(faces.map(\.outlineFormat) == [.trueType, .cff])
        #expect(faces.map(\.index) == [0, 1] && faces[1].fullName == "FM CFF Regular")

        // A glyf member is read as it is, without CoreText: the same bytes
        // as the standalone font it was made from.
        let glyfMember = try Font(bytes: collection, faceIndex: 0)
        #expect(
            try glyfMember.serialize(options: WriteOptions())
                == Fixtures.font("minimal.ttf").serialize(options: WriteOptions()))
        #expect(try Font(bytes: collection).glyphs == glyfMember.glyphs, "faceIndex defaults to 0")

        let cffMember = try Font(bytes: collection, faceIndex: 1)
        let standalone = try Fixtures.font("cff.otf")
        #expect(cffMember.glyphs == standalone.glyphs && cffMember.characterMap == standalone.characterMap)
    }

    @Test func facesDescribeAxesWithoutConverting() throws {
        let expected: VariableExpectation = try Self.expectation("variable-expected.json")
        let faces = try Font.faces(in: try Fixtures.bytes("variable.ttf"))
        #expect(faces.count == 1 && faces[0].outlineFormat == .trueType)
        #expect(faces[0].axes.map(\.tag) == expected.axes.map(\.tag))
        #expect(
            faces[0].axes.map { [$0.minimum, $0.defaultValue, $0.maximum] }
                == expected.axes.map { [$0.minimum, $0.default, $0.maximum] })
        #expect(faces[0].axes.map(\.name) == ["Weight", "Optical size"])
        #expect(try Font.faces(in: try Fixtures.bytes("cff.otf")).map(\.outlineFormat) == [.cff])
        #expect(try Font.faces(in: try Fixtures.bytes("synthetic.ttf"))[0].axes.isEmpty)
    }

    /// Glyphs are converted in parallel; the bytes must not depend on it.
    @Test func conversionIsDeterministic() throws {
        let cff = try Fixtures.bytes("cff.otf")
        let variable = try Fixtures.bytes("variable.ttf")
        #expect(
            try Font(bytes: cff).serialize(options: WriteOptions())
                == Font(bytes: cff).serialize(options: WriteOptions()))
        let location = ["wght": 650.0, "opsz": 30.0]
        #expect(
            try Font(bytes: variable, variation: location).serialize(options: WriteOptions())
                == Font(bytes: variable, variation: location).serialize(options: WriteOptions()))
    }

    /// The recipe's source picks the instance; sha256 stays that of the file.
    @Test func recipeSourceSelectsTheInstance() throws {
        let bytes = try Fixtures.bytes("variable.ttf")
        func build(_ source: String) throws -> BuildResult {
            let json = """
                {"formatVersion": 1, "source": {"file": "variable.ttf", "sha256": "\(sha256Hex(bytes))"\(source)},
                 "output": {"familyName": "Derived Instance"}, "steps": []}
                """
            return try RecipeBuilder.build(
                try Recipe(json: Data(json.utf8)), sourceData: Data(bytes), options: BuildOptions())
        }
        let bold = try Font(data: try build(#", "variation": {"wght": 700}"#).fontData)
        let expected = try (Self.expectation("variable-expected.json") as VariableExpectation)
            .instance(["wght": 700, "opsz": 12])
        #expect(differingGlyphs(bold, expected.glyphs) == [])
        #expect(throws: FontLoadError.unknownAxis(tag: "wdht", available: ["wght", "opsz"])) {
            try build(#", "variation": {"wdht": 100}"#)
        }
        #expect(throws: FontLoadError.faceIndexOutOfRange(index: 3, faceCount: 1)) {
            try build(#", "faceIndex": 3"#)
        }
    }

    /// A converted font is an ordinary TrueType font to every operation.
    @Test func convertedSourceRunsTheOutlineSteps() throws {
        let bytes = try Fixtures.bytes("cff.otf")
        let json = recipeJSON(
            sourceFile: "cff.otf", sha256: sha256Hex(bytes), output: #"{"familyName": "Derived Bold"}"#,
            steps: #"[{"op": "embolden", "weight": 12}, {"op": "pseudoVertical"}]"#)
        let result = try RecipeBuilder.build(try Recipe(json: json), sourceData: Data(bytes), options: BuildOptions())
        let built = try Font(data: result.fontData)
        let source = try Font(bytes: bytes)
        func width(_ glyph: Glyph) throws -> Int32 {
            let box = try #require(BoundingBox(points(glyph)))
            return box.xMax - box.xMin
        }
        #expect(try width(built.glyphs[2]) > width(source.glyphs[2]), "A is emboldened")
        #expect(built.verticalSubstitutions == source.verticalSubstitutions)
        _ = try coreTextFont(result.fontData)
    }
}

/// cmap format 4 (technical design §4.3) uses fontTools' segmentation.
struct CmapFormat4Tests {
    struct Expectation: Decodable {
        let mapping: [String: UInt16]
        let format4: String
    }

    private func format4(_ font: [UInt8]) throws -> [UInt8] {
        let cmap = try #require(table("cmap", in: font))
        let offsets = (0..<Int(cmap.readU16(at: 2))).map { record in
            Int(UInt32(cmap.readU16(at: 8 + 8 * record)) << 16 | UInt32(cmap.readU16(at: 10 + 8 * record)))
        }
        let offset = try #require(offsets.first { cmap.readU16(at: $0) == 4 }, "a format 4 subtable")
        return Array(cmap[offset..<offset + Int(cmap.readU16(at: offset + 2))])
    }

    private func encoded(_ mappings: [UInt32: UInt16], glyphs: Int) throws -> [UInt8] {
        var font = try Fixtures.font("minimal.ttf")
        while font.glyphs.count < glyphs {
            _ = try font.appendGlyph(
                .empty, horizontal: HorizontalMetric(advanceWidth: 0, leftSideBearing: 0), vertical: nil)
        }
        font.characterMap.mappings = mappings
        return try font.serialize(options: WriteOptions())
    }

    @Test func segmentsAreFontToolsByteForByte() throws {
        let expected = try JSONDecoder().decode(
            Expectation.self, from: Data(contentsOf: Fixtures.directory.appendingPathComponent("cmap4-expected.json")))
        let mappings = Dictionary(uniqueKeysWithValues: expected.mapping.map { (UInt32($0)!, $1) })
        let output = try encoded(mappings, glyphs: Int(mappings.values.max()!) + 1)
        let fontTools = stride(from: 0, to: expected.format4.count, by: 2).map {
            let start = expected.format4.index(expected.format4.startIndex, offsetBy: $0)
            return UInt8(expected.format4[start..<expected.format4.index(start, offsetBy: 2)], radix: 16)!
        }
        #expect(try format4(output) == fontTools)
        #expect(try Font(bytes: output).characterMap.mappings == mappings)
    }

    /// 40,000 ideographs in glyph order except every 100th: one glyphIdArray
    /// slot each would need 80 KB, past the format's 64 KiB; as delta
    /// segments they take a few KB. Source Han derivatives look like this.
    @Test func largeBMPCoverageFitsFormat4() throws {
        var mappings: [UInt32: UInt16] = [:]
        for index in 0..<40_000 {
            let code = UInt32(0x4E00 + index)
            mappings[code] = UInt16(index % 100 == 99 ? 40_500 - index / 100 : 1 + index)
        }
        let output = try encoded(mappings, glyphs: 41_000)
        #expect(try format4(output).count < 20_000)
        #expect(try Font(bytes: output).characterMap.mappings == mappings)
    }
}
