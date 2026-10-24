import CryptoKit
import FontsMakerKit
import Foundation
import Observation
import os

enum BuildState: Sendable {
    case idle
    case running(completed: Int, total: Int)
    case finished(BuildOutcome)
    case failed(String)
    case cancelled
}

struct BuildOutcome: Sendable {
    /// Exactly what was built; export writes this recipe, never the current draft.
    let recipe: Recipe
    let result: BuildResult
    let sha256: String
    let seconds: Double
    /// Longest the main thread went without running during the build.
    let maxStallMilliseconds: Double

    var emboldenReport: EmboldenReport? {
        for case .embolden(_, let report) in result.reports { return report }
        return nil
    }

    /// Grade A and B glyphs the font shows. A glyph borrowed in review is
    /// still emboldened and graded (its replace step comes after embolden),
    /// but none of its characters shows it any more.
    var riskyGlyphs: Int {
        guard let report = emboldenReport,
            let embolden = recipe.steps.firstIndex(where: { if case .embolden = $0 { true } else { false } })
        else { return 0 }
        var borrowed: Set<UInt32> = []
        for case .replace(let step) in recipe.steps[(embolden + 1)...] { borrowed.formUnion(step.codePoints) }
        return report.glyphs.filter { glyph in
            RiskReview.reviewedGrades.contains(glyph.grade)
                && (glyph.codePoints.isEmpty || !glyph.codePoints.allSatisfy(borrowed.contains))
        }.count
    }
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// One font being turned into a derived font: the effects and names, live
/// preview, build, risk review and export (product spec §4). Platform-neutral,
/// so the same model drives the macOS and iOS views and runs in unit tests.
@MainActor @Observable
final class EditorModel {
    struct SourceFont: Sendable {
        let data: Data
        /// The font as the draft's face and instance make it.
        let font: Font
        /// Every font of the file (several in a .ttc), with its axes and named instances.
        let faces: [FontFace]
        let faceIndex: Int
        let variation: [String: Double]

        nonisolated static func read(_ data: Data, faceIndex: Int, variation: [String: Double]) throws -> SourceFont {
            SourceFont(
                data: data, font: try Font(data: data, faceIndex: faceIndex, variation: variation),
                faces: try Font.faces(in: [UInt8](data)), faceIndex: faceIndex, variation: variation)
        }
    }

    enum Loading {
        case loading
        case loaded(SourceFont)
        case failed(String)
    }

    static let cjkSampleText = """
        「電子書」預覽：天地玄黃，宇宙洪荒。日月盈昃，辰宿列張。
        简体测试：这个国家的发展为后来里程碑。
        （括號）『引號』——傳導帳熱繁聯育鬢 ABC abc 123！？
        """

    /// Running text, as a reader sets a book, then the shapes e-paper blurs
    /// first: rn/m, il1, O0 and the figures.
    static let latinSampleText = """
        It was the best of times, it was the worst of times, it was the age of wisdom, it was the age of \
        foolishness, it was the epoch of belief, it was the epoch of incredulity, it was the season of Light.
        “Sphinx of black quartz, judge my vow!” — rn m, il 1, O 0, 0123456789 (&?!)
        """

    /// The page's text for a font nobody typed one for: English for a Latin
    /// font; for a CJK font the Chinese test text, and a line of English
    /// under it for the Latin letters these fonts also carry.
    static func defaultSampleText(hasCJK: Bool) -> String {
        hasCJK ? cjkSampleText + "\nIt was the best of times, it was the worst of times. 0123456789" : latinSampleText
    }

    /// Han, kana or hangul in the cmap: the effects for CJK text (直排閱讀,
    /// 簡體書顯示繁體) apply. A Latin font has none of them; one character
    /// is enough, since those effects only ever touch such characters.
    nonisolated static func hasCJK(_ font: Font) -> Bool {
        font.characterMap.mappings.keys.contains(where: isCJK)
    }

    /// Han, kana or hangul.
    nonisolated static func isCJK(_ codePoint: UInt32) -> Bool {
        let ranges: [ClosedRange<UInt32>] = [
            0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x3134F,
        ]
        return ranges.contains { $0.contains(codePoint) }
    }

    /// Replaced by `AppModel.rename`, which changes only its display name.
    var entry: LibraryEntry
    let fontURL: URL
    /// Where the draft is kept between launches (`LibraryModel.draftURL`).
    let draftURL: URL
    /// The license text that came with a downloaded font
    /// (`LibraryModel.licenseTextURL`); no file there for an imported one.
    let licenseTextURL: URL
    /// Where 英文字母換成另一套字型 and 從另一套字型取代 find their second
    /// fonts; nil offers none.
    let library: LibraryModel?
    /// Takes the user to a tab of ①'s catalog, for a font to take glyphs
    /// from: English for Latin letters, 中文 for risky hanzi (`AppModel` sets it).
    var browseCatalog: (@MainActor (CatalogFont.Script) -> Void)?
    private let persistRights: @MainActor (Bool) -> Void
    private let log = Logger(subsystem: "app.fontsmaker.FontsMaker", category: "editor")

