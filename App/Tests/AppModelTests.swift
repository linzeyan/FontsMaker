import FontsMakerKit
import Foundation
import Testing

/// Where the flow starts and what it remembers across launches. A relaunch
/// here is a new `AppModel` on the same library and defaults.
@MainActor
struct AppModelTests {
    private func makeDefaults() -> UserDefaults {
        let name = "fontsmaker-app-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// A card's 「到目錄挑…」 takes the user to ① to download a second font;
    /// ① then offers the way back to the font and step they left, the step
    /// risk review's sheet is on (③) as well as the replace card's (②). It
    /// goes once ① is left, by it or otherwise.
    @Test func browsingTheCatalogFromACardLeadsBack() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(root: root, defaults: makeDefaults())
        await app.importFonts([TestFonts.fixture("ops.ttf"), TestFonts.fixture("minimal.ttf")])
        let ops = try #require(app.library.entries.first { $0.fileName == "ops.ttf" })
        let minimal = try #require(app.library.entries.first { $0.fileName == "minimal.ttf" })
        app.open(ops.id)
        let browse = try #require(app.currentEditor?.browseCatalog)
        #expect(app.catalogReturn == nil, "opening ① by itself offers no way back")

        browse(.latin)
        #expect(app.step == .pick && app.catalogReturn == .adjust)
        app.returnFromCatalog()
        #expect(app.step == .adjust && app.currentFontID == ops.id && app.catalogReturn == nil)

        app.go(to: .export)
        browse(.chinese)
        app.returnFromCatalog()
        #expect(app.step == .export, "back to ③, where risk review browsed from")

        browse(.latin)
        app.open(minimal.id)
        #expect(app.catalogReturn == nil, "another font opened from ① leaves nothing to go back to")
    }

    /// With 「每次都分三步走」 on (the default), every launch starts at ①.
    /// Turned off, the user works on one font at a time, and the app opens
    /// straight on the last one, on the one editing screen; ① is still there
    /// through 換字型.
    @Test func withoutTheStepsTheAppReopensTheLastFont() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = makeDefaults()
        let app = AppModel(root: root, defaults: defaults)
        #expect(app.threeSteps && app.step == .pick && app.currentFontID == nil)
        await app.importFonts([TestFonts.fixture("ops.ttf"), TestFonts.fixture("minimal.ttf")])
        let minimal = try #require(app.library.entries.first { $0.fileName == "minimal.ttf" })
        #expect(app.step == .adjust && app.currentFontID == minimal.id, "an import opens the last file given")
        let ops = try #require(app.library.entries.first { $0.fileName == "ops.ttf" })
        app.goBack()
        #expect(app.step == .pick)
        app.open(ops.id)

        let guided = AppModel(root: root, defaults: defaults)
        #expect(guided.step == .pick && guided.currentFontID == nil)

