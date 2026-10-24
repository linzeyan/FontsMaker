import Foundation
import Observation

/// The three steps of the flow (plan, Phase 4e). With 「每次都分三步走」 off,
/// `.adjust` and `.export` are one editing screen.
enum FlowStep: Int, CaseIterable, Comparable, Sendable {
    case pick
    case adjust
    case export

    var title: String {
        switch self {
        case .pick: "挑字型"
        case .adjust: "調整"
        case .export: "匯出並安裝"
        }
    }

    static func < (lhs: FlowStep, rhs: FlowStep) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// App-wide state: the library, where the user is in the flow, and one
/// editor per font opened this session (so switching fonts keeps each one's
/// work; the drafts also outlive the session, see `EditorModel`).
@MainActor @Observable
final class AppModel {
    /// UserDefaults keys; the views read the same keys through @AppStorage.
    enum Key {
        /// 「每次都分三步走」, on unless turned off.
        static let threeSteps = "flow.threeSteps"
        static let lastFont = "flow.lastFont"
        static let installTarget = "export.installTarget"
        /// ①'s 中文／English tab, where it was left.
        static let catalogScript = "pick.catalogScript"
    }

    let library: LibraryModel
    let downloads: FontDownloads
    #if os(macOS)
        let installed: InstalledFonts
    #endif
    /// Set when the app cannot work as intended; shown instead of failing silently.
    let startupProblem: String?
    private let defaults: UserDefaults

    private(set) var step = FlowStep.pick
    /// The font being adjusted and exported; nil until one is picked.
    private(set) var currentFontID: LibraryEntry.ID?
    /// 「要放到哪裡讀？」, remembered for the next export; nil until chosen.
    var installTarget: InstallTarget? {
        didSet { defaults.set(installTarget?.rawValue, forKey: Key.installTarget) }
    }
    /// ⌘O asks the window to show its file importer.
    var importRequested = false
    #if os(macOS)
        /// 管理已安裝的字型…: ① scrolls to its list of them.
        var showsInstalledRequested = false
    #endif
    /// A font the user tried to open that its license forbids changing.
    var refusedFont: LibraryEntry?
    /// The step a card's 「到目錄挑…」 left for ①: ① offers the way back to
    /// it, since downloading a font there leaves the user nowhere near the
    /// font they were adjusting. Gone once ① is left.
    private(set) var catalogReturn: FlowStep?
    // Created while a view body asks for it, so it must not be observed.
    @ObservationIgnored private var editors: [LibraryEntry.ID: EditorModel] = [:]
    @ObservationIgnored private var styleSets: [LibraryEntry.ID: StyleSetModel] = [:]

    init(root: URL? = nil, defaults: UserDefaults = .standard, fetcher: Fetcher = Fetcher()) {
        self.defaults = defaults
        var problems: [String] = []
        let libraryRoot: URL
        do {
            libraryRoot = try root ?? LibraryModel.defaultRoot()
        } catch {
            libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("FontsMaker")
            problems.append("找不到 Application Support，字型庫暫存在 \(libraryRoot.path)：\(error.localizedDescription)")
        }
        library = LibraryModel(root: libraryRoot)
        downloads = FontDownloads(library: library, fetcher: fetcher)
        #if os(macOS)
            installed = InstalledFonts(directory: libraryRoot.appendingPathComponent("Installed", isDirectory: true))
        #endif
        startupProblem = problems.isEmpty ? nil : problems.joined(separator: "\n")
        installTarget = defaults.string(forKey: Key.installTarget).flatMap(InstallTarget.init(rawValue:))
            .flatMap { InstallTarget.available.contains($0) ? $0 : nil }
        // Someone who turned the steps off works on one font at a time:
        // the app opens on it. Everyone else starts by picking.
        if !threeSteps, let last = defaults.string(forKey: Key.lastFont), canOpen(last) {
            currentFontID = last
            step = .adjust
        }
        // A link's fonts open in ② like an imported file's; a catalog
        // download does not, as it may finish while the user looks elsewhere.
        downloads.onImported = { [weak self] ids in
            if let last = ids.last { self?.open(last) }
        }
    }

    var threeSteps: Bool {
        defaults.object(forKey: Key.threeSteps) as? Bool ?? true
    }

    var currentEntry: LibraryEntry? {
        currentFontID.flatMap { id in library.entries.first { $0.id == id } }
    }

    var currentEditor: EditorModel? {
        currentFontID.flatMap(editor(for:))
    }

