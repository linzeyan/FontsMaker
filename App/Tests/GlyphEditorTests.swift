import FontsMakerKit
import Foundation
import Testing

/// The glyph editor (Phase 4f): what is drawn lands in the draft's outlines
/// step, undo and redo walk it back and forth, and the exported recipe
/// rebuilds with the CLI to the bytes the app wrote (product spec §4.9).
@MainActor
struct GlyphEditorTests {
    private func open() async throws -> (EditorModel, GlyphEditorModel, URL) {
        let (_, editor, root) = try await makeEditor([try TestFonts.reference("CrimsonText-Regular.ttf")])
        let model = try #require(GlyphEditorModel(editor: editor))
        return (editor, model, root)
    }

    /// Drags the first node of the working glyph by (dx, dy), as the canvas does.
    private func dragFirstNode(_ model: GlyphEditorModel, dx: Int, dy: Int) throws {
        let node = try #require(model.working?.contours.first?.first)
        let target = try #require(model.target(atX: Double(node.x), y: Double(node.y), radius: 1))
        #expect(target.part == .node)
        model.beginDrag(target)
        model.drag(to: OutlinePoint(x: node.x + dx / 2, y: node.y + dy / 2))
        model.drag(to: OutlinePoint(x: node.x + dx, y: node.y + dy))
        model.endDrag()
    }

