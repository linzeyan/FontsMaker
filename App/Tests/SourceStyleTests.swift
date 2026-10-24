import FontsMakerKit
import Foundation
import Testing

/// Which font of a collection and which instance of a variable font the
/// user starts from: kept in the draft, written to the recipe's
/// `source.faceIndex` and `source.variation`, and rebuilt from the exported
/// recipe to the same bytes, as the CLI does (product spec §4.1, §4.9).
@MainActor
struct SourceStyleTests {
    /// Builds the editor's draft, exports it with its recipe, puts the source
    /// beside the recipe under the name the recipe gives it, and rebuilds
    /// from the recipe file (`RecipeBuilder.build(recipeAt:)`, the CLI's
    /// path). Returns the recipe and whether the bytes matched.
    private func exportAndRebuild(_ editor: EditorModel, source: URL, in root: URL) async throws -> (Recipe, Bool) {
        editor.startBuild()
        await editor.buildSettled()
        let outcome = try #require(editor.outcome, "build: \(editor.build)")
        let directory = root.appendingPathComponent("export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fontURL = directory.appendingPathComponent(outcome.result.fileName)
        let check = try #require(await editor.writeExport(to: fontURL), "export: \(editor.exportProblem ?? "")")
        #expect(check.mismatches.isEmpty, "the file shows what the preview of this instance showed")
        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(outcome.recipe.source.file))
        let rebuilt = try RecipeBuilder.build(recipeAt: check.recipeURL, options: BuildOptions(iHaveRights: true))
        return (try Recipe(contentsOf: check.recipeURL), sha256Hex(rebuilt.fontData) == outcome.sha256)
    }

