import CoreGraphics
import FontsMakerKit
import Foundation
import Testing

/// Risk review's 從另一套字型取代 (technical design §5.7, product spec §4.5):
/// a glyph whose strokes emboldening crowded shows another library font's
/// glyph instead, as 白鷺楷 took 傳 and 導 from 霞鶩文楷. The decision is a
/// replace step after embolden, so the borrowed glyph keeps its own weight;
/// it survives a relaunch, sits beside 英文字母換成另一套字型's step, and
/// the export rebuilds through the CLI with every font beside the recipe.
@MainActor
struct BorrowTests {
    static let lxgw = "LXGWWenKaiTC-Medium.ttf"

    /// ops.ttf (a few hanzi, OFL) with 霞鶩文楷 Medium in the library: it
    /// emboldens in milliseconds, where 原俠正楷 takes a minute.
    private func opsWithLXGW() async throws -> (LibraryModel, EditorModel, URL, LibraryEntry) {
        let (library, editor, root) = try await makeEditor([
            TestFonts.fixture("ops.ttf"), try TestFonts.reference(BorrowTests.lxgw),
        ])
        let lxgw = try #require(library.entries.first { $0.fileName == BorrowTests.lxgw })
        return (library, editor, root, lxgw)
    }

    private func borrowed(_ entry: LibraryEntry) -> RecipeDraft.BorrowedFont {
        RecipeDraft.BorrowedFont(sha256: entry.id, fileName: entry.fileName)
    }

    /// The glyph's outline in `font`, for the character, composites flattened.
    private func outline(of character: String, in font: Font) throws -> CGPath {
        let glyph = try #require(font.characterMap.mappings[character.unicodeScalars.first!.value])
        return try font.path(ofGlyph: Int(glyph))
    }

    /// Build, review, borrow a risky hanzi from 霞鶩文楷, rebuild: the
    /// recipe gains a replace step after embolden, the page and the font
    /// show 霞鶩文楷's glyph as drawn (not emboldened, its strokes would
    /// crowd again), the risk notice stops counting it, and the export
    /// rebuilds byte for byte with both fonts beside the recipe.
    @Test func borrowedGlyphKeepsItsOwnWeightAndRebuildsThroughTheCLI() async throws {
        let (library, editor, root, lxgw) = try await opsWithLXGW()
        defer { try? FileManager.default.removeItem(at: root) }
        // Past the slider's range: ops' few glyphs crowd only there (回 B, 。 A at 70).
        editor.draft.emboldenWeight = 70
        editor.draft.familyName = "Ops Borrow"
        editor.startBuild()
        await editor.buildSettled()
        let first = try #require(editor.outcome, "build: \(editor.build)")
        let report = try #require(first.emboldenReport)
        #expect(first.riskyGlyphs == report.count(of: .a) + report.count(of: .b))

        await editor.findBorrowCandidates()
        #expect(!editor.isFindingBorrowCandidates)
        let item = try #require(
            editor.review.items.first { !editor.borrowCandidates(for: $0).isEmpty },
            "a risky hanzi 霞鶩文楷 has: \(editor.review.items.map(\.label))")
        #expect(editor.borrowCandidates(for: item).map(\.id) == [lxgw.id], "the other CJK OFL font of the library")
        let character = item.characters[0]

        editor.setDecision(.borrow(borrowed(lxgw)), for: item)
        #expect(editor.decision(for: item) == .borrow(borrowed(lxgw)))
        #expect(Set(editor.draft.borrowed.keys) == Set(item.characters))
        #expect(editor.draft.steps.map(\.op) == ["embolden", "replace"], "borrowed after embolden: \(editor.draft.steps)")
        guard case .replace(let step) = editor.draft.steps.last else { return }
        #expect(step.font == Recipe.Source(file: BorrowTests.lxgw, sha256: lxgw.id))
        #expect(step.characters == item.characters.sorted() && step.match == .unitsPerEm && step.size == 1)