    /// The grid offers what an English text needs, the font's own letters,
    /// figures and punctuation; it opens on the first of them.
    @Test func gridListsTheLatinCharactersOfTheFont() async throws {
        let (_, model, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        let titles = model.groups.map(\.title)
        #expect(titles.prefix(4) == ["大寫字母", "小寫字母", "數字", "標點與符號"])
        #expect(model.groups[2].characters == Array("0123456789"))
        #expect(model.selected == "A" && model.working == model.original && model.working != nil)
        #expect(model.editor.draft.outlines.isEmpty, "opening the editor changes nothing")
    }

    /// A drag is one change: the draft holds the glyph as drawn; undo puts
    /// the source back and leaves no outlines step; redo brings the drag
    /// back. Undo also goes back to the character it happened on.
    @Test func dragsUndoAndRedo() async throws {
        let (editor, model, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        model.select("a")
        let original = try #require(model.working)
        try dragFirstNode(model, dx: 30, dy: -20)
        let drawn = try #require(editor.draft.outlines["a"])
        #expect(drawn != original && drawn == model.working)
        #expect(drawn.contours[0][0].x == original.contours[0][0].x + 30)
        guard case .outlines(let step)? = editor.draft.steps.first else {
            Issue.record("the draft's first step is not outlines")
            return
        }
        #expect(step.glyphs == ["a": drawn])

        model.select("0")
        model.undo()
        #expect(model.selected == "a" && editor.draft.outlines.isEmpty && model.working == original)
        #expect(!editor.draft.steps.contains { $0.op == "outlines" })
        model.redo()
        #expect(editor.draft.outlines["a"] == drawn && model.working == drawn)

        // Back to the source by hand is no edit either.
        model.revert()
        #expect(editor.draft.outlines.isEmpty)
        #expect(model.canUndo)
    }

    /// A press a few units off a node grabs it without snapping it to the
    /// pointer: a click that does not move is no edit and no undo step, and
    /// a drag moves the node by exactly the pointer's travel.
    @Test func aClickIsNotAnEdit() async throws {
        let (editor, model, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        model.select("0")
        let original = try #require(model.working)
        let node = original.contours[0][0]
        let target = try #require(model.target(atX: Double(node.x + 4), y: Double(node.y - 3), radius: 9))
        model.beginDrag(target)
        model.drag(by: 0, 0)
        model.endDrag()
        #expect(model.working == original && !model.canUndo && editor.draft.outlines.isEmpty)

        model.beginDrag(target)
        model.drag(by: 7, 0)
        model.drag(by: 15, -2)
        model.endDrag()
        let moved = try #require(editor.draft.outlines["0"]?.contours[0][0])
        #expect(moved.x == node.x + 15 && moved.y == node.y - 2)
    }

    /// Side bearings as font editors have them: the left one moves the
    /// outline and the advance with it, so the right one stays.
    @Test func sideBearings() async throws {
        let (editor, model, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        model.select("n")
        let lsb = try #require(model.leftSideBearing)
        let rsb = try #require(model.rightSideBearing)
        let advance = try #require(model.working?.advance)
        model.setLeftSideBearing(lsb + 25)
        #expect(model.leftSideBearing == lsb + 25 && model.rightSideBearing == rsb)
        #expect(model.working?.advance == advance + 25)
        model.setRightSideBearing(rsb - 10)
        #expect(model.leftSideBearing == lsb + 25 && model.rightSideBearing == rsb - 10)
        #expect(editor.draft.outlines["n"]?.advance == advance + 15)
    }

    /// The pen adds a contour, closed on its first node and turned to cut a
    /// hole inside the o; a node can be added on a curve, made a corner and
    /// deleted, each one undo step.
    @Test func penAndNodeTools() async throws {
        let (editor, model, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        model.select("o")
        let contours = try #require(model.working?.contours.count)
        model.tool = .pen
        model.penPress(at: OutlinePoint(x: 220, y: 300), radius: 5)
        model.penPress(at: OutlinePoint(x: 260, y: 200), handle: OutlinePoint(x: 280, y: 200), radius: 5)
        model.penPress(at: OutlinePoint(x: 200, y: 200), radius: 5)
        #expect(model.pendingContour.count == 3)
        model.penPress(at: OutlinePoint(x: 221, y: 301), radius: 5)
        #expect(model.pendingContour.isEmpty && model.working?.contours.count == contours + 1)
        #expect(editor.draft.outlines["o"]?.contours.count == contours + 1)

        model.tool = .select
        let before = try #require(model.working)
        let segment = try #require(before.nearestSegment(toX: 0, y: 230))
        model.tool = .addPoint
        let nodes = before.nodeCount
        let x = 0.0
        model.addPoint(atX: x, y: 230, radius: segment.distance + 1)
        #expect(model.working?.nodeCount == nodes + 1 && model.selectedNode?.smooth == true)
        model.toggleSmooth()
        #expect(model.selectedNode?.smooth == false && model.selectedNode?.handleIn == nil)
        model.deleteSelection()
        #expect(model.working?.nodeCount == nodes)
        model.undo()
        model.undo()
        model.undo()
        #expect(model.working == before)
    }

    /// The whole way out: a redrawn a and 0, an advance changed, built,
    /// exported with its recipe; CoreText shows the page as the preview did,
    /// and the CLI's path rebuilds the recipe file to the same bytes.
    @Test func exportRebuildsWithTheCLI() async throws {
        let crimson = try TestFonts.reference("CrimsonText-Regular.ttf")
        let (editor, model, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        model.select("a")
        try dragFirstNode(model, dx: 0, dy: 40)
        model.select("0")
        try dragFirstNode(model, dx: -20, dy: 0)
        model.setRightSideBearing((model.rightSideBearing ?? 0) + 30)
        editor.draft.emboldenWeight = 12
        editor.draft.familyName = "Edited Serif"
        editor.sampleText = "a0 éa 0a"
        await editor.previewSettled()
        #expect(editor.previewProblem == nil)

        editor.startBuild()
        await editor.buildSettled()
        let outcome = try #require(editor.outcome, "build: \(editor.build)")
        #expect(outcome.recipe.steps.first?.op == "outlines" && outcome.recipe.steps.count == 2)
        let directory = root.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let check = try #require(
            await editor.writeExport(to: directory.appendingPathComponent(outcome.result.fileName)),
            "export: \(editor.exportProblem ?? "")")
        #expect(check.mismatches.isEmpty, "CoreText draws the redrawn glyphs as the preview did")
        try FileManager.default.copyItem(at: crimson, to: directory.appendingPathComponent(outcome.recipe.source.file))
        let rebuilt = try RecipeBuilder.build(recipeAt: check.recipeURL, options: BuildOptions())
        #expect(sha256Hex(rebuilt.fontData) == outcome.sha256, "CLI rebuild of the exported recipe is byte-identical")
        let recipe = try Recipe(contentsOf: check.recipeURL)
        guard case .outlines(let step)? = recipe.steps.first else { return }
        #expect(Set(step.glyphs.keys) == ["a", "0"])
    }

    /// Redrawn glyphs are part of the saved draft, coded as the recipe step.
    @Test func draftKeepsTheOutlines() async throws {
        let (editor, model, root) = try await open()
        defer { try? FileManager.default.removeItem(at: root) }
        model.select("e")
        try dragFirstNode(model, dx: 10, dy: 10)
        let data = try JSONEncoder().encode(editor.draft)
        let restored = try JSONDecoder().decode(RecipeDraft.self, from: data)
        #expect(restored == editor.draft && restored.outlines["e"] != nil)
        #expect(String(decoding: data, as: UTF8.self).contains(#""op":"outlines""#))
    }
}
