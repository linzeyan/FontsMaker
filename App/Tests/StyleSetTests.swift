import FontsMakerKit
import Foundation
import Testing

/// Regular, Italic, Bold and Bold Italic exported at once (technical design
/// §5.6): four recipes (D4), one family name, the RIBBI style names a reader
/// pairs `<b>` and `<i>` by, the weight class one step up, one line for all
/// four; and each exported recipe rebuilds to the exported bytes, as the
/// CLI does.
@MainActor
struct StyleSetTests {
    private func library(_ fonts: [URL]) async throws -> (LibraryModel, URL) {
        let root = try temporaryDirectory()
        let library = LibraryModel(root: root)
        await library.importFonts(fonts)
        try #require(library.problems.isEmpty, "import problems: \(library.problems)")
        return (library, root)
    }

    /// The four Crimson Text files, imported by hand: each style finds its
    /// file, whichever of them ② was on. Built with 加粗＋字寬＋字距＋行高,
    /// exported, read back by CoreText, and rebuilt from each recipe.
    @Test func crimsonTextFourStyles() async throws {
        let names = ["Regular", "Italic", "Bold", "BoldItalic"]
        let files = try names.map { try TestFonts.reference("CrimsonText-\($0).ttf") }
        let (library, root) = try await library(files)
        defer { try? FileManager.default.removeItem(at: root) }
        // From the Bold Italic's editor: the set is the family's, not the open font's.
        let entry = try #require(library.entries.first { $0.fileName == "CrimsonText-BoldItalic.ttf" })
        let set = StyleSetModel(entry: entry, library: library)
        await set.search()
        #expect(set.isAvailable)
        #expect(
            StyleRole.allCases.map { set.chosen[$0]?.fileName }
                == names.map { "CrimsonText-\($0).ttf" })
        #expect(set.problem == nil)

