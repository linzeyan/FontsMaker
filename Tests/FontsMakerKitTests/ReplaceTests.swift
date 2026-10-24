import CoreText
import Foundation
import Testing

@testable import FontsMakerKit

/// The replace step (technical design §5.7): a CJK font's Latin letters from
/// a Latin text face, or a few CJK characters from another CJK font.
struct ReplaceTests {
    static let target = "GuanKiapTsingKhai.ttf"
    static let latin = "Literata-VF.ttf"
    static let allLatin = #"["latinLetters", "digits", "asciiPunctuation", "latin1"]"#

    struct Built {
        let source: Font
        let replacement: Font
        /// The fonts of `also`, by placeholder.
        let others: [String: Font]
        let recipe: Recipe
        let result: BuildResult
        let output: Font

        var report: ReplaceReport {
            get throws {
                for case .replace(_, let report) in result.reports { return report }
                throw ReplaceError.charactersNotInReplacement([])
            }
        }
    }

    /// GuanKiapTsingKhai with `steps`, where `REPLACEMENT` stands for the
    /// replacement font's {file, sha256}, and each key of `also` for the
    /// {file, sha256} of the reference font it names.
    static func build(
        _ steps: String, replacement: String = latin, also: [String: String] = [:], family: String = "Example Mixed"
    ) throws -> Built {
        let sourceBytes = try ReferenceFonts.bytes(target)
        var steps = steps
        var data: [String: Data] = [:]
        var fonts: [String: Font] = [:]
        // Longest placeholder first, so none is cut short by another it starts with.
        for (placeholder, file) in (["REPLACEMENT": replacement].merging(also) { $1 }).sorted(by: {
            $0.key.count > $1.key.count
        }) {
            let bytes = try ReferenceFonts.bytes(file)
            let sha = sha256Hex(bytes)
            steps = steps.replacingOccurrences(of: placeholder, with: #"{"file": "\#(file)", "sha256": "\#(sha)"}"#)
            data[sha] = Data(bytes)
            fonts[placeholder] = try Font(bytes: bytes)
        }
        let recipe = try Recipe(
            json: recipeJSON(
                sourceFile: target, sha256: sha256Hex(sourceBytes), output: #"{"familyName": "\#(family)"}"#,
                steps: steps))
        let result = try RecipeBuilder.build(
            recipe, sourceData: Data(sourceBytes), replacementData: data, options: BuildOptions())
        return Built(
            source: try Font(bytes: sourceBytes), replacement: fonts["REPLACEMENT"]!,
            others: fonts.filter { $0.key != "REPLACEMENT" }, recipe: recipe, result: result,
            output: try Font(data: result.fontData))
    }

    static let latinByXHeight = Result {
        try build(#"[{"op": "replace", "font": REPLACEMENT, "sets": \#(allLatin), "match": "xHeight"}]"#)
    }

    private func box(_ font: Font, _ codePoint: UInt32) throws -> BoundingBox? {
        let glyph = try #require(font.characterMap.mappings[codePoint])
        return BoundingBox(try font.flattenedOutline(of: Int(glyph)).rounded().points)
    }

    /// Why the step exists: Latin in a CJK font set at the CJK font's own
    /// x-height, so the letters sit with the Chinese as the font's own did.
    @Test func latinLetterHeightMatchesTheTarget() throws {
        let built = try ReplaceTests.latinByXHeight.get()
        let target = try #require(built.source.outlineTop(of: 0x78))
        let replaced = try #require(built.output.outlineTop(of: 0x78))
        #expect(abs(replaced - target) / target <= 0.01, "x-height \(replaced), target \(target)")
        // Not trivially so: by the em ratio alone Literata's x (507) would be
        // 4.8 % taller than GuanKiapTsingKhai's (484).
        let byEm = try #require(built.replacement.outlineTop(of: 0x78)) * 1000 / Double(built.replacement.unitsPerEm)
        #expect(abs(byEm - target) / target > 0.01)
        let report = try built.report
        #expect(report.xHeight?.after == Int(replaced))
        #expect(report.replaced > 180, "ASCII and Latin-1, \(report.replaced)")
    }

    /// Each letter is the replacement's, scaled about the origin: bounds,
    /// advance and so both side bearings scale together, so the letters keep
    /// the replacement font's spacing.
    @Test func replacedLettersAreTheReplacementsScaled() throws {
        let built = try ReplaceTests.latinByXHeight.get()
        let scale = try built.report.scale
        var checked = 0
        for codePoint in try built.recipe.replaceSteps[0].codePoints {
            guard let donorGlyph = built.replacement.characterMap.mappings[codePoint] else { continue }
            let glyph = try #require(built.output.characterMap.mappings[codePoint])
            #expect(Int(glyph) >= built.source.glyphs.count, "a new glyph, not the target's own")
            let advance = Double(built.replacement.horizontalMetrics[Int(donorGlyph)].advanceWidth) * scale
            #expect(abs(Double(built.output.horizontalMetrics[Int(glyph)].advanceWidth) - advance) <= 0.5)
            let expected = BoundingBox(try built.replacement.flattenedOutline(of: Int(donorGlyph)).rounded().points)
            let actual = try box(built.output, codePoint)
            #expect((expected == nil) == (actual == nil))
            if let expected, let actual {
                let scaled = [expected.xMin, expected.yMin, expected.xMax, expected.yMax].map { Double($0) * scale }
                let got = [actual.xMin, actual.yMin, actual.xMax, actual.yMax].map(Double.init)
                #expect(zip(scaled, got).allSatisfy { abs($0 - $1) <= 1 }, "U+\(hex(codePoint))")
            }
            checked += 1
        }
        #expect(checked == (try built.report.replaced))
    }

    /// Only the code points asked for change: every other one keeps its
    /// outline and advance, so the Chinese is untouched.
    @Test func everythingElseKeepsItsGlyph() throws {
        let built = try ReplaceTests.latinByXHeight.get()
        let replaced = Set(try built.recipe.replaceSteps[0].codePoints)
        var compared = 0
        for (codePoint, glyph) in built.source.characterMap.mappings.sorted(by: { $0.key < $1.key })
        where !replaced.contains(codePoint) && codePoint % 7 == 0 {
            let output = try #require(built.output.characterMap.mappings[codePoint])
            #expect(output == glyph, "U+\(hex(codePoint)) keeps its glyph ID")
            #expect(
                try built.output.flattenedOutline(of: Int(output)).rounded()
                    == built.source.flattenedOutline(of: Int(glyph)).rounded())
            #expect(built.output.horizontalMetrics[Int(output)] .advanceWidth == built.source.horizontalMetrics[Int(glyph)].advanceWidth)
            compared += 1
        }
        #expect(compared > 3000)
    }

    /// CoreText sets mixed text from the built font alone, and the Latin
    /// comes out as the new glyphs.
    @Test func mixedTextLaysOutWithoutFallback() throws {
        let built = try ReplaceTests.latinByXHeight.get()
        let text = "中英混排 Mixed text, 123 «déjà vu»。"
        let font = try coreTextFont(built.result.fontData)
        let attributed = NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font])
        var glyphs: [CGGlyph] = []
        for run in CTLineGetGlyphRuns(CTLineCreateWithAttributedString(attributed)) as? [CTRun] ?? [] {
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String]
            #expect(CTFontCopyPostScriptName(runFont as! CTFont) as String == "ExampleMixed-Regular", "no fallback")
            var runGlyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &runGlyphs)
            glyphs += runGlyphs
        }
        #expect(glyphs == text.unicodeScalars.map { built.output.characterMap.mappings[$0.value]! })
    }

    /// OFL condition 2: the output carries both fonts' copyright notices and
    /// license text, and the replacement's names bind the new name as the
    /// source's do.
    @Test func noticesAndNamesOfBothFonts() throws {
        let built = try ReplaceTests.latinByXHeight.get()
        func text(_ font: Font, _ id: UInt16) -> String {
            font.names.first { $0.nameID == id && $0.platformID == 3 && $0.languageID == 0x0409 }?.string ?? ""
        }
        let copyright = text(built.output, 0)
        #expect(copyright.contains(text(built.source, 0)) && copyright.contains(text(built.replacement, 0)))
        #expect(copyright.hasSuffix("; Modified with FontsMaker"))
        let license = text(built.output, 13)
        #expect(license.contains(text(built.source, 13)) && license.contains(text(built.replacement, 13)))

        #expect(throws: RenameError.self) {
            try ReplaceTests.build(
                #"[{"op": "replace", "font": REPLACEMENT, "sets": ["latinLetters"]}]"#, family: "Literata Kai")
        }
    }

    /// The size and baseline controls on top of the match.
    @Test func sizeAndBaselineShift() throws {
        let built = try ReplaceTests.build(
            #"[{"op": "replace", "font": REPLACEMENT, "sets": ["latinLetters"], "match": "xHeight", "size": 1.1, "#
                + #""baselineShift": -20}]"#)
        let target = try #require(built.source.outlineTop(of: 0x78))
        let top = try #require(built.output.outlineTop(of: 0x78))
        #expect(abs(top - (target * 1.1 - 20)) <= 1)
        let baseline = try #require(try box(built.output, 0x78)).yMin
        #expect(abs(Double(baseline) + 20) <= 1, "x sits on the baseline, moved down 20")
    }

    /// 白鷺楷's way with 傳 and 導: the glyph of another CJK font, as it is
    /// (same em, scale 1), while every other character stays.
    @Test func cjkCharactersFromAnotherFont() throws {
        let built = try ReplaceTests.build(
            #"[{"op": "replace", "font": REPLACEMENT, "characters": ["導", "傳"]}]"#,
            replacement: "LXGWWenKaiTC-Medium.ttf")
        #expect(try built.report.scale == 1)
        for character in "傳導".unicodeScalars {
            let donor = try #require(built.replacement.characterMap.mappings[character.value])
            let glyph = try #require(built.output.characterMap.mappings[character.value])
            #expect(
                try built.output.flattenedOutline(of: Int(glyph)).rounded()
                    == built.replacement.flattenedOutline(of: Int(donor)).rounded())
        }
        #expect(built.output.characterMap.mappings[0x50B3] != built.source.characterMap.mappings[0x50B3])
        #expect(built.output.glyphs.count == built.source.glyphs.count + 2)
    }

    /// The preview runs the step on subsets of both fonts; what it draws must
    /// be what the build writes, with a redrawn glyph before the replacement
    /// and embolden after it too, the order the app writes them in.
    @Test func previewMatchesTheBuild() throws {
        let redrawn = #"{"op": "outlines", "glyphs": {"中": {"advance": 1000, "contours": "#
            + #"[[{"x": 100, "y": 0}, {"x": 900, "y": 0}, {"x": 500, "y": 800}]]}}}"#
        let steps = #"[\#(redrawn), {"op": "replace", "font": REPLACEMENT, "sets": \#(ReplaceTests.allLatin), "#
            + #""match": "xHeight", "size": 1.05}, {"op": "embolden", "weight": 12}]"#
        let built = try ReplaceTests.build(steps)
        let middle = try #require(built.output.characterMap.mappings[0x4E2D])
        guard case .simple(let triangle) = built.output.glyphs[Int(middle)].outline else {
            Issue.record("built glyphs are flattened")
            return
        }
        #expect(triangle.endPoints.count == 1, "中 is the one contour drawn, emboldened")
        let text = Set("Agé中文".unicodeScalars.map(\.value))
        let replacement = try Font(bytes: try ReferenceFonts.bytes(ReplaceTests.latin))
        let preview = try built.source.preview(
            of: text, steps: built.recipe.steps, replacements: [built.recipe.replaceSteps[0].font.sha256: replacement])
        try ReplaceTests.expect(preview, of: text, equals: built.output)
        #expect(throws: PreviewError.replacementFontMissing(file: ReplaceTests.latin)) {
            try built.source.preview(of: text, steps: built.recipe.steps)
        }
    }

    /// Every character of `text` shows in `preview` the outline and advance it has in `output`.
    static func expect(_ preview: GlyphPreview, of text: Set<UInt32>, equals output: Font) throws {
        for codePoint in text {
            let shown = try #require(preview.glyphs[codePoint])
            let glyph = try #require(output.characterMap.mappings[codePoint])
            guard case .simple(let outline) = output.glyphs[Int(glyph)].outline else {
                Issue.record("built glyphs are flattened")
                continue
            }
            #expect(shown.outline.points == outline.points, "U+\(hex(codePoint))")
            #expect(shown.advanceWidth == Int(output.horizontalMetrics[Int(glyph)].advanceWidth))
        }
    }

    // MARK: Several replace steps

    static let cjk = "LXGWWenKaiTC-Medium.ttf"

    /// The app's recipe once risk review borrowed glyphs (design §5.7): the
    /// Latin letters from Literata before embolden, 傳導育 from 霞鶩文楷
    /// after it, each step with its own font.
    static let latinAndCJK = Result {
        try build(
            #"[{"op": "replace", "font": REPLACEMENT, "sets": \#(allLatin), "match": "xHeight"}, "#
                + #"{"op": "embolden", "weight": 12}, {"op": "replace", "font": CJK, "characters": ["傳", "導", "育"]}]"#,
            also: ["CJK": cjk])
    }

    /// Why a recipe needs two replace steps: a CJK font whose Latin comes
    /// from a Latin face, and whose crowded 傳導育 come from another CJK font.
    /// Each step takes from its own font. The borrowed hanzi come after
    /// embolden, so they are 霞鶩文楷 Medium as drawn (白鷺楷 took them at
    /// that font's own weight), while the Latin letters are emboldened with
    /// the rest of the text.
    @Test func twoReplaceStepsEachTakeFromTheirOwnFont() throws {
        let built = try ReplaceTests.latinAndCJK.get()
        let lxgw = try #require(built.others["CJK"])
        for character in "傳導育".unicodeScalars {
            let donor = try #require(lxgw.characterMap.mappings[character.value])
            let glyph = try #require(built.output.characterMap.mappings[character.value])
            #expect(
                try built.output.flattenedOutline(of: Int(glyph)).rounded()
                    == lxgw.flattenedOutline(of: Int(donor)).rounded(), "\(character) is 霞鶩文楷's, not emboldened")
        }
        let reports = built.result.reports.compactMap { if case .replace(_, let report) = $0 { report } else { nil } }
        #expect(reports.map(\.familyName) == [built.replacement.familyName, lxgw.familyName])
        #expect(reports.map(\.replaced) == [reports[0].replaced, 3])
        // Literata's x, matched to the target's x-height, then emboldened:
        // 12 units taller than the match, 6 above and 6 below.
        let target = try #require(built.source.outlineTop(of: 0x78))
        let x = try #require(built.output.outlineTop(of: 0x78))
        #expect((target + 3...target + 10).contains(x), "x top \(x), target x-height \(target)")
        #expect(built.output.glyphs.count == built.source.glyphs.count + reports[0].glyphs + 3)
        // Both second fonts' notices, OFL condition 2.
        let copyright =
            built.output.names.first { $0.nameID == 0 && $0.platformID == 3 && $0.languageID == 0x0409 }?.string ?? ""
        for font in [built.replacement, lxgw] {
            let notice = font.names.first { $0.nameID == 0 && $0.platformID == 3 && $0.languageID == 0x0409 }?.string
            #expect(copyright.contains(try #require(notice)))
        }
    }

    /// The preview takes each step's font by the sha256 the step names, and
    /// draws what the build writes for both steps' characters.
    @Test func previewMatchesTheBuildWithTwoSecondFonts() throws {
        let built = try ReplaceTests.latinAndCJK.get()
        let text = Set("Ax傳導中文".unicodeScalars.map(\.value))
        let steps = built.recipe.replaceSteps
        let fonts = [steps[0].font.sha256: built.replacement, steps[1].font.sha256: try #require(built.others["CJK"])]
        let preview = try built.source.preview(of: text, steps: built.recipe.steps, replacements: fonts)
        try ReplaceTests.expect(preview, of: text, equals: built.output)
        #expect(throws: PreviewError.replacementFontMissing(file: ReplaceTests.cjk)) {
            try built.source.preview(
                of: text, steps: built.recipe.steps, replacements: [steps[0].font.sha256: built.replacement])
        }
    }

    /// The CLI reads every second font beside the recipe, by the file name
    /// its step gives, and builds what the app's in-memory build does.
    @Test func cliPathReadsEverySecondFontBesideTheRecipe() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var data: [String: Data] = [:]
        var reference: [String: String] = [:]
        for name in [ReplaceTests.target, ReplaceTests.latin, ReplaceTests.cjk] {
            let bytes = Data(try ReferenceFonts.bytes(name))
            try bytes.write(to: directory.appendingPathComponent(name))
            data[name] = bytes
            reference[name] = #"{"file": "\#(name)", "sha256": "\#(sha256Hex(bytes))"}"#
        }
        let recipe = try Recipe(
            json: recipeJSON(
                sourceFile: ReplaceTests.target, sha256: sha256Hex(data[ReplaceTests.target]!),
                output: #"{"familyName": "Example Mixed"}"#,
                steps: #"[{"op": "replace", "font": \#(reference[ReplaceTests.latin]!), "sets": ["latinLetters"], "#
                    + #""match": "xHeight"}, {"op": "replace", "font": \#(reference[ReplaceTests.cjk]!), "#
                    + #""characters": ["傳", "導"]}]"#))
        let url = directory.appendingPathComponent("recipe.json")
        try recipe.canonicalJSON().write(to: url)
        let fromFiles = try RecipeBuilder.build(recipeAt: url, options: BuildOptions())
        let inMemory = try RecipeBuilder.build(
            recipe, sourceData: data[ReplaceTests.target]!,
            replacementData: Dictionary(
                uniqueKeysWithValues: [ReplaceTests.latin, ReplaceTests.cjk].map { (sha256Hex(data[$0]!), data[$0]!) }),
            options: BuildOptions())
        #expect(fromFiles.fontData == inMemory.fontData, "the CLI's path builds the app's bytes")
        let output = try Font(data: fromFiles.fontData)
        let lxgw = try Font(data: data[ReplaceTests.cjk]!)
        #expect(
            try output.flattenedOutline(of: Int(output.characterMap.mappings[0x50B3]!)).rounded()
                == lxgw.flattenedOutline(of: Int(lxgw.characterMap.mappings[0x50B3]!)).rounded(),
            "傳 came from the second step's file, not the first's")
        try FileManager.default.removeItem(at: directory.appendingPathComponent(ReplaceTests.cjk))
        #expect(throws: BuildError.self) { try RecipeBuilder.build(recipeAt: url, options: BuildOptions()) }
    }
}