        await editor.secondFontsSettled()
        editor.sampleText = character + "口"
        await editor.previewSettled()
        #expect(editor.previewProblem == nil, "\(editor.previewProblem ?? "")")
        let lxgwFont = try #require(editor.secondFonts[lxgw.id]?.font)
        let shown = try #require(editor.previewPage?.positions.first { String($0.scalar) == character }?.glyph?.path)
        #expect(shown == (try outline(of: character, in: lxgwFont)), "the page shows 霞鶩文楷's \(character) as drawn")

        editor.startBuild()
        await editor.buildSettled()
        let second = try #require(editor.outcome, "build: \(editor.build)")
        let output = try Font(data: second.result.fontData)
        #expect(try outline(of: character, in: output) == outline(of: character, in: lxgwFont))
        let secondReport = try #require(second.emboldenReport)
        let graded = secondReport.glyphs.first { $0.glyphID == item.id }?.grade
        #expect(graded.map(RiskReview.reviewedGrades.contains) == true, "the source glyph is still emboldened and graded")
        #expect(
            second.riskyGlyphs == secondReport.count(of: .a) + secondReport.count(of: .b) - 1,
            "the notice no longer counts the glyph nobody sees")
        #expect(editor.review.items.contains { $0.id == item.id }, "it stays in the review, to be changed back")

        let directory = root.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let check = try #require(
            await editor.writeExport(to: directory.appendingPathComponent(second.result.fileName)),
            "export: \(editor.exportProblem ?? "")")
        #expect(check.mismatches.isEmpty, "CoreText shows what the page showed: \(check.mismatches)")
        let recipe = try Recipe(contentsOf: check.recipeURL)
        #expect(recipe.replaceSteps.map(\.font.file) == [BorrowTests.lxgw])
        for (entry, name) in [(editor.entry, recipe.source.file), (lxgw, BorrowTests.lxgw)] {
            try FileManager.default.copyItem(
                at: library.fontURL(for: entry), to: directory.appendingPathComponent(name))
        }
        let rebuilt = try RecipeBuilder.build(recipeAt: check.recipeURL, options: BuildOptions())
        #expect(sha256Hex(rebuilt.fontData) == second.sha256, "CLI rebuild of the exported recipe is byte-identical")

        // A review decision, like 不加粗: without 加粗 there is nothing to borrow for.
        editor.draft.emboldenWeight = 0
        #expect(editor.draft.steps.isEmpty && !editor.draft.borrowed.isEmpty)
    }

    /// Only hanzi (kana, hangul) are offered: a borrowed glyph comes in at
    /// its own font's size, which fits a full-width character, not a letter.
    @Test func onlyCJKGlyphsCanBeBorrowed() async throws {
        let (_, editor, root, lxgw) = try await opsWithLXGW()
        defer { try? FileManager.default.removeItem(at: root) }
        await editor.findBorrowCandidates()
        let font = try #require(editor.sourceFont?.font)
        func item(_ character: String) throws -> ReviewItem {
            let glyph = try #require(font.characterMap.mappings[character.unicodeScalars.first!.value])
            return ReviewItem(id: Int(glyph), characters: [character], label: character, grade: .a)
        }
        #expect(editor.borrowCandidates(for: try item("漢")).map(\.id) == [lxgw.id])
        // 霞鶩文楷 has an A too.
        #expect(editor.borrowCandidates(for: try item("A")).isEmpty)
    }

    /// The decision is part of the saved draft: reopened, the font is read
    /// again, the build can run, and after a rebuild the glyph is back in
    /// the review with its decision. Drafts from before have none.
    @Test func borrowedGlyphsSurviveARelaunch() async throws {
        let (library, editor, root, lxgw) = try await opsWithLXGW()
        defer { try? FileManager.default.removeItem(at: root) }
        editor.draft.emboldenWeight = RecipeDraft.defaultWeight
        editor.draft.familyName = "Ops Borrow"
        editor.draft.borrowed = ["漢": borrowed(lxgw)]
        editor.saveDraft()
        await editor.draftSettled()

        let entry = editor.entry
        let reopened = EditorModel(
            entry: entry, fontURL: library.fontURL(for: entry), draftURL: library.draftURL(for: entry),
            licenseTextURL: library.licenseTextURL(for: entry), library: library)
        #expect(reopened.draft.borrowed == ["漢": borrowed(lxgw)])
        await reopened.load()
        await reopened.secondFontsSettled()
        #expect(reopened.secondFonts[lxgw.id] != nil && reopened.canBuild)
        reopened.startBuild()
        await reopened.buildSettled()
        #expect(reopened.outcome?.recipe.replaceSteps.first?.characters == ["漢"])
        let han = try #require(reopened.review.items.first { $0.characters.contains("漢") })
        #expect(reopened.decision(for: han) == .borrow(borrowed(lxgw)))

        let old =
            #"{"emboldenWeight":12,"familyName":"","localizedFamilyName":"","perCharacter":{},"skip":["漢"],"styleName":"Regular"}"#
        #expect(try JSONDecoder().decode(RecipeDraft.self, from: Data(old.utf8)).borrowed.isEmpty)
    }

    /// With 英文字母換成另一套字型 on too, the recipe has two replace steps,
    /// Literata's before embolden and 霞鶩文楷's after it; the page shows
    /// both; and the output name must stay clear of both fonts' names.
    /// On 原俠正楷 by preview only: building it would embolden every glyph.
    @Test func besideEnglishLettersTheRecipeHasTwoReplaceSteps() async throws {
        let (library, editor, root) = try await makeEditor([
            try TestFonts.reference("GuanKiapTsingKhai.ttf"), try TestFonts.reference("Literata-VF.ttf"),
            try TestFonts.reference(BorrowTests.lxgw),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let literata = try #require(library.entries.first { $0.fileName == "Literata-VF.ttf" })
        let lxgw = try #require(library.entries.first { $0.fileName == BorrowTests.lxgw })
        editor.draft.replacement = RecipeDraft.Replacement(sha256: literata.id, fileName: literata.fileName)
        editor.draft.emboldenWeight = RecipeDraft.defaultWeight
        editor.draft.borrowed = ["傳": borrowed(lxgw)]
        editor.draft.familyName = "GKTK Mixed"
        let recipe = try editor.draft.recipe(source: editor.source)
        #expect(recipe.steps.map(\.op) == ["replace", "embolden", "replace"])
        #expect(recipe.replaceSteps.map(\.font.file) == ["Literata-VF.ttf", BorrowTests.lxgw])

        await editor.secondFontsSettled()
        editor.sampleText = "傳x"
        await editor.previewSettled()
        #expect(editor.previewProblem == nil, "\(editor.previewProblem ?? "")")
        let page = try #require(editor.previewPage)
        let lxgwFont = try #require(editor.secondFonts[lxgw.id]?.font)
        #expect(page.positions.first { $0.scalar == "傳" }?.glyph?.path == (try outline(of: "傳", in: lxgwFont)))
        let x = try #require(page.positions.first { $0.scalar == "x" }?.glyph?.path.boundingBoxOfPath.maxY)
        let ownX = try #require(editor.sourcePage?.positions.first { $0.scalar == "x" }?.glyph?.path.boundingBoxOfPath.maxY)
        #expect((ownX + 3...ownX + 10).contains(x), "Literata's x at the font's x-height, emboldened: \(x) vs \(ownX)")

        #expect(editor.nameProblem == nil && editor.canBuild)
        editor.draft.familyName = "LXGW WenKai TC Ebook"
        #expect(editor.nameProblem?.contains("LXGW") == true, "the borrowed glyphs' font binds the name too")
        editor.draft.familyName = "Literata Ebook"
        #expect(editor.nameProblem?.contains("Literata") == true)
    }
}