    private(set) var loading = Loading.loading
    // Stored apart from `draft`: the setter adjusts the names it is given,
    // and an @Observable property assigned in its own didSet recurses.
    // Set directly by init, so the restore is neither saved nor renamed.
    private var storedDraft: RecipeDraft
    var draft: RecipeDraft {
        get { storedDraft }
        set {
            let oldValue = storedDraft
            var draft = newValue
            followSuggestedNames(in: &draft, from: oldValue)
            storedDraft = draft
            if draft != oldValue { scheduleDraftSave() }
            // Another face or instance is another source font: the preview
            // follows once it is read.
            if draft.secondFonts != oldValue.secondFonts { loadSecondFonts() }
            if draft.faceIndex != oldValue.faceIndex || draft.variation != oldValue.variation {
                scheduleSourceReload()
            } else if draft.steps != oldValue.steps {
                // Names do not change outlines; only the steps do.
                schedulePreview()
            }
            // A flip by the user lasts until pseudoVertical itself is toggled.
            if (draft.pseudoVertical != nil) != (oldValue.pseudoVertical != nil) {
                previewOrientation = PageOrientation(steps: draft.steps)
            }
        }
    }
    /// The CJK text until the font has loaded, which then replaces it with
    /// its own default unless the user's text was put in (`FlowView`).
    var sampleText = EditorModel.cjkSampleText {
        didSet { if sampleText != oldValue { schedulePreview() } }
    }
    /// See `hasCJK(_:)`; decides which effect cards ② offers. True until the
    /// font has loaded, as for the fonts FontsMaker started with.
    private(set) var fontHasCJK = true

    /// The text 還原預設 puts back, for this font.
    var defaultSampleText: String { EditorModel.defaultSampleText(hasCJK: fontHasCJK) }
    var rightsConfirmed: Bool {
        didSet { if rightsConfirmed != oldValue { persistRights(rightsConfirmed) } }
    }

    /// The live page's orientation: turned while the draft has pseudoVertical,
    /// as a reader shows such a font. The user may flip it for the session.
    var previewOrientation = PageOrientation.horizontal
    /// The export page's: follows the exported recipe.
    var exportOrientation = PageOrientation.horizontal

    private(set) var preview: GlyphPreview?
    /// The sample text as the built font shows it (`PageText.preview`).
    private(set) var previewPage: PageText?
    /// The sample text in the unmodified source font, the page's 原字 beside
    /// `previewPage` (成品). It has no steps, so only a new text recomputes
    /// it: flipping between the two never waits, however often the steps change.
    private(set) var sourcePage: PageText?
    private(set) var previewProblem: String?
    /// The s2t phrase rules for the preview are still being derived (up to
    /// 0.3 s on an iPhone XR): the page shown predates the last change.
    private(set) var preparingPhraseRules = false
    /// A preview was asked for and has not landed yet; the pages shown are
    /// the last ones computed, or nil before the first.
    private var previewPending = false
    private var previewTask: Task<Void, Never>?
    /// The preview's stand-ins for s2t, one per options, derived off the main
    /// actor; the finished ones are also in `readyConverters`, so a preview
    /// can tell without waiting whether it has to.
    private var converterTasks: [S2TOptions: Task<S2TTextConverter, any Error>] = [:]
    private var readyConverters: [S2TOptions: S2TTextConverter] = [:]

    private(set) var build = BuildState.idle
    private var buildTask: Task<Void, Never>?
    private var cancelFlag: CancelFlag?

    private(set) var review = RiskReview()
    private(set) var exportCheck: ExportCheck?
    /// Where `exportCheck`'s files went; set with it.
    private(set) var exportDestination: ExportDestination?
    private(set) var exportProblem: String?

    /// The debounced write of the draft, while a change waits for it.
    private var draftSave: Task<Void, Never>?

    /// Restores the font's saved draft, if any, so the first preview already
    /// shows it.
    init(
        entry: LibraryEntry, fontURL: URL, draftURL: URL, licenseTextURL: URL, library: LibraryModel? = nil,
        persistRights: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        self.entry = entry
        self.fontURL = fontURL
        self.draftURL = draftURL
        self.licenseTextURL = licenseTextURL
        self.library = library
        self.persistRights = persistRights
        rightsConfirmed = entry.rightsConfirmed
        var unreadable: (any Error)?
        do {
            // No file yet: the font was never edited.
            storedDraft =
                try FileManager.default.fileExists(atPath: draftURL.path)
                ? JSONDecoder().decode(RecipeDraft.self, from: Data(contentsOf: draftURL)) : RecipeDraft()
        } catch {
            storedDraft = RecipeDraft()
            unreadable = error
        }
        previewOrientation = PageOrientation(steps: storedDraft.steps)
        if let unreadable {
            // Never in the way of opening the font; the next change replaces the file.
            log.error(
                "draft \(draftURL.path, privacy: .public) unreadable, starting a fresh one: \(String(describing: unreadable), privacy: .public)"
            )
        }
    }

    var source: Recipe.Source {
        Recipe.Source(file: entry.fileName, sha256: entry.id, faceIndex: draft.faceIndex, variation: draft.variation)
    }

    var sourceFont: SourceFont? {
        if case .loaded(let source) = loading { return source }
        return nil
    }

