import CoreGraphics
import FontsMakerKit
import Foundation
import Testing

/// 英文字母換成另一套字型 (design §5.7): a CJK font takes its Latin letters
/// from another library font. The page shows them at the CJK font's
/// x-height, the export is what the page showed, and the CLI rebuilds the
/// exported recipe byte for byte with both fonts beside it (product spec §4.9).
@MainActor
struct ReplacementTests {
    private func editorWithLiterata() async throws -> (LibraryModel, EditorModel, URL, LibraryEntry) {
        let guanKiap = try TestFonts.reference("GuanKiapTsingKhai.ttf")
        let literata = try TestFonts.reference("Literata-VF.ttf")
        let (library, editor, root) = try await makeEditor([guanKiap, literata])
        let second = try #require(library.entries.first { $0.fileName == "Literata-VF.ttf" })
        return (library, editor, root, second)
    }

    private func choose(_ entry: LibraryEntry, in editor: EditorModel, size: Double = 1) async {
        editor.draft.replacement = RecipeDraft.Replacement(sha256: entry.id, fileName: entry.fileName, size: size)
        await editor.secondFontsSettled()
        await editor.previewSettled()
    }

    private func top(of character: Unicode.Scalar, on page: PageText?) -> CGFloat? {
        page?.positions.first { $0.scalar == character }?.glyph?.path.boundingBoxOfPath.maxY
    }

    /// The page's x stands as tall as the CJK font's own x: that is what
    /// makes the second font's letters sit right beside the hanzi. Without
    /// the match Literata's x would be 4.8 % taller (507 vs 484 units).
    @Test func pageShowsTheSecondFontsLettersAtTheTargetsXHeight() async throws {
        let (_, editor, root, literata) = try await editorWithLiterata()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(editor.replacementCandidates.map(\.id) == [literata.id], "the other OFL font of the library")
        editor.sampleText = "中文 xa"
        await editor.previewSettled()
        let ownA = try #require(editor.previewPage?.positions.first { $0.scalar == "a" }?.glyph?.path)
        let ownX = try #require(top(of: "x", on: editor.previewPage))

        await choose(literata, in: editor)
        let page = try #require(editor.previewPage)
        #expect(editor.previewProblem == nil)
        #expect(page.positions.first { $0.scalar == "a" }?.glyph?.path != ownA, "a is Literata's now")
        let x = try #require(top(of: "x", on: page))
        #expect(abs(x - ownX) / ownX < 0.01, "x-height \(x) vs the font's own \(ownX)")
        #expect(page.positions.first { $0.scalar == "中" }?.glyph?.path == editor.sourcePage?.positions.first?.glyph?.path)

        // 大小 scales from that match.
        editor.draft.replacement?.size = 1.2
        await editor.previewSettled()
        let larger = try #require(top(of: "x", on: editor.previewPage))
        #expect(abs(larger / ownX - 1.2) < 0.01, "120 %: \(larger) vs \(ownX)")
    }

    /// The exported font is what the page showed (CoreText, no fallback for
    /// the new letters), and the exported recipe rebuilds to the same bytes
    /// through the CLI's path with both fonts beside it under the names the
    /// recipe gives them.
    @Test func exportRebuildsWithTheSecondFontBesideTheRecipe() async throws {
        let (_, editor, root, literata) = try await editorWithLiterata()
        defer { try? FileManager.default.removeItem(at: root) }
        editor.sampleText = "中英混排 Mixed text, déjà vu 123。"
        await choose(literata, in: editor, size: 1.05)
        // Embolden comes after it, so the borrowed letters are as bold as the
        // rest. Not built here: emboldening GuanKiap's 25,000 glyphs takes a minute.
        editor.draft.emboldenWeight = 12
        guard case .replace? = editor.draft.steps.first, case .embolden? = editor.draft.steps.dropFirst().first else {
            Issue.record("replace runs first: \(editor.draft.steps)")
            return
        }
        editor.draft.emboldenWeight = 0
        editor.draft.familyName = "GKTK Mixed"
        await editor.previewSettled()
        #expect(editor.canBuild, "name: \(editor.nameProblem ?? "-"), license: \(editor.licenseProblem ?? "-")")

        editor.startBuild()
        await editor.buildSettled()
        let outcome = try #require(editor.outcome, "build: \(editor.build)")
        let directory = root.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let check = try #require(
            await editor.writeExport(to: directory.appendingPathComponent(outcome.result.fileName)),
            "export: \(editor.exportProblem ?? "")")
        #expect(check.mismatches.isEmpty && check.checkedGlyphs > 20, "\(check.mismatches) of \(check.checkedGlyphs)")

