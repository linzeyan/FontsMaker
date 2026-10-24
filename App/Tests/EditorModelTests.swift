import CoreText
import FontsMakerKit
import Foundation
import Testing

@MainActor
struct EditorModelTests {
    /// License gate (product spec §4.2): an unrecognized license builds only
    /// after the user confirms (and the confirmation is kept); a restricted
    /// font never builds.
    @Test func licenseGate() async throws {
        let (library, editor, root) = try await makeEditor([TestFonts.fixture("minimal.ttf")])
        defer { try? FileManager.default.removeItem(at: root) }
        editor.draft.familyName = "Ebook Kai"
        #expect(editor.nameProblem == nil)
        #expect(editor.licenseProblem != nil && !editor.canBuild)
        editor.rightsConfirmed = true
        #expect(editor.licenseProblem == nil && editor.canBuild)
        #expect(library.entries.first?.rightsConfirmed == true)

        let (_, restricted, restrictedRoot) = try await makeEditor([TestFonts.fixture("restricted.ttf")])
        defer { try? FileManager.default.removeItem(at: restrictedRoot) }
        restricted.draft.familyName = "Ebook Kai"
        restricted.rightsConfirmed = true
        #expect(restricted.licenseProblem != nil && !restricted.canBuild)
    }

    /// The live preview follows the controls: s2t makes 汉 show 漢's glyph,
    /// pseudoVertical then turns it as the build would. The page holds the
    /// characters the font shows, so with s2t it reads 漢漢A, not 汉漢A.
    @Test func previewFollowsTheControls() async throws {
        let (_, editor, root) = try await makeEditor([TestFonts.fixture("ops.ttf")])
        defer { try? FileManager.default.removeItem(at: root) }
        let font = try #require(editor.sourceFont?.font)
        let han = try font.path(ofGlyph: Int(font.characterMap.mappings[0x6F22]!))
        editor.sampleText = "汉漢A"
        await editor.previewSettled()
        #expect(editor.previewPage?.text == "汉漢A")
        #expect(editor.preview?.glyphs[0x6C49]?.glyphID == Int(font.characterMap.mappings[0x6C49]!))

        editor.draft.s2t = S2TOptions(mode: .single, taiwanVariants: false)
        await editor.previewSettled()
        let converted = try #require(editor.previewPage)
        #expect(converted.text == "漢漢A")
        #expect(converted.positions[0].glyph?.path == han)
        #expect(editor.preview?.processedGlyphs ?? .max < 10)

        editor.draft.pseudoVertical = PseudoVerticalOptions()
        await editor.previewSettled()
        let turned = try #require(editor.previewPage?.positions[0].glyph)
        #expect(turned.path != han)
        #expect(
            editor.preview?.glyphs[0x41]?.glyphID == Int(font.characterMap.mappings[0x41]!), "Latin stays sideways (R)")
        #expect(editor.previewPage?.positions.count == 3)
    }

    /// While a preview computes, the page says so and keeps the last one it
    /// had, never going blank (4e's VM screenshot m28 was an empty page with
    /// nothing to say why). Before the first preview there is no page, and
    /// the view has only the updating state to show.
    @Test func previewSaysItIsUpdatingAndKeepsTheLastPage() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryModel(root: root)
        let ids = await library.importFonts([TestFonts.fixture("ops.ttf")])
        let entry = try #require(library.entries.first { $0.id == ids.first })
        let editor = EditorModel(
            entry: entry, fontURL: library.fontURL(for: entry), draftURL: library.draftURL(for: entry),
            licenseTextURL: library.licenseTextURL(for: entry))
        #expect(editor.isUpdatingPreview && editor.previewPage == nil, "the font is still being read")
        await editor.load()
        #expect(editor.isUpdatingPreview && editor.previewPage == nil, "the first preview is computing")
        await editor.previewSettled()
        func outlines(_ page: PageText?) -> [CGPath] { page?.positions.compactMap { $0.glyph?.path } ?? [] }
        let first = outlines(editor.previewPage)
        #expect(!first.isEmpty && !editor.isUpdatingPreview)

        editor.draft.emboldenWeight = 8
        #expect(editor.isUpdatingPreview)
        #expect(outlines(editor.previewPage) == first, "the last page stays up while the next one computes")
        await editor.previewSettled()
        #expect(!editor.isUpdatingPreview && outlines(editor.previewPage) != first)

        // Superseded previews hand the state on rather than clearing it.
        editor.draft.emboldenWeight = 4
        editor.sampleText = "漢A"
        #expect(editor.isUpdatingPreview)
        await editor.previewSettled()
        #expect(!editor.isUpdatingPreview && editor.previewPage?.text == "漢A")
    }

    /// The OFL lets a modified font be passed on only with its license
    /// (condition 2): a font that came with its license text (a download)
    /// exports it beside the font and recipe, byte for byte as upstream
    /// wrote it, named for the font; one imported from a file has none to
    /// give, and the check says so rather than writing a stand-in.
    @Test func exportCarriesTheLicenseText() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryModel(root: root)
        let crimson = try Data(contentsOf: TestFonts.reference("CrimsonText-Regular.ttf"))
        let licenseText = "Copyright 2010 The Crimson Text Project Authors\n\nSIL OPEN FONT LICENSE Version 1.1\n"
        let ids = await library.importDownloaded(
            [LibraryModel.IncomingFont(fileName: "CrimsonText-Regular.ttf", data: crimson)], licenseText: licenseText)
        let entry = try #require(library.entries.first { $0.id == ids.first })
        let editor = EditorModel(
            entry: entry, fontURL: library.fontURL(for: entry), draftURL: library.draftURL(for: entry),
            licenseTextURL: library.licenseTextURL(for: entry))
        await editor.load()
        #expect(editor.hasLicenseText)
        editor.draft.emboldenWeight = RecipeDraft.defaultWeight
        editor.startBuild()
        await editor.buildSettled()
        let outcome = try #require(editor.outcome)
        #expect(outcome.result.fileName == "CTEbook-Medium.ttf")
        let export = root.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        let check = try #require(await editor.writeExport(to: export.appendingPathComponent(outcome.result.fileName)))
        #expect(check.licenseURL == export.appendingPathComponent("CTEbook-Medium-OFL.txt"))
        #expect(try Data(contentsOf: try #require(check.licenseURL)) == Data(licenseText.utf8))

        let (_, imported, importedRoot) = try await makeEditor([TestFonts.reference("CrimsonText-Regular.ttf")])
        defer { try? FileManager.default.removeItem(at: importedRoot) }
        #expect(!imported.hasLicenseText)
        imported.draft.emboldenWeight = RecipeDraft.defaultWeight
        imported.startBuild()
        await imported.buildSettled()
        let importedOutcome = try #require(imported.outcome)
        let check2 = try #require(
            await imported.writeExport(to: importedRoot.appendingPathComponent(importedOutcome.result.fileName)))
        #expect(check2.licenseURL == nil)
        let written = try FileManager.default.contentsOfDirectory(atPath: importedRoot.path).filter { $0.hasSuffix(".txt") }
        #expect(written.isEmpty)
    }

    /// A character the exported font lacks: CoreText draws it from a
    /// fallback font, which says nothing about this file and which a reader
    /// may not have. The export page shows the file's .notdef there, as the
    /// preview does, so the position matches; another font's glyph ID read as
    /// one of this file's would not.
    @Test func exportCheckTreatsFallbackAsMissing() async throws {
        let (_, editor, root) = try await makeEditor([TestFonts.fixture("ops.ttf")])
        defer { try? FileManager.default.removeItem(at: root) }
        let font = try #require(editor.sourceFont?.font)
        #expect(font.characterMap.mappings[0x5B57] == nil, "ops.ttf has no 字")
        editor.draft.familyName = "Ebook Kai"
        editor.draft.emboldenWeight = 6
        editor.sampleText = "汉字A"
        editor.startBuild()
        await editor.buildSettled()
        let outcome = try #require(editor.outcome)
        let fontURL = root.appendingPathComponent(outcome.result.fileName)
        let check = try #require(await editor.writeExport(to: fontURL))
        #expect(check.checkedGlyphs == 3 && check.mismatches.isEmpty)

        let descriptor = try #require(CTFontManagerCreateFontDescriptorFromData(try Data(contentsOf: fontURL) as CFData))
        let coreText = CTFontCreateWithFontDescriptor(descriptor, CGFloat(font.unitsPerEm), nil)
        let notdef = try #require(CTFontCreatePathForGlyph(coreText, 0, nil))
        #expect(!notdef.isEmpty, "a visible .notdef, so drawing it can be told from drawing nothing")
        #expect(check.page.positions[1].glyph?.path == notdef)
    }

    /// The page orientation follows the recipe rather than an app-wide
    /// setting: a font without pseudoVertical is never shown sideways because
    /// another one was. The user may still flip it, until pseudoVertical is
    /// toggled; the export page follows the exported recipe (see the
    /// GuanKiapTsingKhai tests).
    @Test func orientationFollowsTheDraft() async throws {
        let (_, editor, root) = try await makeEditor([TestFonts.fixture("ops.ttf")])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(editor.previewOrientation == .horizontal && editor.exportOrientation == .horizontal)
        editor.draft.pseudoVertical = PseudoVerticalOptions()
        #expect(editor.previewOrientation == .readerRotated)

        editor.previewOrientation = .horizontal
        editor.draft.emboldenWeight = 4
        editor.draft.familyName = "Ops Vertical"
        #expect(editor.previewOrientation == .horizontal, "the user's flip survives other changes")
        editor.draft.pseudoVertical = nil
        #expect(editor.previewOrientation == .horizontal)
        editor.draft.pseudoVertical = PseudoVerticalOptions()
        #expect(editor.previewOrientation == .readerRotated)
        editor.draft.pseudoVertical = nil
        editor.draft.s2t = RecipeDraft.defaultS2T
        #expect(editor.previewOrientation == .horizontal)

        // An editor with a fresh draft (another library) starts upright
        // whatever this one showed; a relaunch follows the saved draft
        // (DraftPersistenceTests).
        editor.previewOrientation = .readerRotated
        let (_, again, againRoot) = try await makeEditor([TestFonts.fixture("ops.ttf")])
        defer { try? FileManager.default.removeItem(at: againRoot) }
        #expect(again.previewOrientation == .horizontal)
    }

    /// 簡體書顯示繁體 as its card switches it on (phrases on) on GuanKiapTsingKhai with the default
    /// sample text. The preview cannot shape, so it draws the text converted
    /// as the built font shows it: 里程碑 stays 里程碑 with phrases and
    /// becomes 裡程碑 character by character. The export page is CoreText's
    /// shaping of the exported file: at 里 it shows the phrase rule's glyph
    /// rather than the cmap's 裡, and every position matches the preview.
    /// Against the character-level preview, the counter reports exactly the
    /// positions the rules change: no false match, no false mismatch.
    @Test func phrasesInPreviewAndExportOnGuanKiap() async throws {
        let sourceURL = try TestFonts.reference("GuanKiapTsingKhai.ttf")
        let (_, editor, root) = try await makeEditor([sourceURL])
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try #require(editor.sourceFont?.font)
        let text = editor.sampleText
        #expect(text == editor.defaultSampleText && text.contains("It was the best of times"))
        editor.draft.s2t = RecipeDraft.defaultS2T
        editor.draft.familyName = "Trad Kai"
        await editor.previewSettled()
        #expect(!editor.preparingPhraseRules && editor.previewProblem == nil)
        let phrased = try #require(editor.previewPage?.text)
        #expect(phrased.contains("簡體測試：這個國家的發展為後來里程碑。"))

        editor.draft.s2t?.phrases = false
        await editor.previewSettled()
        let perCharacter = try #require(editor.previewPage?.text)
        #expect(perCharacter.contains("簡體測試：這個國家的發展為後來裡程碑。"))
        editor.draft.s2t?.phrases = true
        await editor.previewSettled()
        #expect(editor.previewPage?.text == phrased)

        editor.startBuild()
        await editor.buildSettled()
        let outcome = try #require(editor.outcome)
        let s2tReport = outcome.result.reports.lazy.compactMap { report -> S2TReport? in
            if case .s2t(_, let report) = report { report } else { nil }
        }.first
        #expect((s2tReport?.phrases?.activeRules ?? 0) > 9000)

        let exportDirectory = root.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let fontURL = exportDirectory.appendingPathComponent(outcome.result.fileName)
        let check = try #require(await editor.writeExport(to: fontURL))
        #expect(editor.exportCheck == nil, "written and checked is not exported: on iOS the user may still cancel")
        let scalars = Array(text.unicodeScalars)
        #expect(check.checkedGlyphs == scalars.count { $0 != "\n" } && check.mismatches.isEmpty)
        #expect(check.page.text == phrased, "CoreText shows what the preview showed, 里程碑 included")

        let index = phrased.unicodeScalars.distance(
            from: phrased.unicodeScalars.startIndex, to: try #require(phrased.unicodeScalars.firstIndex(of: "里")))
        let data = try Data(contentsOf: fontURL)
        let descriptor = try #require(CTFontManagerCreateFontDescriptorFromData(data as CFData))
        let coreText = CTFontCreateWithFontDescriptor(descriptor, CGFloat(source.unitsPerEm), nil)
        var units = Array("里".utf16)
        var cmapGlyph: CGGlyph = 0
        CTFontGetGlyphsForCharacters(coreText, &units, &cmapGlyph, 1)
        let ruleGlyph = CGGlyph(source.characterMap.mappings[0x91CC]!)
        #expect(cmapGlyph == CGGlyph(source.characterMap.mappings[0x88E1]!), "the cmap shows 裡 for 里")
        let shown = try #require(check.page.positions[index].glyph?.path)
        #expect(shown == CTFontCreatePathForGlyph(coreText, ruleGlyph, nil), "the rule's 里")
        #expect(shown != CTFontCreatePathForGlyph(coreText, cmapGlyph, nil))

        let characterLevel = S2TOptions(taiwanVariants: true)
        let expected = try PageText.preview(
            of: text, steps: [.s2t(characterLevel)], font: source,
            converter: S2TTextConverter(font: source, options: characterLevel)
        ).page
        let differing = zip(phrased.unicodeScalars, perCharacter.unicodeScalars).enumerated().filter {
            $0.element.0 != $0.element.1
        }.map(\.offset)
        #expect(differing.contains(index))
        let strict = try ExportCheck.run(
            fontURL: fontURL, recipeURL: check.recipeURL, sha256: check.sha256, recipe: outcome.recipe, text: text,
            expected: expected)
        #expect(strict.mismatches == differing)
        #expect(strict.page.positions[index].scalar == "\u{FFFD}", "what a mismatched position shows is unknown")

        editor.markExported(check, to: .savedFile)
        #expect(editor.exportCheck?.sha256 == outcome.sha256 && editor.exportOrientation == .horizontal)
    }

    /// Cancel reaches the engine's workers and ends the build as cancelled,
    /// not as a failure.
    @Test func cancelStopsTheBuild() async throws {
        let (_, editor, root) = try await makeEditor([try TestFonts.reference("GuanKiapTsingKhai.ttf")])
        defer { try? FileManager.default.removeItem(at: root) }
        editor.draft.emboldenWeight = RecipeDraft.defaultWeight
        editor.draft.familyName = "Ebook Kai"
        editor.startBuild()
        #expect(editor.isBuilding)
        editor.cancelBuild()
        await editor.buildSettled()
        guard case .cancelled = editor.build else {
            Issue.record("expected cancelled, got \(editor.build)")
            return
        }
        #expect(editor.canBuild, "a cancelled build can be started again")
    }

    /// S1/S5 on GuanKiapTsingKhai with 加粗＋偽直排: the build runs off the
    /// main actor and reports progress; review decisions go into the recipe
    /// and survive the rebuild; export writes the font and the canonical
    /// recipe, CoreText loads the file, and building the exported recipe
    /// again gives the same bytes (what the CLI does with it).
    @Test func buildReviewAndExportOnGuanKiap() async throws {
        let sourceURL = try TestFonts.reference("GuanKiapTsingKhai.ttf")
        let (_, editor, root) = try await makeEditor([sourceURL])
        defer { try? FileManager.default.removeItem(at: root) }
        editor.draft.emboldenWeight = RecipeDraft.defaultWeight
        editor.draft.pseudoVertical = PseudoVerticalOptions()
        editor.draft.familyName = "Ebook Kai"
        editor.draft.localizedFamilyName = "電子書楷"
        #expect(editor.canBuild)

        editor.startBuild()
        var sawProgress = false
        while editor.isBuilding {
            if case .running(let completed, let total) = editor.build, completed > 0, total > 0 { sawProgress = true }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(sawProgress, "progress reached the main actor while the build ran")
        let first = try #require(editor.outcome)
        let report = try #require(first.emboldenReport)
        #expect(report.count(of: .a) > 0 && report.count(of: .b) > 0)
        #expect(editor.review.items.count == report.count(of: .a) + report.count(of: .b))
        #expect(editor.review.items.first?.firstGrade == .a)

        // Decide: the worst glyph is not emboldened, the next encoded one gets half the weight.
        let skipped = try #require(editor.review.items.first { !$0.characters.isEmpty })
        let lighter = try #require(editor.review.items.first { !$0.characters.isEmpty && $0.id != skipped.id })
        editor.setDecision(.skip, for: skipped)
        editor.setDecision(.weight(6), for: lighter)
        #expect(editor.draft.skip == [skipped.characters[0]])
        #expect(editor.draft.perCharacter == [lighter.characters[0]: 6])
        #expect(editor.outcomeIsStale)

        editor.startBuild()
        await editor.buildSettled()
        let second = try #require(editor.outcome)
        #expect(!editor.outcomeIsStale)
        guard case .embolden(let step) = second.recipe.steps.first else {
            Issue.record("embolden must be the first step")
            return
        }
        #expect(step.skip == [skipped.characters[0]] && step.perCharacter[lighter.characters[0]]?.weight == 6)
        let skippedNow = try #require(editor.review.items.first { $0.id == skipped.id })
        #expect(skippedNow.grade == nil, "a skipped glyph stays listed, as not emboldened")
        #expect(editor.review.items.first { $0.id == lighter.id }?.weight == 6)
        #expect(editor.decision(for: skippedNow) == .skip)

        let exportDirectory = root.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let fontURL = exportDirectory.appendingPathComponent(second.result.fileName)
        #expect(second.result.fileName == "EbookKai-Medium.ttf")
        let check = try #require(await editor.writeExport(to: fontURL))
        #expect(editor.exportProblem == nil && editor.exportCheck == nil)
        editor.markExported(check, to: .savedFile)
        #expect(editor.exportCheck != nil && editor.exportOrientation == .readerRotated)
        // Every position of the default sample text, embolden and turned
        // glyphs included, as CoreText shapes the file.
        #expect(check.checkedGlyphs > 20 && check.mismatches.isEmpty)
        #expect(check.page.text == editor.sampleText)
        // CoreText's natural line for the file is its hhea, the line the
        // preview lays out by (CoreText returns it with float noise, ~0.006 u).
        let hhea = try Font(data: second.result.fontData).hhea
        #expect(abs(check.page.ascender - CGFloat(hhea.ascender)) < 0.05)
        #expect(abs(check.page.descender - CGFloat(hhea.descender)) < 0.05)
        #expect(abs(check.page.lineGap - CGFloat(hhea.lineGap)) < 0.05)
        #expect(sha256Hex(try Data(contentsOf: fontURL)) == second.sha256)
        let recipeURL = exportDirectory.appendingPathComponent("EbookKai-Medium.json")
        #expect(check.recipeURL == recipeURL)
        let written = try Data(contentsOf: recipeURL)
        #expect(written == (try second.recipe.canonicalJSON()))
        #expect(try Recipe(json: written).source.file == "GuanKiapTsingKhai.ttf")

        try FileManager.default.copyItem(
            at: sourceURL, to: exportDirectory.appendingPathComponent("GuanKiapTsingKhai.ttf"))
        let rebuilt = try RecipeBuilder.build(recipeAt: recipeURL, options: BuildOptions())
        #expect(sha256Hex(rebuilt.fontData) == second.sha256)
    }

    /// A font opened for the first time is named for the user, and the name
    /// follows the effect cards (so 匯出 needs no typing), each suggestion
    /// passing the engine's naming rules for that font. Once the user types
    /// a name or picks a style, switching effects never replaces it.
    @Test func suggestedNamesFollowTheEffectsUntilEdited() async throws {
        let (_, editor, root) = try await makeEditor([try TestFonts.reference("GuanKiapTsingKhai.ttf")])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(editor.entry.familyName == "GuanKiapTsingKhai")
        #expect(editor.draft.familyName == "GKTK Custom" && editor.draft.styleName == "Regular")
        editor.draft.emboldenWeight = RecipeDraft.defaultWeight
        #expect(editor.draft.familyName == "GKTK Ebook" && editor.draft.styleName == "Medium")
        #expect(editor.nameProblem == nil)
        editor.draft.emboldenWeight = 20
        #expect(editor.draft.familyName == "GKTK Ebook", "the slider does not rename")
        editor.draft.pseudoVertical = PseudoVerticalOptions()
        #expect(editor.draft.familyName == "GKTK Ebook V" && editor.nameProblem == nil)
        editor.draft.s2t = RecipeDraft.defaultS2T
        #expect(editor.draft.familyName == "GKTK Ebook V TC" && editor.nameProblem == nil)

        editor.draft.familyName = "Moon Kai"
        editor.draft.styleName = "SemiBold"
        editor.draft.pseudoVertical = nil
        editor.draft.emboldenWeight = 0
        #expect(editor.draft.familyName == "Moon Kai" && editor.draft.styleName == "SemiBold")

        // Another font, another source name: ops.ttf is "FM Ops" (運算測試).
        let (_, ops, opsRoot) = try await makeEditor([TestFonts.fixture("ops.ttf")])
        defer { try? FileManager.default.removeItem(at: opsRoot) }
        ops.draft.s2t = RecipeDraft.defaultS2T
        #expect(ops.draft.familyName == "FO TC" && ops.nameProblem == nil)
        ops.draft.familyName = ""
        ops.draft.pseudoVertical = PseudoVerticalOptions()
        #expect(ops.draft.familyName == "FO V TC", "an emptied name takes the suggestion again")
    }

    /// 做出字型並存檔 builds only when the settings were never built: the same
    /// settings export the same build again, and any change, a review
    /// decision included, builds anew.
    @Test func rebuildsOnlyWhenTheSettingsChanged() async throws {
        let (_, editor, root) = try await makeEditor([TestFonts.fixture("ops.ttf")])
        defer { try? FileManager.default.removeItem(at: root) }
        editor.draft.emboldenWeight = 6
        #expect(editor.startBuildIfNeeded())
        await editor.buildSettled()
        let first = try #require(editor.outcome)
        #expect(!editor.startBuildIfNeeded())
        #expect(!editor.isBuilding && editor.outcome?.seconds == first.seconds && editor.outcome?.sha256 == first.sha256)

        editor.draft.skip = ["漢"]
        #expect(editor.startBuildIfNeeded(), "a decision changes the recipe")
        await editor.buildSettled()
        let second = try #require(editor.outcome)
        #expect(second.sha256 != first.sha256)
        editor.draft.familyName = "Ops Kai"
        #expect(editor.startBuildIfNeeded(), "the name is in the font too")
        await editor.buildSettled()
        #expect(!editor.startBuildIfNeeded())
    }
}