    func editor(for id: LibraryEntry.ID) -> EditorModel? {
        if let editor = editors[id] { return editor }
        guard let entry = library.entries.first(where: { $0.id == id }) else { return nil }
        let library = library
        let editor = EditorModel(
            entry: entry, fontURL: library.fontURL(for: entry), draftURL: library.draftURL(for: entry),
            licenseTextURL: library.licenseTextURL(for: entry), library: library,
            persistRights: { library.setRightsConfirmed($0, for: id) })
        editor.browseCatalog = { [weak self] script in
            guard let self else { return }
            defaults.set(script.rawValue, forKey: Key.catalogScript)
            let from = step
            go(to: .pick)
            catalogReturn = from
        }
        editors[id] = editor
        return editor
    }

    /// ③'s style set for the font `editor` is on, kept for the session like the editor.
    func styleSet(for editor: EditorModel) -> StyleSetModel {
        if let set = styleSets[editor.entry.id] { return set }
        let set = StyleSetModel(entry: editor.entry, library: library)
        styleSets[editor.entry.id] = set
        return set
    }

    /// A restricted font (product spec §4.2) is marked in ① and never gets
    /// past it.
    private func canOpen(_ id: LibraryEntry.ID) -> Bool {
        guard let entry = library.entries.first(where: { $0.id == id }) else { return false }
        return entry.license != .restricted
    }

    // MARK: Navigation

    /// Opens the font in ②; refused (and `refusedFont` set) when its license
    /// forbids changes.
    func open(_ id: LibraryEntry.ID) {
        guard canOpen(id) else {
            refusedFont = library.entries.first { $0.id == id }
            return
        }
        currentFontID = id
        defaults.set(id, forKey: Key.lastFont)
        step = .adjust
        catalogReturn = nil
    }

    func canGo(to step: FlowStep) -> Bool {
        step == .pick || currentFontID.map(canOpen) == true
    }

    func go(to step: FlowStep) {
        guard canGo(to: step) else { return }
        // Without the three steps, ② and ③ are one screen.
        self.step = !threeSteps && step == .export ? .adjust : step
        if step != .pick { catalogReturn = nil }
    }

    /// Back from ① to the step and font a card's 「到目錄挑…」 left.
    func returnFromCatalog() {
        guard let back = catalogReturn else { return }
        go(to: back)
    }

    /// ⌘[ and ⌘]: one step back or forward; without the three steps, between
    /// ① and the editing screen.
    func goBack() {
        go(to: step == .export && threeSteps ? .adjust : .pick)
    }

    func goForward() {
        switch step {
        case .pick: go(to: .adjust)
        case .adjust: if threeSteps { go(to: .export) }
        case .export: break
        }
    }

    /// ⌘E: to the export controls, and ask them to build and save.
    func requestExport() {
        guard let editor = currentEditor, canGo(to: .export) else { return }
        go(to: .export)
        editor.exportRequest = .export
    }

    #if os(macOS)
        func showInstalled() {
            go(to: .pick)
            showsInstalledRequested = true
        }
    #endif

    /// Writes every draft change still waiting for its debounced write: the
    /// app is going to the background or quitting.
    func saveDrafts() {
        for editor in editors.values { editor.saveDraft() }
    }

    // MARK: Managing the library

    /// ①'s 重新命名: the library's name for the font, and the open editor's
    /// copy of the entry, whose title shows it. False for a blank name.
    @discardableResult
    func rename(_ id: LibraryEntry.ID, to name: String) -> Bool {
        guard library.rename(id, to: name), let entry = library.entries.first(where: { $0.id == id }) else {
            return false
        }
        editors[id]?.entry = entry
        return true
    }

    /// ①'s 刪除 (移除下載 for a catalog font): the font leaves the library
    /// with its draft. The one being edited is closed, so ② and ③ cannot
    /// show a font that is gone, and the next launch does not look for it.
    func remove(_ id: LibraryEntry.ID) throws {
        editors[id]?.cancelDraftSave()
        try library.remove(id)
        editors[id] = nil
        styleSets[id] = nil
        for editor in editors.values { editor.libraryRemoved(id) }
        if currentFontID == id {
            currentFontID = nil
            step = .pick
        }
        if defaults.string(forKey: Key.lastFont) == id { defaults.removeObject(forKey: Key.lastFont) }
    }

    /// Imports the files and opens the last one given in ②, the step every
    /// import is for.
    func importFonts(_ urls: [URL]) async {
        let ids = await library.importFonts(urls)
        if let last = ids.last { open(last) }
    }
}