    func load() async {
        guard case .loading = loading else { return }
        let url = fontURL
        let (faceIndex, variation) = (draft.faceIndex, draft.variation)
        do {
            let (source, hasCJK) = try await Task.detached(priority: .userInitiated) {
                let source = try SourceFont.read(Data(contentsOf: url), faceIndex: faceIndex, variation: variation)
                return (source, EditorModel.hasCJK(source.font))
            }.value
            fontHasCJK = hasCJK
            loading = .loaded(source)
            if sampleText == EditorModel.cjkSampleText { sampleText = defaultSampleText }
            // A font never named yet gets the suggestion; any other name,
            // the user's or a suggestion from before, stays as it is.
            if draft.familyName.isEmpty {
                let suggested = suggestedNames(for: draft.effects)
                draft.familyName = suggested.family
                draft.styleName = suggested.style
            }
            loadSecondFonts()
            schedulePreview()
            // Chosen while the file was being read.
            if source.faceIndex != draft.faceIndex || source.variation != draft.variation { scheduleSourceReload() }
        } catch {
            loading = .failed(LibraryModel.describe(error))
        }
    }

    // MARK: - Face and instance

    /// Reading another instance of a variable font converts every glyph
    /// (0.2 s for 52,000 glyphs on a Mac), so a slider drag waits for a pause.
    private static let sourceReloadDelay = Duration.milliseconds(250)
    private var sourceReload: Task<Void, Never>?
    /// The face or instance chosen is still being read: the page shows the previous one.
    private(set) var isApplyingStyle = false

    /// The font of the file the draft builds from.
    var face: FontFace? {
        guard let faces = sourceFont?.faces, faces.indices.contains(draft.faceIndex) else { return nil }
        return faces[draft.faceIndex]
    }

    /// Axes have different ranges, or none, in another face: its default instance.
    func chooseFace(_ index: Int) {
        guard index != draft.faceIndex else { return }
        var draft = draft
        draft.faceIndex = index
        draft.variation = [:]
        self.draft = draft
    }

    /// Axis values as the recipe keeps them: only those away from the default.
    func setAxes(_ values: [String: Double]) {
        guard let axes = face?.axes else { return }
        var variation: [String: Double] = [:]
        for axis in axes {
            if let value = values[axis.tag], value != axis.defaultValue { variation[axis.tag] = value }
        }
        draft.variation = variation
    }

    /// Every axis's value in the draft's instance.
    var axisValues: [String: Double] {
        var values: [String: Double] = [:]
        for axis in face?.axes ?? [] { values[axis.tag] = draft.variation[axis.tag] ?? axis.defaultValue }
        return values
    }

    private func scheduleSourceReload() {
        guard let current = sourceFont else { return }  // the first load reads the draft's choice
        sourceReload?.cancel()
        previewTask?.cancel()
        isApplyingStyle = true
        let (faceIndex, variation) = (draft.faceIndex, draft.variation)
        sourceReload = Task {
            try? await Task.sleep(for: EditorModel.sourceReloadDelay)
            if Task.isCancelled { return }
            let result = await Task.detached(priority: .userInitiated) {
                Result { try SourceFont.read(current.data, faceIndex: faceIndex, variation: variation) }
            }.value
            if Task.isCancelled { return }
            isApplyingStyle = false
            switch result {
            case .success(let source):
                // Another instance is another weight: a style that was the
                // suggestion follows it, as it follows the effect cards; one
                // the user picked stays.
                let before = suggestedStyle(for: draft.effects, font: sourceFont?.font)
                loading = .loaded(source)
                let after = suggestedStyle(for: draft.effects, font: source.font)
                if draft.styleName == before && after != before { draft.styleName = after }
                // Both the 原字 page and the s2t converters were of the other font.
                sourcePage = nil
                converterTasks = [:]
                readyConverters = [:]
                schedulePreview()
            case .failure(let error):
                // The preview it cancelled will not come: nothing is updating any more.
                previewPending = false
                previewProblem = LibraryModel.describe(error)
            }
        }
    }

    /// Waits for the face or instance being read, for tests.
    func sourceSettled() async {
        await sourceReload?.value
    }

    // MARK: - Second fonts

    /// A second font of a replace step (英文字母換成另一套字型, or risk
    /// review's 從另一套字型取代), as the build reads it.
    struct ReplacementFont: Sendable {
        let id: LibraryEntry.ID
        let data: Data
        let font: Font
    }

    /// 英文字母換成另一套字型 is on with no font chosen yet: the user went to
    /// the catalog for one, and comes back to the card still open. Kept here,
    /// not in the card, which ① replaces on screen.
    var choosingReplacement = false
    /// Every second font the draft's steps read, by sha256; one is missing
    /// while it is read. Fonts the steps stop reading are let go.
    private(set) var secondFonts: [LibraryEntry.ID: ReplacementFont] = [:]
    /// Why a second font cannot be read, by sha256.
    private(set) var secondFontProblems: [LibraryEntry.ID: String] = [:]
    private var secondFontLoads: [LibraryEntry.ID: Task<Void, Never>] = [:]