        var draft = RecipeDraft()
        draft.familyName = "CT Ebook"
        draft.emboldenWeight = RecipeDraft.defaultWeight
        draft.widen = true
        draft.tracking = 20
        draft.lineHeight = 1434
        set.startBuild(draft: draft, rightsConfirmed: false)
        #expect(set.isBuilding)
        #expect(await set.buildIfNeeded(draft: draft, rightsConfirmed: false))
        #expect(set.built.map(\.result.fileName)
            == ["CTEbook-Regular.ttf", "CTEbook-Italic.ttf", "CTEbook-Bold.ttf", "CTEbook-BoldItalic.ttf"])

        var lines = Set<[Int16]>()
        for (one, (bold, italic, weight)) in zip(
            set.built, [(false, false, 500), (false, true, 500), (true, false, 800), (true, true, 800)])
        {
            let font = try Font(data: one.result.fontData)
            #expect(font.names.contains { $0.nameID == 1 && $0.string == "CT Ebook" }, "one family for all four")
            #expect(font.names.contains { $0.nameID == 2 && $0.string == one.member.role.styleName })
            let selection = font.os2?.fsSelection ?? 0
            #expect((selection & 0x20 != 0) == bold && (selection & 1 != 0) == italic)
            #expect(font.os2?.weightClass == UInt16(weight), "\(one.member.role.styleName)")
            #expect(one.member.recipe.steps == draft.steps)
            lines.insert([font.hhea.ascender, font.hhea.descender, font.hhea.lineGap])
        }
        #expect(lines == [[1024, -410, 0]], "the line asked for, the same in all four")

        let export = root.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        let checks = try #require(await set.writeExport(to: export, text: "Sphinx of black quartz, judge my vow"))
        #expect(set.exported.isEmpty, "written and checked is not exported yet")
        #expect(checks.allSatisfy { $0.mismatches.isEmpty && $0.checkedGlyphs > 30 })
        #expect(checks.allSatisfy { $0.licenseURL == nil }, "imported files come with no license text")
        set.markExported(checks, to: .savedFile)
        #expect(set.exported.count == 4)

        for (check, source) in zip(checks, files) {
            let recipe = try Recipe(contentsOf: check.recipeURL)
            try? FileManager.default.copyItem(at: source, to: export.appendingPathComponent(recipe.source.file))
            let rebuilt = try RecipeBuilder.build(recipeAt: check.recipeURL, options: BuildOptions())
            #expect(sha256Hex(rebuilt.fontData) == check.sha256, "the CLI rebuilds \(check.fontURL.lastPathComponent)")
            #expect(sha256Hex(try Data(contentsOf: check.fontURL)) == check.sha256)
        }

        // A change after the build makes it stale; the same settings never rebuild.
        #expect(!set.isStale(draft: draft))
        draft.tracking = 10
        #expect(set.isStale(draft: draft))
    }

    /// A variable font is its own family: Literata's named instances give
    /// Regular (the default, no variation in the recipe) and Bold (wght 700);
    /// it has no italic file, so the italics are left out. A downloaded
    /// font's license text goes with the set once, named for the family.
    @Test func variableFontRegularAndBold() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryModel(root: root)
        let data = try Data(contentsOf: TestFonts.reference("Literata-VF.ttf"))
        await library.importDownloaded(
            [LibraryModel.IncomingFont(fileName: "Literata[opsz,wght].ttf", data: data)], licenseText: "OFL text\n")
        let entry = try #require(library.entries.first)
        let set = StyleSetModel(entry: entry, library: library)
        await set.search()
        #expect(set.chosen[.regular]?.variation == [:] && set.chosen[.bold]?.variation == ["wght": 700])
        #expect(set.chosen[.italic] == nil && set.chosen[.boldItalic] == nil && set.problem == nil)
        #expect(set.candidates(for: .bold).count > 2, "every named instance can be chosen")

        var draft = RecipeDraft()
        draft.familyName = "L Ebook"
        draft.emboldenWeight = 8
        #expect(await set.buildIfNeeded(draft: draft, rightsConfirmed: false))
        #expect(set.built.map { $0.member.recipe.output.weightClass } == [500, 800])
        let export = root.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        let checks = try #require(await set.writeExport(to: export, text: "Hamburgefonstiv"))
        #expect(checks.allSatisfy { $0.mismatches.isEmpty })
        let license = export.appendingPathComponent("LEbook-OFL.txt")
        #expect(checks.allSatisfy { $0.licenseURL == license })
        #expect(try String(contentsOf: license, encoding: .utf8) == "OFL text\n")
        #expect(StyleSetModel.files(of: checks).map(\.lastPathComponent)
            == ["LEbook-Regular.ttf", "LEbook-Regular.json", "LEbook-Bold.ttf", "LEbook-Bold.json", "LEbook-OFL.txt"])

        // The user picks another instance for Bold: the recipe follows.
        let black = try #require(set.candidates(for: .bold).first { $0.weight == 900 })
        set.chosen[.bold] = black
        #expect(set.isStale(draft: draft))
        #expect(try set.members(draft: draft)[1].recipe.source.variation == ["wght": 900])

        // A glyph redrawn on the Regular instance stays in the Regular: the
        // Bold is the same file, but its a is not the one that was drawn.
        draft.outlines = ["a": EditedGlyph(advance: 500, contours: [[OutlineNode(x: 0, y: 0), OutlineNode(x: 400, y: 0)]])]
        let members = try set.members(draft: draft)
        #expect(members.map { $0.recipe.steps.map(\.op) } == [["outlines", "embolden"], ["embolden"]])
        #expect(set.outlinesNote(draft: draft)?.contains("只用在 Regular") == true)
        draft.variation = ["wght": 900]
        #expect(try set.members(draft: draft).map { $0.recipe.steps.first?.op } == ["embolden", "outlines"])
    }

    /// The choice rules: italics only for the italic styles, nothing lighter
    /// than 600 as Bold, no font twice, one unitsPerEm.
    @Test func assignmentRules() {
        func source(_ name: String, _ weight: Int, italic: Bool = false, unitsPerEm: Int = 1000) -> StyleSource {
            StyleSource(
                entryID: name, fileName: name, faceIndex: 0, variation: [:], weight: weight, italic: italic,
                unitsPerEm: unitsPerEm, label: name)
        }
        let medium = StyleSetModel.assign([source("R", 400), source("M", 500)])
        #expect(medium[.regular]?.label == "R" && medium[.bold] == nil, "a Medium is no Bold")
        let full = StyleSetModel.assign([
            source("L", 300), source("R", 400), source("SB", 600), source("B", 700), source("I", 400, italic: true),
        ])
        #expect(full[.regular]?.label == "R" && full[.bold]?.label == "B" && full[.italic]?.label == "I")
        #expect(full[.boldItalic] == nil)
        #expect(StyleSetModel.assign([source("I", 400, italic: true)])[.regular] == nil)
    }
}
