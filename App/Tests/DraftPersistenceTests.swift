import FontsMakerKit
import Foundation
import Testing

/// Each font's draft outlives the app: a relaunch opens the editor as the
/// user left it. A relaunch here is a new `AppModel` on the same root.
@MainActor
struct DraftPersistenceTests {
    /// The draft comes back whole, review decisions included, before the
    /// font loads, so the first preview already shows it; and the page
    /// follows it: a pseudoVertical draft opens turned, whichever way the
    /// user flipped the page in the last session.
    @Test func relaunchRestoresTheDraft() async throws {
        let (app, entry, root) = try await makeApp()
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = try #require(app.editor(for: entry.id))
        #expect(editor.draft == RecipeDraft() && editor.previewOrientation == .horizontal)
        editor.draft.emboldenWeight = RecipeDraft.defaultWeight
        editor.draft.pseudoVertical = PseudoVerticalOptions()
        editor.draft.styleName = "Medium"
        editor.draft.familyName = "Ops Vertical"
        editor.draft.localizedFamilyName = "直排測試"
        editor.draft.skip = ["漢"]
        editor.draft.perCharacter = ["汉": 6]
        editor.previewOrientation = .horizontal
        await editor.draftSettled()
        let saved = editor.draft

        let relaunched = AppModel(root: root)
        let restored = try #require(relaunched.editor(for: entry.id))
        #expect(restored !== editor)
        #expect(restored.draft == saved)
        #expect(restored.draft.skip == ["漢"] && restored.draft.perCharacter == ["汉": 6])
        #expect(restored.previewOrientation == .readerRotated)

        restored.sampleText = "漢"
        await restored.load()
        await restored.previewSettled()
        let font = try #require(restored.sourceFont?.font)
        let upright = try font.path(ofGlyph: Int(font.characterMap.mappings[0x6F22]!))
        let shown = try #require(restored.previewPage?.positions.first?.glyph)
        #expect(shown.path != upright, "the first preview turns 漢, as the restored pseudoVertical does")
        #expect(restored.draft == saved, "loading the font suggests names only to a font never named")
    }

    /// After a relaunch the review starts empty, and the rebuilt report does
    /// not list a skipped glyph, nor rank a lighter one that now grades C or
    /// D: each restored decision must still be in the review so it can be
    /// changed back. Neither glyph was graded at the step's weight, so
    /// neither gets a first grade.
    @Test func restoredDecisionsStayInTheReview() async throws {
        let (app, entry, root) = try await makeApp()
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = try #require(app.editor(for: entry.id))
        editor.draft.familyName = "Ebook Kai"
        editor.draft.emboldenWeight = 6
        editor.draft.skip = ["漢"]
        editor.draft.perCharacter = ["汉": 1]
        app.saveDrafts()

        let restored = try #require(AppModel(root: root).editor(for: entry.id))
        await restored.load()
        #expect(restored.review.items.isEmpty && restored.canBuild)
        restored.startBuild()
        await restored.buildSettled()
        let report = try #require(restored.outcome?.emboldenReport)
        let font = try #require(restored.sourceFont?.font)
        let han = Int(try #require(font.characterMap.mappings[0x6F22]))
        let simplified = Int(try #require(font.characterMap.mappings[0x6C49]))
        let grades = Dictionary(uniqueKeysWithValues: report.glyphs.map { ($0.glyphID, $0.grade) })
        try #require(grades[han] == nil, "a skipped glyph is not in the report")
        let lighterGrade = try #require(grades[simplified])
        try #require(!RiskReview.reviewedGrades.contains(lighterGrade), "汉 at weight 1 grades C or D")

        let skipped = try #require(restored.review.items.first { $0.id == han })
        #expect(skipped.characters.contains("漢") && skipped.firstGrade == nil && skipped.grade == nil)
        #expect(restored.decision(for: skipped) == .skip)
        let lighter = try #require(restored.review.items.first { $0.id == simplified })
        #expect(lighter.firstGrade == nil && lighter.grade == lighterGrade && lighter.weight == 1)
        #expect(restored.decision(for: lighter) == .weight(1))

        restored.setDecision(.accept, for: skipped)
        restored.setDecision(.accept, for: lighter)
        #expect(restored.draft.skip.isEmpty && restored.draft.perCharacter.isEmpty)
    }

    /// A draft file that cannot be read (cut short, or holding options the
    /// engine refuses) costs only that draft: the editor starts fresh and
    /// upright, the font still opens, and the next change replaces the file.
    @Test func unreadableDraftStartsFresh() async throws {
        let (app, entry, root) = try await makeApp()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = app.library.draftURL(for: entry)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let unreadable = [
            #"{"emboldenWeight":12,"skip":["#,
            #"{"emboldenWeight":0,"skip":[],"perCharacter":{},"familyName":"","localizedFamilyName":"","styleName":"Regular","pseudoVertical":{"op":"pseudoVertical","punctuation":"centered"},"s2t":{"op":"s2t","mode":"skipAmbiguous","taiwanVariants":false,"phrases":true}}"#,
        ]
        for content in unreadable {
            try Data(content.utf8).write(to: url)
            let editor = try #require(AppModel(root: root).editor(for: entry.id))
            #expect(editor.draft == RecipeDraft() && editor.previewOrientation == .horizontal)
            await editor.load()
            guard case .loaded = editor.loading else {
                Issue.record("the font did not open beside an unreadable draft: \(editor.loading)")
                return
            }
            editor.draft.familyName = "Ops Kai"
            editor.saveDraft()
            #expect(try JSONDecoder().decode(RecipeDraft.self, from: Data(contentsOf: url)) == editor.draft)
        }
    }

    /// A change waits a second for the next one before it is written; going
    /// to the background or quitting (`AppModel.saveDrafts`) writes it at
    /// once. A change left alone is written when its second is up.
    @Test func pendingChangeIsFlushed() async throws {
        let (app, entry, root) = try await makeApp()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = app.library.draftURL(for: entry)
        let editor = try #require(app.editor(for: entry.id))
        editor.draft.familyName = "Ops Kai"
        #expect(!FileManager.default.fileExists(atPath: url.path), "debounced: not written on the change itself")
        app.saveDrafts()
        #expect(try JSONDecoder().decode(RecipeDraft.self, from: Data(contentsOf: url)) == editor.draft)
        #expect(AppModel(root: root).editor(for: entry.id)?.draft.familyName == "Ops Kai")

        editor.draft.emboldenWeight = 7
        await editor.draftSettled()
        #expect(try JSONDecoder().decode(RecipeDraft.self, from: Data(contentsOf: url)).emboldenWeight == 7)
    }

    private func makeApp() async throws -> (AppModel, LibraryEntry, URL) {
        let root = try temporaryDirectory()
        let app = AppModel(root: root)
        try #require(app.startupProblem == nil, "\(app.startupProblem ?? "")")
        await app.importFonts([TestFonts.fixture("ops.ttf")])
        let entry = try #require(app.library.entries.first)
        return (app, entry, root)
    }
}