        defaults.set(false, forKey: AppModel.Key.threeSteps)
        let relaunched = AppModel(root: root, defaults: defaults)
        #expect(relaunched.step == .adjust && relaunched.currentFontID == ops.id)
        #expect(relaunched.currentEditor?.entry.id == ops.id)
        relaunched.go(to: .export)
        #expect(relaunched.step == .adjust, "② and ③ are one screen")
        relaunched.goBack()
        #expect(relaunched.step == .pick)
        relaunched.goForward()
        #expect(relaunched.step == .adjust)
    }

    /// A font whose license forbids changes (product spec §4.2) is marked
    /// in ① and never opens, not by a tap, an import or a relaunch.
    @Test func restrictedFontNeverGetsPastPick() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppModel.Key.threeSteps)
        let app = AppModel(root: root, defaults: defaults)
        await app.importFonts([TestFonts.fixture("restricted.ttf")])
        let entry = try #require(app.library.entries.first)
        #expect(entry.license == .restricted)
        #expect(app.step == .pick && app.currentFontID == nil && app.refusedFont == entry)
        #expect(!app.canGo(to: .adjust))
        app.go(to: .adjust)
        #expect(app.step == .pick)

        defaults.set(entry.id, forKey: AppModel.Key.lastFont)
        #expect(AppModel(root: root, defaults: defaults).step == .pick)
    }

    /// 「要放到哪裡讀？」 is asked once: the choice comes back on the next
    /// launch. Only macOS offers 這台 Mac, so a stored choice the platform
    /// does not offer is no choice.
    @Test func installTargetIsRemembered() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = makeDefaults()
        let app = AppModel(root: root, defaults: defaults)
        #expect(app.installTarget == nil)
        app.installTarget = .kobo
        #expect(AppModel(root: root, defaults: defaults).installTarget == .kobo)

        defaults.set(InstallTarget.mac.rawValue, forKey: AppModel.Key.installTarget)
        #if os(macOS)
            #expect(AppModel(root: root, defaults: defaults).installTarget == .mac)
            #expect(InstallTarget.available.contains(.mac))
        #else
            #expect(AppModel(root: root, defaults: defaults).installTarget == nil)
            #expect(!InstallTarget.available.contains(.mac))
        #endif
    }

    /// A rename shows at once where ② and ③ title the font, and nowhere
    /// else: the export names are suggested from the font's own family, the
    /// recipe names the file it was imported as.
    @Test func renameChangesOnlyTheNameShown() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(root: root, defaults: makeDefaults())
        await app.importFonts([TestFonts.fixture("ops.ttf")])
        let original = try #require(app.currentEntry)
        let opened = try #require(app.currentEditor)
        // Latin, so a suggestion taken from it would differ (initials RN).
        #expect(app.rename(original.id, to: "Reading Night"))
        #expect(opened.entry.displayName == "Reading Night", "the open editor's title follows")
        #expect(!app.rename(original.id, to: "  "))
        #expect(opened.entry.displayName == "Reading Night")

        await opened.load()
        #expect(!opened.draft.familyName.hasPrefix("RN"), "suggested from \(opened.draft.familyName)")
        let reference = EditorModel(
            entry: original, fontURL: app.library.fontURL(for: original),
            draftURL: root.appendingPathComponent("reference-draft.json"),
            licenseTextURL: app.library.licenseTextURL(for: original))
        await reference.load()
        #expect(!opened.draft.familyName.isEmpty && opened.draft.familyName == reference.draft.familyName)
        #expect(opened.source == reference.source && opened.source.file == "ops.ttf")
    }

    /// Deleting the font being edited closes it: ① shows, ② and ③ cannot
    /// be reached, and with the three steps off the next launch does not
    /// look for it. A change still waiting for its debounced write does not
    /// bring the draft back.
    @Test func removingTheOpenFontGoesBackToPick() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = makeDefaults()
        let app = AppModel(root: root, defaults: defaults)
        await app.importFonts([TestFonts.fixture("ops.ttf")])
        let entry = try #require(app.currentEntry)
        let editor = try #require(app.currentEditor)
        await editor.load()
        editor.draft.emboldenWeight = 12
        #expect(app.step == .adjust)

        try app.remove(entry.id)
        #expect(app.step == .pick && app.currentFontID == nil && app.currentEditor == nil)
        #expect(!app.canGo(to: .adjust) && !app.canGo(to: .export))
        #expect(app.library.entries.isEmpty)
        // Past the draft's 1 s debounce.
        try await Task.sleep(for: .milliseconds(1_500))
        #expect(!FileManager.default.fileExists(atPath: app.library.draftURL(for: entry).path))

        defaults.set(false, forKey: AppModel.Key.threeSteps)
        let relaunched = AppModel(root: root, defaults: defaults)
        #expect(relaunched.step == .pick && relaunched.currentFontID == nil)
        #expect(defaults.string(forKey: AppModel.Key.lastFont) == nil)
    }

    /// A font another draft takes its Latin letters from can be deleted:
    /// that draft keeps its choice, says the font is missing and does not
    /// build, in the editor open now and after a relaunch; it still opens.
    @Test func removingASecondFontLeavesItsDraftsReadable() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = makeDefaults()
        let app = AppModel(root: root, defaults: defaults)
        await app.importFonts([try TestFonts.reference("GuanKiapTsingKhai.ttf"), try TestFonts.reference("Literata-VF.ttf")])
        let guanKiap = try #require(app.library.entries.first { $0.fileName == "GuanKiapTsingKhai.ttf" })
        let literata = try #require(app.library.entries.first { $0.fileName == "Literata-VF.ttf" })
        app.open(guanKiap.id)
        let editor = try #require(app.currentEditor)
        await editor.load()
        let chosen = RecipeDraft.Replacement(sha256: literata.id, fileName: literata.fileName)
        editor.draft.replacement = chosen
        await editor.secondFontsSettled()
        #expect(editor.replacementFont?.id == literata.id && editor.replacementProblem == nil)
        editor.saveDraft()

        try app.remove(literata.id)
        await editor.secondFontsSettled()
        #expect(editor.draft.replacement == chosen, "the choice stays for the user to change")
        #expect(editor.replacementFont == nil && editor.replacementProblem?.contains("Literata-VF.ttf") == true)
        #expect(!editor.canBuild)
        #expect(app.currentFontID == guanKiap.id && app.step == .adjust, "only the deleted font closes")

        let relaunched = AppModel(root: root, defaults: defaults)
        let reopened = try #require(relaunched.editor(for: guanKiap.id))
        #expect(reopened.draft.replacement == chosen)
        await reopened.load()
        await reopened.secondFontsSettled()
        guard case .loaded = reopened.loading else {
            Issue.record("the draft no longer opens: \(reopened.loading)")
            return
        }
        #expect(reopened.replacementProblem?.contains("Literata-VF.ttf") == true && !reopened.canBuild)
    }

    /// ⌘E from ② goes to ③ and leaves the export for its controls to run.
    @Test func exportShortcutGoesToExport() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(root: root, defaults: makeDefaults())
        app.requestExport()
        #expect(app.step == .pick, "nothing to export before a font is picked")
        await app.importFonts([TestFonts.fixture("ops.ttf")])
        app.requestExport()
        #expect(app.step == .export && app.currentEditor?.exportRequest == .export)
    }
}