    /// Dragging a weight slider reads instance after instance, on several
    /// threads at once. Each conversion's CoreText font must read bytes that
    /// are still alive: when they were released early, this crashed the test
    /// process on the iOS Simulator in 3 runs of 3 (a crash, not a failure).
    @Test func instancesReadInParallelDoNotCrash() async throws {
        let data = try Data(contentsOf: TestFonts.reference("Literata-VF.ttf"))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for lane in 0..<4 {
                group.addTask {
                    for i in 0..<60 {
                        let variation = i % 3 == 0 ? [:] : ["wght": Double(200 + (lane * 60 + i) * 3 % 700)]
                        _ = try Font(data: data, faceIndex: 0, variation: variation)
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    /// A named instance of Literata (opsz and wght): the preview and the
    /// build follow it, the recipe names only the axes away from the
    /// default, and the CLI rebuilds the export byte for byte. The default
    /// instance writes the recipe a never-touched font writes.
    @Test func variableInstanceGoesIntoTheRecipe() async throws {
        let literata = try TestFonts.reference("Literata-VF.ttf")
        let (_, editor, root) = try await makeEditor([literata])
        defer { try? FileManager.default.removeItem(at: root) }
        editor.sampleText = "Hamburgefonstiv 0123"
        await editor.previewSettled()
        let face = try #require(editor.face)
        #expect(face.axes.map(\.tag) == ["opsz", "wght"] && !face.namedInstances.isEmpty)
        let regularA = try #require(editor.previewPage?.positions.first?.glyph?.path)

        let bold = try #require(face.namedInstances.first { $0.name == "Bold" })
        editor.setAxes(bold.coordinates)
        #expect(editor.isApplyingStyle && !editor.canBuild, "no build of the instance being replaced")
        await editor.sourceSettled()
        await editor.previewSettled()
        let expected = bold.coordinates.filter { tag, value in face.axes.first { $0.tag == tag }?.defaultValue != value
        }
        #expect(editor.draft.variation == expected && expected["wght"] == 700)
        #expect(editor.sourceFont?.variation == expected && !editor.isApplyingStyle)
        #expect(editor.axisValues == bold.coordinates)
        #expect(editor.previewPage?.positions.first?.glyph?.path != regularA, "the page shows the Bold H")

        editor.draft.familyName = "Ebook Serif"
        let (recipe, same) = try await exportAndRebuild(editor, source: literata, in: root)
        #expect(recipe.source.variation == expected && recipe.source.faceIndex == 0)
        #expect(same, "CLI rebuild of the exported recipe is byte-identical")

        // The default instance is no choice at all.
        let regular = try #require(face.namedInstances.first { $0.name == "Regular" })
        editor.setAxes(regular.coordinates)
        await editor.sourceSettled()
        #expect(editor.draft.variation.isEmpty)
        let json = String(decoding: try editor.draft.recipe(source: editor.source).canonicalJSON(), as: UTF8.self)
        #expect(!json.contains("variation"))
    }

    /// The suggested style follows the instance chosen as it follows the
    /// effect cards: Literata's Bold emboldened builds as ExtraBold, weight
    /// class 800, not as the Medium a Regular would give. A style the user
    /// picked stays whatever instance comes next.
    @Test func suggestedStyleFollowsTheInstance() async throws {
        let (_, editor, root) = try await makeEditor([try TestFonts.reference("Literata-VF.ttf")])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(editor.draft.styleName == "Regular")
        editor.draft.emboldenWeight = RecipeDraft.defaultWeight
        #expect(editor.draft.styleName == "Medium")
        let face = try #require(editor.face)
        let bold = try #require(face.namedInstances.first { $0.name == "Bold" })
        editor.setAxes(bold.coordinates)
        await editor.sourceSettled()
        #expect(editor.draft.styleName == "ExtraBold")
        editor.startBuild()
        await editor.buildSettled()
        let built = try Font(data: try #require(editor.outcome, "build: \(editor.build)").result.fontData)
        #expect(built.os2?.weightClass == 800)
        #expect(built.names.contains { $0.nameID == 17 && $0.string == "ExtraBold" })

        editor.draft.styleName = "SemiBold"
        let regular = try #require(face.namedInstances.first { $0.name == "Regular" })
        editor.setAxes(regular.coordinates)
        await editor.sourceSettled()
        #expect(editor.draft.styleName == "SemiBold", "the user's style is theirs")
    }

    /// An italic keeps Italic in its suggested style, and 樣式 offers the
    /// italic styles: Crimson Text Italic emboldened is Medium Italic, with
    /// the italic bit set in the build.
    @Test func italicSourceKeepsItalic() async throws {
        let (_, editor, root) = try await makeEditor([try TestFonts.reference("CrimsonText-Italic.ttf")])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(editor.draft.styleName == "Italic" && editor.styleChoices.contains("Bold Italic"))
        #expect(!editor.styleChoices.contains("Bold"))
        editor.draft.emboldenWeight = RecipeDraft.defaultWeight
        #expect(editor.draft.styleName == "Medium Italic" && editor.nameProblem == nil)
        editor.startBuild()
        await editor.buildSettled()
        let built = try Font(data: try #require(editor.outcome, "build: \(editor.build)").result.fontData)
        #expect(built.os2?.weightClass == 500 && RecipeDraft.isItalic(built))
    }

    /// Dragging an axis slider sends a value per frame; only the last is
    /// read, and the build waits for it.
    @Test func sliderDragReadsTheLastValueOnly() async throws {
        let (_, editor, root) = try await makeEditor([TestFonts.fixture("variable.ttf")])
        defer { try? FileManager.default.removeItem(at: root) }
        for weight in stride(from: 410.0, through: 600, by: 10) {
            editor.setAxes(["wght": weight, "opsz": 12])
        }
        #expect(editor.isApplyingStyle)
        await editor.sourceSettled()
        #expect(editor.draft.variation == ["wght": 600] && editor.sourceFont?.variation == ["wght": 600])
        #expect(editor.axisValues == ["wght": 600, "opsz": 12])
    }

    /// The second font of a .ttc (a CFF face): read as that face, built from
    /// it, and rebuilt from the exported recipe to the same bytes. Another
    /// face starts at its own default instance.
    @Test func collectionFaceGoesIntoTheRecipe() async throws {
        let collection = TestFonts.fixture("collection.ttc")
        let (_, editor, root) = try await makeEditor([collection])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(editor.sourceFont?.faces.count == 2 && editor.face?.index == 0)
        editor.draft.variation = ["wght": 500]  // as if left from another face
        editor.chooseFace(1)
        #expect(editor.draft.variation.isEmpty)
        await editor.sourceSettled()
        let faceOne = try Font(data: Data(contentsOf: collection), faceIndex: 1)
        #expect(editor.sourceFont?.faceIndex == 1 && editor.sourceFont?.font.glyphs.count == faceOne.glyphs.count)
        #expect(editor.face?.fullName == "FM CFF Regular")

        editor.sampleText = "A"
        editor.draft.familyName = "Collection Test"
        editor.rightsConfirmed = true  // face 0, which the library lists, has no recognized license
        let (recipe, same) = try await exportAndRebuild(editor, source: collection, in: root)
        #expect(recipe.source.faceIndex == 1 && recipe.source.file == "collection.ttc")
        #expect(same, "CLI rebuild of the exported recipe is byte-identical")
    }

    /// The choice is part of the saved draft: a relaunch reads the same
    /// instance before the first preview.
    @Test func choiceSurvivesARelaunch() async throws {
        let (library, editor, root) = try await makeEditor([TestFonts.fixture("variable.ttf")])
        defer { try? FileManager.default.removeItem(at: root) }
        editor.setAxes(["wght": 700, "opsz": 30])
        await editor.sourceSettled()
        editor.saveDraft()
        await editor.draftSettled()

        let entry = try #require(library.entries.first)
        let reopened = EditorModel(
            entry: entry, fontURL: library.fontURL(for: entry), draftURL: library.draftURL(for: entry),
            licenseTextURL: library.licenseTextURL(for: entry))
        #expect(reopened.draft.variation == ["wght": 700, "opsz": 30])
        await reopened.load()
        #expect(reopened.sourceFont?.variation == ["wght": 700, "opsz": 30])
        #expect(reopened.source.variation == ["wght": 700, "opsz": 30])

        // Most fonts have one face and no axes; their drafts leave both out, as recipes do.
        let old =
            #"{"emboldenWeight":0,"familyName":"","localizedFamilyName":"","perCharacter":{},"skip":[],"styleName":"Regular"}"#
        let decoded = try JSONDecoder().decode(RecipeDraft.self, from: Data(old.utf8))
        #expect(decoded.faceIndex == 0 && decoded.variation.isEmpty)
    }
}