/// Recipe format and gates of the replace step, on the small fixtures.
struct ReplaceRecipeTests {
    private func recipe(_ step: String, source: String = "ops.ttf") throws -> Recipe {
        try Recipe(
            json: recipeJSON(
                sourceFile: source, sha256: sha256Hex(try Fixtures.bytes(source)),
                output: #"{"familyName": "Example"}"#, steps: "[\(step)]"))
    }

    private func font(_ name: String) throws -> String {
        #"{"file": "\#(name)", "sha256": "\#(sha256Hex(try Fixtures.bytes(name)))"}"#
    }

    @Test func decodesStrictlyAndCanonically() throws {
        let decoded = try recipe(
            #"{"op": "replace", "font": \#(try font("minimal.ttf")), "sets": ["digits", "latinLetters", "digits"], "#
                + #""characters": ["中", "A", "中"]}"#)
        let step = try #require(decoded.replaceSteps.first)
        #expect(step.sets == [.latinLetters, .digits])
        #expect(step.characters == ["A", "中"])
        #expect(step.match == .unitsPerEm && step.size == 1 && step.baselineShift == 0)
        #expect(try Recipe(json: decoded.canonicalJSON()) == decoded)

        let minimal = try font("minimal.ttf")
        #expect(throws: RecipeError.unknownKey(path: "steps[0].scale")) {
            try recipe(#"{"op": "replace", "font": \#(minimal), "sets": ["digits"], "scale": 2}"#)
        }
        #expect(throws: RecipeError.self) { try recipe(#"{"op": "replace", "font": \#(minimal)}"#) }
        #expect(throws: RecipeError.self) { try recipe(#"{"op": "replace", "font": \#(minimal), "sets": ["greek"]}"#) }
        #expect(throws: RecipeError.self) {
            try recipe(#"{"op": "replace", "font": \#(minimal), "characters": ["AB"]}"#)
        }
        #expect(throws: RecipeError.self) {
            try recipe(#"{"op": "replace", "font": \#(minimal), "sets": ["digits"], "size": 0}"#)
        }
        #expect(throws: RecipeError.missingKey(path: "steps[0].font.sha256")) {
            try recipe(#"{"op": "replace", "font": {"file": "x.ttf"}, "sets": ["digits"]}"#)
        }
    }

    /// Like `source.file`, where the second font sits on one machine is not
    /// part of what the recipe makes.
    @Test func identityIgnoresWhereTheReplacementSits() throws {
        let sha = sha256Hex(try Fixtures.bytes("minimal.ttf"))
        let here = try recipe(#"{"op": "replace", "font": {"file": "minimal.ttf", "sha256": "\#(sha)"}, "sets": ["digits"]}"#)
        let there = try recipe(
            #"{"op": "replace", "font": {"file": "/elsewhere/minimal.ttf", "sha256": "\#(sha)"}, "sets": ["digits"]}"#)
        #expect(try here.identityHash() == there.identityHash())
        let other = try recipe(#"{"op": "replace", "font": {"file": "minimal.ttf", "sha256": "\#(sha)"}, "sets": ["latin1"]}"#)
        #expect(try here.identityHash() != other.identityHash())

        // Every replace step's file, not only the first one's.
        let ops = sha256Hex(try Fixtures.bytes("ops.ttf"))
        func two(_ second: String) throws -> Recipe {
            try recipe(
                #"{"op": "replace", "font": {"file": "minimal.ttf", "sha256": "\#(sha)"}, "sets": ["digits"]}, "#
                    + #"{"op": "replace", "font": {"file": "\#(second)", "sha256": "\#(ops)"}, "characters": ["漢"]}"#)
        }
        #expect(try two("ops.ttf").identityHash() == two("/elsewhere/ops.ttf").identityHash())
    }

    /// Several replace steps, each with its own font, make one recipe; any
    /// other operation still runs at most once.
    @Test func severalReplaceStepsDecode() throws {
        let decoded = try recipe(
            #"{"op": "replace", "font": \#(try font("minimal.ttf")), "sets": ["digits"]}, {"op": "embolden", "weight": 6}, "#
                + #"{"op": "replace", "font": \#(try font("ops.ttf")), "characters": ["漢", "口"]}"#)
        #expect(decoded.replaceSteps.map(\.font.file) == ["minimal.ttf", "ops.ttf"])
        #expect(decoded.replaceSteps[1].characters == ["口", "漢"])
        #expect(try Recipe(json: decoded.canonicalJSON()) == decoded)
        #expect(
            throws: RecipeError.invalidValue(
                path: "steps[1].op", reason: "'embolden' appears more than once; each operation runs at most once")
        ) {
            try recipe(#"{"op": "embolden", "weight": 6}, {"op": "embolden", "weight": 8}"#)
        }
    }

    /// A character two replace steps ask for would show whichever ran last;
    /// the recipe is refused instead, named by the later step, whether the
    /// clash is in listed characters or in a set. A recipe put together in
    /// code meets the same rule in the build and in the preview.
    @Test func aCharacterComesFromOneReplaceStep() throws {
        let minimal = try font("minimal.ttf")
        let clash = RecipeError.invalidValue(
            path: "steps[1]", reason: "U+0041 A also replaced by steps[0]; each character comes from one replace step")
        #expect(throws: clash) {
            try recipe(
                #"{"op": "replace", "font": \#(minimal), "characters": ["A"]}, "#
                    + #"{"op": "replace", "font": \#(try font("ops.ttf")), "sets": ["latinLetters"]}"#)
        }
        // The same font twice does not make it one step's character.
        #expect(
            throws: RecipeError.invalidValue(
                path: "steps[2]", reason: "U+0041 A also replaced by steps[0]; each character comes from one replace step")
        ) {
            try recipe(
                #"{"op": "replace", "font": \#(minimal), "characters": ["中", "A"]}, {"op": "embolden", "weight": 6}, "#
                    + #"{"op": "replace", "font": \#(minimal), "characters": ["A"]}"#)
        }

        var inCode = try recipe(#"{"op": "replace", "font": \#(minimal), "characters": ["A"]}"#)
        inCode.steps.append(inCode.steps[0])
        #expect(throws: clash) {
            try RecipeBuilder.build(
                inCode, sourceData: Data(try Fixtures.bytes("ops.ttf")),
                replacementData: [inCode.replaceSteps[0].font.sha256: Data(try Fixtures.bytes("minimal.ttf"))],
                options: BuildOptions(iHaveRights: true))
        }
        #expect(throws: clash) {
            try Fixtures.font("ops.ttf").preview(
                of: [0x41], steps: inCode.steps,
                replacements: [inCode.replaceSteps[0].font.sha256: try Fixtures.font("minimal.ttf")])
        }
    }

    private func build(_ recipe: Recipe, replacement: String?, options: BuildOptions = BuildOptions()) throws
        -> BuildResult
    {
        // Keyed by what the recipe expects, whatever the file: a wrong one
        // must reach the sha256 check, not pass for missing.
        try RecipeBuilder.build(
            recipe, sourceData: Data(try Fixtures.bytes("ops.ttf")),
            replacementData: try replacement.map { [recipe.replaceSteps[0].font.sha256: Data(try Fixtures.bytes($0))] }
                ?? [:], options: options)
    }

    /// The license gate applies to the second font: its glyphs ship too.
    @Test func replacementGoesThroughTheLicenseGate() throws {
        let restricted = try recipe(#"{"op": "replace", "font": \#(try font("restricted.ttf")), "characters": ["A"]}"#)
        #expect(throws: BuildError.replacementLicenseRestricted(file: "restricted.ttf")) {
            try build(restricted, replacement: "restricted.ttf", options: BuildOptions(iHaveRights: true))
        }
        let unknown = try recipe(#"{"op": "replace", "font": \#(try font("minimal.ttf")), "characters": ["A"]}"#)
        #expect(throws: BuildError.replacementLicenseNotConfirmed(file: "minimal.ttf")) {
            try build(unknown, replacement: "minimal.ttf")
        }
        let confirmed = try build(unknown, replacement: "minimal.ttf", options: BuildOptions(iHaveRights: true))
        let output = try Font(data: confirmed.fontData)
        #expect(Int(output.characterMap.mappings[0x41]!) >= (try Fixtures.font("ops.ttf")).glyphs.count)

        #expect(throws: BuildError.replacementUnreadable(path: "minimal.ttf", reason: "no file was given for it")) {
            try build(unknown, replacement: nil, options: BuildOptions(iHaveRights: true))
        }
        #expect(throws: BuildError.self) {
            try build(unknown, replacement: "ops.ttf", options: BuildOptions(iHaveRights: true))
        }
    }

    @Test func listedCharactersMustBeInTheReplacement() throws {
        let missing = try recipe(#"{"op": "replace", "font": \#(try font("minimal.ttf")), "characters": ["A", "中"]}"#)
        #expect(throws: ReplaceError.charactersNotInReplacement(["中"])) {
            try build(missing, replacement: "minimal.ttf", options: BuildOptions(iHaveRights: true))
        }
    }

    /// The CLI reads the second font beside the recipe, as it reads the source.
    @Test func cliPathReadsTheReplacementBesideTheRecipe() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["ops.ttf", "minimal.ttf"] {
            try Data(try Fixtures.bytes(name)).write(to: directory.appendingPathComponent(name))
        }
        let url = directory.appendingPathComponent("recipe.json")
        try recipe(#"{"op": "replace", "font": \#(try font("minimal.ttf")), "characters": ["A"]}"#)
            .canonicalJSON().write(to: url)
        let first = try RecipeBuilder.build(recipeAt: url, options: BuildOptions(iHaveRights: true))
        let second = try RecipeBuilder.build(recipeAt: url, options: BuildOptions(iHaveRights: true))
        #expect(first.fontData == second.fontData, "deterministic")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("minimal.ttf"))
        #expect(throws: BuildError.self) { try RecipeBuilder.build(recipeAt: url, options: BuildOptions(iHaveRights: true)) }
    }
}