    /// 英文字母換成另一套字型's font; nil while it is read, or when the draft has none.
    var replacementFont: ReplacementFont? { draft.replacement.flatMap { secondFonts[$0.sha256] } }
    /// Why 英文字母換成另一套字型's font cannot be read; the card says so.
    var replacementProblem: String? { draft.replacement.flatMap { secondFontProblems[$0.sha256] } }

    /// Library fonts the letters can come from. OFL only: the build's license
    /// gate needs a font it recognizes, or rights confirmed for that font too,
    /// and ③ asks only about the font being edited.
    var replacementCandidates: [LibraryEntry] {
        (library?.entries ?? []).filter { $0.id != entry.id && $0.license == .openFontLicense }
    }

    /// The second font as ① names it; its file name once it left the library.
    var replacementName: String? {
        draft.replacement.map { secondFontName(sha256: $0.sha256, fileName: $0.fileName) }
    }

    /// A second font as ① names it; its file name once it left the library.
    func secondFontName(sha256: String, fileName: String) -> String {
        library?.entries.first { $0.id == sha256 }?.displayName ?? fileName
    }

    /// Reads every second font the draft's steps name that is not read or
    /// being read already, and lets go of those they no longer name; the
    /// preview waits for them (`schedulePreview`). A font the library lacked
    /// is looked for again on the next change, since it may have come since.
    private func loadSecondFonts() {
        let wanted = draft.secondFonts
        for id in Set(secondFonts.keys).union(secondFontProblems.keys).union(secondFontLoads.keys)
        where wanted[id] == nil {
            secondFontLoads.removeValue(forKey: id)?.cancel()
            secondFonts[id] = nil
            secondFontProblems[id] = nil
        }
        for (id, fileName) in wanted where secondFonts[id] == nil && secondFontLoads[id] == nil {
            secondFontProblems[id] = nil
            guard let library, let entry = library.entries.first(where: { $0.id == id }) else {
                secondFontProblems[id] = "字型庫裡沒有「\(fileName)」，請另選一套字型。"
                continue
            }
            let url = library.fontURL(for: entry)
            secondFontLoads[id] = Task {
                let result = await Task.detached(priority: .userInitiated) {
                    Result { () throws -> ReplacementFont in
                        let data = try Data(contentsOf: url)
                        return ReplacementFont(id: id, data: data, font: try Font(data: data))
                    }
                }.value
                if Task.isCancelled { return }
                secondFontLoads[id] = nil
                switch result {
                case .success(let font):
                    secondFonts[id] = font
                    schedulePreview()
                case .failure(let error):
                    secondFontProblems[id] = LibraryModel.describe(error)
                    schedulePreview()
                }
            }
        }
    }

    /// The second fonts the steps read, by sha256, once every one is read;
    /// nil before.
    private var loadedSecondFonts: [String: Font]? {
        var fonts: [String: Font] = [:]
        for id in draft.secondFonts.keys {
            guard let loaded = secondFonts[id] else { return nil }
            fonts[id] = loaded.font
        }
        return fonts
    }

    /// Waits for the second fonts being read, for tests.
    func secondFontsSettled() async {
        // Each load removes itself when done; a cancelled one was removed when cancelled.
        while let load = secondFontLoads.values.first { await load.value }
    }

    // MARK: - Borrowing risky glyphs

    /// The CJK fonts of the library a risky glyph can be borrowed from
    /// (risk review's 從另一套字型取代), with the characters each has: OFL
    /// only, for the reason `replacementCandidates` gives. Read once per
    /// font (`findBorrowCandidates`): a CJK font takes a moment to parse.
    private(set) var borrowCandidates: [LibraryEntry.ID: Set<UInt32>] = [:]
    /// Library fonts read for `borrowCandidates`, CJK or not.
    private var probedFonts: Set<LibraryEntry.ID> = []
    /// `findBorrowCandidates` is reading fonts: the menu says so rather
    /// than offering none.
    private(set) var isFindingBorrowCandidates = false

    /// Reads each library font not read yet, off the main actor, one at a
    /// time (a CJK font parsed is tens of MB), keeping only its characters.
    func findBorrowCandidates() async {
        guard let library, !isFindingBorrowCandidates else { return }
        isFindingBorrowCandidates = true
        defer { isFindingBorrowCandidates = false }
        for candidate in library.entries
        where candidate.id != entry.id && candidate.license == .openFontLicense && !probedFonts.contains(candidate.id) {
            let url = library.fontURL(for: candidate)
            let characters = await Task.detached(priority: .userInitiated) { () -> Set<UInt32>? in
                guard let font = try? Font(data: Data(contentsOf: url)), EditorModel.hasCJK(font) else { return nil }
                return Set(font.characterMap.mappings.keys)
            }.value
            probedFonts.insert(candidate.id)
            if let characters { borrowCandidates[candidate.id] = characters }
        }
    }