        let recipe = try Recipe(contentsOf: check.recipeURL)
        let step = try #require(recipe.replaceSteps.first)
        #expect(step.font == Recipe.Source(file: "Literata-VF.ttf", sha256: literata.id))
        #expect(step.match == .xHeight && step.size == 1.05 && step.sets == RecipeDraft.replacementSets)
        for (file, name) in [("GuanKiapTsingKhai.ttf", recipe.source.file), ("Literata-VF.ttf", step.font.file)] {
            try FileManager.default.copyItem(
                at: try TestFonts.reference(file), to: directory.appendingPathComponent(name))
        }
        let rebuilt = try RecipeBuilder.build(recipeAt: check.recipeURL, options: BuildOptions())
        #expect(sha256Hex(rebuilt.fontData) == outcome.sha256, "CLI rebuild of the exported recipe is byte-identical")
    }

    /// The output carries Literata's glyphs, so its name must stay clear of
    /// Literata's too, as the build will insist (OFL condition 3).
    @Test func outputNameMustNotUseTheSecondFontsName() async throws {
        let (_, editor, root, literata) = try await editorWithLiterata()
        defer { try? FileManager.default.removeItem(at: root) }
        editor.draft.familyName = "Literata Kai"
        #expect(editor.nameProblem == nil, "nothing of Literata's in the font yet")
        await choose(literata, in: editor)
        #expect(editor.nameProblem?.contains("Literata") == true)
        #expect(!editor.canBuild)
    }

    /// The choice is part of the saved draft; a draft whose second font left
    /// the library says so, and does not build without it.
    @Test func choiceSurvivesARelaunchAndAMissingFontIsSaid() async throws {
        let (library, editor, root, literata) = try await editorWithLiterata()
        defer { try? FileManager.default.removeItem(at: root) }
        await choose(literata, in: editor, size: 1.1)
        editor.saveDraft()
        await editor.draftSettled()

        let entry = editor.entry
        let reopened = EditorModel(
            entry: entry, fontURL: library.fontURL(for: entry), draftURL: library.draftURL(for: entry),
            licenseTextURL: library.licenseTextURL(for: entry), library: library)
        #expect(reopened.draft.replacement == RecipeDraft.Replacement(sha256: literata.id, fileName: literata.fileName, size: 1.1))
        await reopened.load()
        await reopened.secondFontsSettled()
        #expect(reopened.replacementFont?.id == literata.id && reopened.replacementProblem == nil)

        // Without the library the font cannot be found.
        let orphan = EditorModel(
            entry: entry, fontURL: library.fontURL(for: entry), draftURL: library.draftURL(for: entry),
            licenseTextURL: library.licenseTextURL(for: entry))
        await orphan.load()
        #expect(orphan.replacementProblem?.contains("Literata-VF.ttf") == true)
        #expect(!orphan.canBuild && orphan.previewPage == nil)

        // Drafts from before the card have no replacement.
        let old =
            #"{"emboldenWeight":0,"familyName":"","localizedFamilyName":"","perCharacter":{},"skip":[],"styleName":"Regular"}"#
        #expect(try JSONDecoder().decode(RecipeDraft.self, from: Data(old.utf8)).replacement == nil)
    }
}
