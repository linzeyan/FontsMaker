import CoreText
import FontsMakerKit
import Foundation
import Testing

/// English reading tuning in the app (Phase 4c): a Latin font is offered the
/// cards that act on Latin text, previews English, and exports what the
/// preview shows, rebuilt to the same bytes by the CLI's code path.
@MainActor
struct ReadingTuningTests {
    /// The cards follow the font: 直排閱讀 and 簡體書顯示繁體 find nothing to
    /// turn or convert in a font without CJK, so a Latin font gets 字距 and
    /// 行高 instead. Its page is English; a CJK font's keeps the Chinese text
    /// with a line of English under it for its Latin letters.
    @Test func aLatinFontGetsEnglishTextAndItsOwnCards() async throws {
        let (_, latin, root) = try await makeEditor([try TestFonts.reference("CrimsonText-Regular.ttf")])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!latin.fontHasCJK)
        #expect(latin.sampleText == EditorModel.latinSampleText && latin.defaultSampleText == latin.sampleText)

        let (_, cjk, cjkRoot) = try await makeEditor([TestFonts.fixture("ops.ttf")])
        defer { try? FileManager.default.removeItem(at: cjkRoot) }
        #expect(cjk.fontHasCJK)
        #expect(cjk.sampleText.hasPrefix(EditorModel.cjkSampleText) && cjk.sampleText.contains("best of times"))

        // A text the user put in stays, whatever the font.
        let (library, _, typedRoot) = try await makeEditor([try TestFonts.reference("CrimsonText-Regular.ttf")])
        defer { try? FileManager.default.removeItem(at: typedRoot) }
        let entry = try #require(library.entries.first)
        let typed = EditorModel(
            entry: entry, fontURL: library.fontURL(for: entry), draftURL: library.draftURL(for: entry),
            licenseTextURL: library.licenseTextURL(for: entry))
        typed.sampleText = "Hamburgefonstiv"
        await typed.load()
        #expect(typed.sampleText == "Hamburgefonstiv")
    }

    /// 行高 and 字距 show on the page as the font will set them: the line is
    /// the units asked for, and each letter's advance carries the tracking
    /// on top of what widen gave it.
    @Test func previewShowsLineHeightAndTracking() async throws {
        let (_, editor, root) = try await makeEditor([try TestFonts.reference("CrimsonText-Regular.ttf")])
        defer { try? FileManager.default.removeItem(at: root) }
        editor.sampleText = "on"
        await editor.previewSettled()
        let plain = try #require(editor.previewPage)
        #expect(plain.lineHeight == CGFloat(try #require(editor.sourceLineHeight)))

        editor.draft.lineHeight = editor.suggestedLineHeight
        #expect(editor.draft.lineHeight == 1536, "1.30 em + 0.2 em, on the slider's 0.05 em steps")
        editor.draft.tracking = RecipeDraft.defaultTracking(unitsPerEm: 1024)
        #expect(editor.draft.tracking == 20)
        await editor.previewSettled()
        let tuned = try #require(editor.previewPage)
        #expect(tuned.lineHeight == 1536)
        for (before, after) in zip(plain.positions, tuned.positions) {
            #expect(after.glyph?.advance == (before.glyph?.advance ?? 0) + 20)
        }
        #expect(editor.draft.familyName == "CT Ebook", "reading tuning names the font as 加粗 does")
    }

    /// 加粗＋字寬＋字距＋行高 on Crimson Text, exported: CoreText loads the
    /// file, every position shows what the preview drew, the line is what 行高
    /// set, and the exported recipe rebuilds to the same bytes.
    @Test func exportOfAllFourRebuildsTheSameBytes() async throws {
        let sourceURL = try TestFonts.reference("CrimsonText-Regular.ttf")
        let (_, editor, root) = try await makeEditor([sourceURL])
        defer { try? FileManager.default.removeItem(at: root) }
        editor.draft.emboldenWeight = 20
        editor.draft.widen = true
        editor.draft.tracking = 16
        editor.draft.lineHeight = 1434
        #expect(editor.canBuild)
        editor.startBuild()
        await editor.buildSettled()
        let outcome = try #require(editor.outcome)
        #expect(
            outcome.recipe.steps == [
                .embolden(EmboldenStep(weight: 20, widen: true)), .tracking(TrackingOptions(units: 16)),
                .lineHeight(LineHeightOptions(units: 1434)),
            ])

        let exportDirectory = root.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let fontURL = exportDirectory.appendingPathComponent(outcome.result.fileName)
        let check = try #require(await editor.writeExport(to: fontURL))
        #expect(check.checkedGlyphs > 200 && check.mismatches.isEmpty, "mismatches at \(check.mismatches)")
        #expect(abs(check.page.lineHeight - 1434) < 0.05, "CoreText's line is 行高's")

        try FileManager.default.copyItem(
            at: sourceURL, to: exportDirectory.appendingPathComponent("CrimsonText-Regular.ttf"))
        let rebuilt = try RecipeBuilder.build(recipeAt: check.recipeURL, options: BuildOptions())
        #expect(sha256Hex(rebuilt.fontData) == outcome.sha256)
    }

    /// The new controls are saved with the draft; a draft saved before they
    /// existed opens with them off.
    @Test func draftKeepsTheNewControls() throws {
        var draft = RecipeDraft()
        draft.emboldenWeight = 12
        draft.widen = true
        draft.tracking = 30
        draft.lineHeight = 1300
        draft.familyName = "CT Ebook"
        let restored = try JSONDecoder().decode(RecipeDraft.self, from: JSONEncoder().encode(draft))
        #expect(restored == draft)

        let older = Data(
            #"{"emboldenWeight": 12, "skip": [], "perCharacter": {}, "familyName": "A", "localizedFamilyName": "", "styleName": "Medium"}"#
                .utf8)
        let old = try JSONDecoder().decode(RecipeDraft.self, from: older)
        #expect(!old.widen && old.tracking == 0 && old.lineHeight == nil)
        #expect(old.steps == [.embolden(EmboldenStep(weight: 12))])
    }
}