    /// Fonts a review item's glyph can be borrowed from: they have every
    /// character of it (the recipe lists them all, and the build refuses a
    /// listed character the font lacks), by name.
    func borrowCandidates(for item: ReviewItem) -> [LibraryEntry] {
        guard RiskReview.canBorrow(item), let library else { return [] }
        let codePoints = item.characters.compactMap { $0.unicodeScalars.first?.value }
        return library.entries.filter { entry in
            borrowCandidates[entry.id].map { characters in codePoints.allSatisfy(characters.contains) } ?? false
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// A font left the library. A draft taking characters from it (the
    /// letters, or a borrowed glyph) keeps the choice and says the font is
    /// missing, as it does when restored without it; the copy read before
    /// is dropped, so nothing builds from a font the user deleted.
    func libraryRemoved(_ id: LibraryEntry.ID) {
        guard draft.secondFonts[id] != nil else { return }
        secondFontLoads.removeValue(forKey: id)?.cancel()
        secondFonts[id] = nil
        loadSecondFonts()
        schedulePreview()
    }

    // MARK: - Saved draft

    /// A slider drag or typing changes the draft several times a second, so
    /// a write waits this long for the next change. Leaving the foreground or
    /// quitting writes at once (`saveDraft()`): only a crash loses this much.
    private static let draftSaveDelay = Duration.seconds(1)

    private func scheduleDraftSave() {
        draftSave?.cancel()
        draftSave = Task {
            try? await Task.sleep(for: EditorModel.draftSaveDelay)
            if Task.isCancelled { return }
            draftSave = nil
            writeDraft()
        }
    }

    /// Writes a change still waiting for its debounced write, now: the app
    /// is going to the background or quitting, and may not run again.
    func saveDraft() {
        guard let pending = draftSave else { return }
        pending.cancel()
        draftSave = nil
        writeDraft()
        log.notice("draft \(self.draftURL.lastPathComponent, privacy: .public) saved ahead of its debounce")
    }

    /// The font is being deleted: a write still waiting would put its draft
    /// back after the library removed it.
    func cancelDraftSave() {
        draftSave?.cancel()
        draftSave = nil
    }

    /// Waits for the debounced write, for tests.
    func draftSettled() async {
        await draftSave?.value
    }

    private func writeDraft() {
        do {
            try FileManager.default.createDirectory(
                at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(draft).write(to: draftURL, options: .atomic)
        } catch {
            log.error(
                "draft not saved to \(self.draftURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Recipe

    /// The names the effects suggest (`RecipeDraft.suggestedFamilyNames`):
    /// the first family the engine's naming rules accept for this font, or
    /// "" when none does and the user has to choose one.
    func suggestedNames(for effects: RecipeDraft.Effects) -> (family: String, style: String) {
        let style = suggestedStyle(for: effects, font: sourceFont?.font)
        guard let font = sourceFont?.font else { return ("", style) }
        var probe = draft
        probe.localizedFamilyName = ""
        probe.styleName = style
        let family = RecipeDraft.suggestedFamilyNames(sourceFamily: entry.familyName, effects: effects).first {
            probe.familyName = $0
            return probe.nameProblem(source: source, font: font, secondFonts: secondFonts.mapValues(\.font)) == nil
        }
        return (family ?? "", style)
    }

    /// The style `RecipeDraft.suggestedStyle` gives `font`, the source as
    /// its face and instance make it: its weight and whether it is italic.
    private func suggestedStyle(for effects: RecipeDraft.Effects, font: Font?) -> String {
        RecipeDraft.suggestedStyle(
            effects: effects, sourceWeight: Int(font?.os2?.weightClass ?? 400),
            italic: font.map(RecipeDraft.isItalic) ?? false)
    }

    /// What 樣式 offers: the source's italic styles when it is italic. A
    /// style from elsewhere (a draft saved for another instance) is kept
    /// among them, so the menu still shows what the font will be called.
    var styleChoices: [String] {
        let choices = RecipeDraft.styles(italic: sourceFont.map { RecipeDraft.isItalic($0.font) } ?? false)
        return choices.contains(draft.styleName) ? choices : choices + [draft.styleName]
    }

    /// A name the user typed is theirs and is never replaced. One that is
    /// still what the previous effects suggested (or still empty) follows
    /// the effects as cards are switched; so does the style.
    private func followSuggestedNames(in draft: inout RecipeDraft, from old: RecipeDraft) {
        guard draft.effects != old.effects, sourceFont != nil else { return }
        let before = suggestedNames(for: old.effects)
        let after = suggestedNames(for: draft.effects)
        if draft.familyName == old.familyName && (old.familyName.isEmpty || old.familyName == before.family) {
            draft.familyName = after.family
        }
        if draft.styleName == old.styleName && old.styleName == before.style {
            draft.styleName = after.style
        }
    }

    /// The source's own line, ascender − descender + line gap in hhea: what
    /// CoreText and the page use, and what 行高 starts from.
    var sourceLineHeight: Int? {
        guard let hhea = sourceFont?.font.hhea else { return nil }
        return Int(hhea.ascender) - Int(hhea.descender) + Int(hhea.lineGap)
    }

    /// What 行高 is set to when switched on: 0.2 em looser than the font's
    /// own line, on the slider's 0.05 em steps.
    var suggestedLineHeight: Int {
        let unitsPerEm = Double(sourceFont?.font.unitsPerEm ?? 1000)
        let current = Double(sourceLineHeight ?? Int(unitsPerEm * 1.2)) / unitsPerEm
        let em = min(RecipeDraft.lineHeightRange.upperBound, max(RecipeDraft.lineHeightRange.lowerBound, current + 0.2))
        return Int(((em * 20).rounded() / 20 * unitsPerEm).rounded())
    }

    /// nil when the output names pass the engine's rules.
    var nameProblem: String? {
        guard let font = sourceFont?.font else { return nil }
        return draft.nameProblem(source: source, font: font, secondFonts: secondFonts.mapValues(\.font))
    }

    /// Why the license gate (product spec §4.2) stops the build, if it does.
    var licenseProblem: String? {
        switch entry.license {
        case .restricted: return "此字型的授權禁止修改（OS/2 fsType 設有 Restricted License），FontsMaker 不會處理。"
        case .unknown where !rightsConfirmed: return "無法辨識此字型的授權。請確認你有權修改並散布它，才能建置。"
        case .unknown, .openFontLicense: return nil
        }
    }

    var isBuilding: Bool {
        if case .running = build { return true }
        return false
    }

    var canBuild: Bool {
        sourceFont != nil && !isApplyingStyle && nameProblem == nil && licenseProblem == nil && !isBuilding
            && loadedSecondFonts != nil
    }

    var outcome: BuildOutcome? {
        if case .finished(let outcome) = build { return outcome }
        return nil
    }

    /// The finished build no longer matches the controls; exporting it would
    /// hand out something other than what the preview shows.
    var outcomeIsStale: Bool {
        guard let outcome else { return false }
        return (try? draft.recipe(source: source)) != outcome.recipe
    }

    // MARK: - Preview

    /// The pages shown predate the controls (or there are none yet): the
    /// font is being read, another instance is, or a preview is computing.
    /// The view keeps the last page and says it is updating, rather than
    /// going blank (4e's VM screenshot m28).
    var isUpdatingPreview: Bool {
        if case .loading = loading { return true }
        return previewPending || isApplyingStyle
    }

    private func schedulePreview() {
        previewTask?.cancel()
        guard let font = sourceFont?.font else { return }
        // Its load schedules the preview again once it is read.
        guard let replacements = loadedSecondFonts else {
            if let problem = draft.secondFonts.keys.sorted().lazy.compactMap({ self.secondFontProblems[$0] }).first {
                previewProblem = problem
            }
            return
        }
        let steps = draft.steps
        let text = sampleText
        let log = log
        previewPending = true
        previewTask = Task {
            // A later preview replaced this one and owns the flag; any other
            // end, success or failure, is the preview landing.
            defer { if !Task.isCancelled { previewPending = false } }
            // Debounce: a slider drag sends a value per frame.
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { return }
            // Before the s2t converter, which can take 0.3 s with phrases:
            // 原字 needs none, and is shown at once.
            if sourcePage?.text != text {
                let source = await Task.detached(priority: .userInitiated) {
                    Result { try PageText.preview(of: text, steps: [], font: font, converter: nil).page }
                }.value
                if Task.isCancelled { return }
                switch source {
                case .success(let page): sourcePage = page
                case .failure(let error):
                    previewProblem = error.localizedDescription
                    return
                }
            }
            var converter: S2TTextConverter?
            if let s2t = steps.s2tOptions {
                // Only phrase rules take long enough to need saying; the
                // character-level converter is ready in milliseconds.
                preparingPhraseRules = s2t.phrases && readyConverters[s2t] == nil
                do {
                    converter = try await self.converter(for: s2t, font: font)
                } catch {
                    if Task.isCancelled { return }
                    preparingPhraseRules = false
                    previewProblem = error.localizedDescription
                    return
                }
                if Task.isCancelled { return }
            }
            preparingPhraseRules = false
            let result = await Task.detached(priority: .userInitiated) { [converter] in
                Result { () throws -> (PageText, GlyphPreview, Duration) in
                    let clock = ContinuousClock()
                    let start = clock.now
                    let (page, preview) = try PageText.preview(
                        of: text, steps: steps, font: font, converter: converter, replacements: replacements)
                    return (page, preview, clock.now - start)
                }
            }.value
            if Task.isCancelled { return }
            switch result {
            case .success(let (page, preview, elapsed)):
                self.preview = preview
                previewPage = page
                previewProblem = nil
                log.info(
                    "preview: \(preview.glyphs.count) characters, \(preview.processedGlyphs) glyphs processed in \(elapsed.milliseconds, format: .fixed(precision: 1)) ms"
                )
            case .failure(let error):
                previewProblem = error.localizedDescription
            }
        }
    }

    /// The text converter that stands in for an s2t step (`PageText.preview`),
    /// derived once per options. With phrases that reads the whole phrase
    /// dictionary, 0.1–0.3 s on an iPhone XR in Release (ios-bench
    /// `s2t-converter`), too long for the main actor, so it runs off it and
    /// every later preview reuses it.
    private func converter(for options: S2TOptions, font: Font) async throws -> S2TTextConverter {
        if let ready = readyConverters[options] { return ready }
        let task =
            converterTasks[options]
            ?? Task.detached(priority: .userInitiated) { [log] in
                let clock = ContinuousClock()
                let start = clock.now
                let converter = try S2TTextConverter(font: font, options: options)
                log.info(
                    "s2t text converter (phrases: \(options.phrases), Taiwan variants: \(options.taiwanVariants)) derived in \((clock.now - start).milliseconds, format: .fixed(precision: 1)) ms"
                )
                return converter
            }
        converterTasks[options] = task
        let converter = try await task.value
        readyConverters[options] = converter
        return converter
    }

    /// Waits for the pending preview, for tests and for export.
    func previewSettled() async {
        await previewTask?.value
    }

    // MARK: - Build

    /// Starts a build unless the finished one is of the current settings,
    /// which is then the one to export. True when a build started.
    @discardableResult
    func startBuildIfNeeded() -> Bool {
        if outcome != nil && !outcomeIsStale { return false }
        guard canBuild else { return false }
        startBuild()
        return true
    }

    func startBuild() {
        guard canBuild, let source = sourceFont, let recipe = try? draft.recipe(source: self.source) else { return }
        exportCheck = nil
        exportDestination = nil
        exportProblem = nil
        let flag = CancelFlag()
        cancelFlag = flag
        build = .running(completed: 0, total: 0)
        let relay = ProgressRelay { [weak self] completed, total in
            guard let self, self.cancelFlag === flag, case .running(let shown, _) = self.build else { return }
            // Hops can arrive out of order; the bar never moves back.
            self.build = .running(completed: max(shown, completed), total: total)
        }
        let options = BuildOptions(iHaveRights: rightsConfirmed)
        let replacementData = Dictionary(
            recipe.replaceSteps.compactMap { step in secondFonts[step.font.sha256].map { (step.font.sha256, $0.data) } },
            uniquingKeysWith: { first, _ in first })
        let monitor = StallMonitor()
        monitor.start()
        let clock = ContinuousClock()
        let started = clock.now
        buildTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws -> (BuildResult, String) in
                    let built = try RecipeBuilder.build(
                        recipe, sourceData: source.data, replacementData: replacementData, options: options
                    ) {
                        completed, total in
                        relay.report(completed, total)
                        return !flag.isCancelled
                    }
                    return (built, sha256Hex(built.fontData))
                }
            }.value
            let seconds = Double((clock.now - started).milliseconds) / 1000
            finishBuild(result, recipe: recipe, seconds: seconds, stall: monitor.stop())
        }
    }

    func cancelBuild() {
        cancelFlag?.cancel()
    }

    /// Waits for the running build, for tests.
    func buildSettled() async {
        await buildTask?.value
    }

    private func finishBuild(
        _ result: Result<(BuildResult, String), any Error>, recipe: Recipe, seconds: Double, stall: Double
    ) {
        switch result {
        case .success(let (built, sha256)):
            let outcome = BuildOutcome(
                recipe: recipe, result: built, sha256: sha256, seconds: seconds, maxStallMilliseconds: stall)
            build = .finished(outcome)
            // The cmap embolden ran on: after a replace step, Latin letters are new glyphs.
            if let report = outcome.emboldenReport, let before = built.emboldenSnapshots?.before ?? sourceFont?.font {
                review.update(with: report, draft: draft, characterMap: before.characterMap)
            } else {
                review = RiskReview()
            }
            let recipeJSON = (try? String(decoding: recipe.canonicalJSON(), as: UTF8.self)) ?? "?"
            log.info(
                "build finished: \(built.fileName, privacy: .public) \(built.fontData.count) bytes sha256 \(sha256, privacy: .public) in \(seconds, format: .fixed(precision: 2)) s; main-thread max stall \(stall, format: .fixed(precision: 1)) ms; recipe \(recipeJSON, privacy: .public)"
            )
        case .failure(let error) where error is CancellationError:
            build = .cancelled
            log.info("build cancelled after \(seconds, format: .fixed(precision: 2)) s")
        case .failure(let error):
            build = .failed(error.localizedDescription)
            log.error("build failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Risk review

    func decision(for item: ReviewItem) -> ReviewDecision {
        review.decision(for: item, in: draft)
    }

    func setDecision(_ decision: ReviewDecision, for item: ReviewItem) {
        review.apply(decision, to: item, in: &draft)
    }

    // MARK: - Export

    /// ⌘E or 套用並重新匯出, for the export controls on screen to carry
    /// out (`ExportActions`): saving is the platform's, and asks the user.
    var exportRequest: ExportRequest?

    enum ExportRequest: Equatable {
        /// Build if needed, then ask where to save.
        case export
        /// The review changed the recipe: rebuild and save over the last
        /// export where the platform can (macOS), else ask again.
        case again
    }

    /// The library keeps a license text for this font: it goes with the export.
    var hasLicenseText: Bool { FileManager.default.fileExists(atPath: licenseTextURL.path) }

    /// The license text's name beside an export whose font is `<stem>.ttf`:
    /// `<stem>-OFL.txt` for an OFL font, which says what it is to whoever
    /// receives the folder, else `<stem>-LICENSE.txt`.
    nonisolated static func licenseFileName(stem: String, license: LicenseStatus) -> String {
        stem + (license == .openFontLicense ? "-OFL.txt" : "-LICENSE.txt")
    }

    /// Writes the built font to `fontURL` and its recipe next to it
    /// (`<stem>.json`, canonical encoding), and the source's license text
    /// when the library has one (`licenseFileName`): the OFL lets a modified
    /// font be passed on only with the license (condition 2), and a font is
    /// exported to be put on a reader. Then reads the font file back
    /// through CoreText and lays the sample text out with it. Nil when that
    /// failed; `exportProblem` says why.
    ///
    /// The result is not yet the export: on iOS these are staged files the
    /// user may still decline to save or share. `markExported` makes it one.
    func writeExport(to fontURL: URL) async -> ExportCheck? {
        guard let outcome, let source = sourceFont else { return nil }
        let recipeURL = fontURL.deletingPathExtension().appendingPathExtension("json")
        let licenseURL = fontURL.deletingLastPathComponent().appendingPathComponent(
            EditorModel.licenseFileName(stem: fontURL.deletingPathExtension().lastPathComponent, license: entry.license))
        let licenseTextURL = licenseTextURL
        let text = sampleText
        let replacements = Dictionary(
            outcome.recipe.replaceSteps.compactMap { step in
                secondFonts[step.font.sha256].map { (step.font.sha256, $0.font) }
            }, uniquingKeysWith: { first, _ in first })
        do {
            var converter: S2TTextConverter?
            if let s2t = outcome.recipe.steps.s2tOptions {
                converter = try await self.converter(for: s2t, font: source.font)
            }
            let check = try await Task.detached(priority: .userInitiated) { [converter] in
                try outcome.result.fontData.write(to: fontURL, options: .atomic)
                try outcome.recipe.canonicalJSON().write(to: recipeURL, options: .atomic)
                // Copied as stored: the text is the upstream file's, byte for byte.
                let license = FileManager.default.fileExists(atPath: licenseTextURL.path) ? licenseURL : nil
                if let license {
                    if FileManager.default.fileExists(atPath: license.path) { try FileManager.default.removeItem(at: license) }
                    try FileManager.default.copyItem(at: licenseTextURL, to: license)
                }
                let expected = try PageText.preview(
                    of: text, steps: outcome.recipe.steps, font: source.font, converter: converter,
                    replacements: replacements
                ).page
                var check = try ExportCheck.run(
                    fontURL: fontURL, recipeURL: recipeURL, sha256: outcome.sha256, recipe: outcome.recipe, text: text,
                    expected: expected)
                check.licenseURL = license
                return check
            }.value
            exportProblem = nil
            let scalars = Array(text.unicodeScalars)
            let differing = check.mismatches.map { "\(scalars[$0])@\($0)" }.joined(separator: " ")
            log.info(
                "wrote \(fontURL.path, privacy: .public) sha256 \(check.sha256, privacy: .public), \(recipeURL.path, privacy: .public) and license \(check.licenseURL?.lastPathComponent ?? "none", privacy: .public); CoreText loaded \(check.fullName, privacy: .public), \(check.matchingGlyphs)/\(check.checkedGlyphs) positions as previewed; differing: [\(differing, privacy: .public)]"
            )
            return check
        } catch {
            exportProblem = error.localizedDescription
            return nil
        }
    }

    /// The checked files left the app (saved, or shared): show them as the export.
    func markExported(_ check: ExportCheck, to destination: ExportDestination) {
        exportCheck = check
        exportDestination = destination
        exportOrientation = PageOrientation(steps: check.recipe.steps)
        log.info(
            "exported \(check.fontURL.lastPathComponent, privacy: .public) to \(String(describing: destination), privacy: .public)"
        )
    }
}

extension [Recipe.Step] {
    /// The options of the s2t step, if there is one.
    fileprivate var s2tOptions: S2TOptions? {
        for case .s2t(let options) in self { return options }
        return nil
    }
}

/// Set from the main actor, read by the engine's worker threads.
final class CancelFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { state.withLock { $0 } }
    func cancel() { state.withLock { $0 = true } }
}

/// Carries embolden progress from the engine's worker threads to the main
/// actor, at most once per 0.1 %: the engine reports every 16 glyphs and
/// holds its lock while doing so.
final class ProgressRelay: Sendable {
    private let lastPermille = OSAllocatedUnfairLock(initialState: -1)
    private let deliver: @MainActor @Sendable (Int, Int) -> Void

    init(deliver: @escaping @MainActor @Sendable (Int, Int) -> Void) {
        self.deliver = deliver
    }

    func report(_ completed: Int, _ total: Int) {
        let permille = total > 0 ? completed * 1000 / total : 0
        let isNew = lastPermille.withLock { last in
            guard last != permille else { return false }
            last = permille
            return true
        }
        guard isNew else { return }
        let deliver = deliver
        Task { @MainActor in deliver(completed, total) }
    }
}

/// Measures how late the main actor runs a 10 ms timer while a build is in
/// flight: evidence that the build never blocks the UI.
@MainActor
final class StallMonitor {
    private var task: Task<Void, Never>?
    private var worst = Duration.zero

    func start() {
        task = Task { @MainActor in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                let before = clock.now
                try? await Task.sleep(for: .milliseconds(10))
                worst = max(worst, clock.now - before - .milliseconds(10))
            }
        }
    }

    /// Milliseconds.
    func stop() -> Double {
        task?.cancel()
        return Double(worst.milliseconds)
    }
}

extension Duration {
    var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }
}
