import FontsMakerKit
import Foundation
import Observation

/// One of the four styles a reader app pairs into a family: `<b>` and `<i>`
/// find their files by name IDs 1/2 and the fsSelection BOLD/ITALIC bits
/// (technical design §5.6), which the engine sets from these style names.
enum StyleRole: Int, CaseIterable, Comparable, Identifiable, Sendable {
    case regular, italic, bold, boldItalic

    var id: Int { rawValue }
    var styleName: String { ["Regular", "Italic", "Bold", "Bold Italic"][rawValue] }
    var isBold: Bool { self == .bold || self == .boldItalic }
    var isItalic: Bool { self == .italic || self == .boldItalic }

    static func < (lhs: StyleRole, rhs: StyleRole) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A font of the library, as one face and instance, that a style can be
/// built from: a static file of the family, or a named instance of a
/// variable one (Literata's Bold is wght 700 of the same file as its Regular).
struct StyleSource: Hashable, Identifiable, Sendable {
    var entryID: LibraryEntry.ID
    var fileName: String
    var faceIndex: Int
    /// Only the axes away from their default, as a recipe keeps them.
    var variation: [String: Double]
    /// usWeightClass of this face and instance; a variable font's is its wght.
    var weight: Int
    var italic: Bool
    var unitsPerEm: Int
    /// What the style menus show: the file, and the instance when there is one.
    var label: String

    var id: String {
        let axes = variation.keys.sorted().map { "\($0)=\(variation[$0]!)" }.joined(separator: ",")
        return "\(entryID)/\(faceIndex)/\(axes)"
    }
}

/// Regular, Italic, Bold and Bold Italic exported at once (plan 4c, technical
/// design §5.6). Decision D4 stands: it is four recipes, one per font, each
/// with its own source, the same steps and family name as the editor's
/// draft, the RIBBI style name, and the weight class one step up when
/// emboldened (400→500, 700→800, written into the recipe because a RIBBI
/// name alone would say 400/700). The steps carry the draft's units, so the
/// line height set in ② is the same in all four and a paragraph does not
/// move when it switches to italic. Each recipe rebuilds with the CLI to
/// the bytes exported here.
///
/// Offered for Latin fonts: the families with italics, and the ones a
/// default instance can be read for cheaply (a CJK variable font's takes
/// seconds). Two of the four are enough, Regular among them: the catalog's
/// variable fonts have Regular and Bold instances but no italic file.
@MainActor @Observable
final class StyleSetModel {
    enum BuildState: Sendable {
        case idle
        case running(member: Int, of: Int, completed: Int, total: Int)
        case finished
        case failed(String)
        case cancelled
    }

    struct Member: Equatable, Sendable {
        let role: StyleRole
        let source: StyleSource
        let recipe: Recipe
    }

    struct Built: Sendable {
        let member: Member
        let result: BuildResult
        let sha256: String
    }

    let entry: LibraryEntry
    private let library: LibraryModel

    /// Every face and instance of the family in the library, once searched.
    private(set) var sources: [StyleSource] = []
    /// The family's library entries the sources were read from.
    private var searchedEntries: [LibraryEntry.ID]?
    /// The source each style is built from; a style left out is not exported.
    var chosen: [StyleRole: StyleSource] = [:]
    /// 「Regular／Italic／Bold／Bold Italic 一起匯出」: the export builds the set.
    var isOn = false

    private(set) var build = BuildState.idle
    /// The styles of the running or last build, in build order.
    private(set) var buildRoles: [StyleRole] = []
    private(set) var built: [Built] = []
    private var buildTask: Task<Void, Never>?
    private var cancelFlag: CancelFlag?

    /// Written and checked, not yet exported (iOS stages before Files saves).
    private(set) var staged: [ExportCheck] = []
    private(set) var exported: [ExportCheck] = []
    private(set) var exportDestination: ExportDestination?
    private(set) var exportProblem: String?
    /// 這台 Mac: how installing the exported files went, one line.
    var installSummary: String?

    init(entry: LibraryEntry, library: LibraryModel) {
        self.entry = entry
        self.library = library
    }

    // MARK: Finding the family

    /// Library fonts of this family: the same English family name (name ID
    /// 16, else 1, as the library lists it), which the members of a static
    /// family share. A restricted font never gets built.
    private var familyEntries: [LibraryEntry] {
        library.entries.filter {
            $0.familyName.caseInsensitiveCompare(entry.familyName) == .orderedSame && $0.license != .restricted
        }
    }

    /// Reads the family's faces and instances and chooses a source for each
    /// style (`assign`), off the main actor: every face's default instance is
    /// read for its weight and italic bits.
    /// Only when the family's files changed (an import may complete it):
    /// ③ asks every time it shows, and the styles chosen must survive that.
    func search() async {
        let family = familyEntries
        guard family.map(\.id) != searchedEntries else { return }
        searchedEntries = family.map(\.id)
        let files = family.map { ($0, library.fontURL(for: $0)) }
        let found = await Task.detached(priority: .userInitiated) { StyleSetModel.sources(of: files) }.value
        sources = found
        chosen = StyleSetModel.assign(found)
    }

    nonisolated static func sources(of files: [(LibraryEntry, URL)]) -> [StyleSource] {
        var found: [StyleSource] = []
        for (entry, url) in files {
            guard let data = try? Data(contentsOf: url), let faces = try? Font.faces(in: [UInt8](data)) else { continue }
            for face in faces {
                guard let font = try? Font(data: data, faceIndex: face.index) else { continue }
                let italic = RecipeDraft.isItalic(font)
                let name = faces.count > 1 ? "\(entry.fileName) 第 \(face.index + 1) 套" : entry.fileName
                func source(_ variation: [String: Double], weight: Double, italic: Bool, label: String) -> StyleSource {
                    StyleSource(
                        entryID: entry.id, fileName: entry.fileName, faceIndex: face.index, variation: variation,
                        weight: Int(weight.rounded()), italic: italic, unitsPerEm: Int(font.unitsPerEm), label: label)
                }
                guard let wght = face.axes.first(where: { $0.tag == "wght" }), !face.namedInstances.isEmpty else {
                    found.append(source([:], weight: Double(font.os2?.weightClass ?? 400), italic: italic, label: name))
                    continue
                }
                for instance in face.namedInstances {
                    var variation: [String: Double] = [:]
                    for axis in face.axes {
                        if let value = instance.coordinates[axis.tag], value != axis.defaultValue {
                            variation[axis.tag] = value
                        }
                    }
                    let weight = instance.coordinates["wght"] ?? wght.defaultValue
                    let label = "\(name) · \(instance.name ?? "wght \(Int(weight))")"
                    found.append(
                        source(
                            variation, weight: weight, italic: italic || (instance.coordinates["ital"] ?? 0) >= 1,
                            label: label))
                }
            }
        }
        // A variable font may name one location twice (with and without opsz, say).
        var seen = Set<String>()
        return found.filter { seen.insert($0.id).inserted }
    }

    /// For each style, the upright or italic source nearest its weight
    /// (400, 700); Regular no heavier than 500 and Bold no lighter than 600,
    /// so a Medium never stands in for a Bold. Ties go to the first label.
    nonisolated static func assign(_ sources: [StyleSource]) -> [StyleRole: StyleSource] {
        var chosen: [StyleRole: StyleSource] = [:]
        for role in StyleRole.allCases {
            let target = role.isBold ? 700 : 400
            let fits = sources.filter {
                $0.italic == role.isItalic && (role.isBold ? $0.weight >= 600 : $0.weight <= 500)
            }
            chosen[role] = fits.min { (abs($0.weight - target), $0.label) < (abs($1.weight - target), $1.label) }
        }
        return chosen
    }

    /// The family has a Regular and at least one more style: worth offering.
    var isAvailable: Bool {
        let roles = StyleSetModel.assign(sources)
        return roles[.regular] != nil && roles.count >= 2
    }

    /// Sources a style may be built from: the upright ones for Regular and
    /// Bold, the italic ones for the italics.
    func candidates(for role: StyleRole) -> [StyleSource] {
        sources.filter { $0.italic == role.isItalic }
    }

    /// Why the chosen sources cannot be exported as a set, if they cannot.
    var problem: String? {
        if chosen[.regular] == nil { return "要有 Regular。" }
        if chosen.count < 2 { return "至少要選兩種樣式。" }
        if Set(chosen.values.map(\.id)).count < chosen.count { return "同一套字不能同時當兩種樣式。" }
        if Set(chosen.values.map(\.unitsPerEm)).count > 1 {
            // The steps are in font units: the same numbers would mean other sizes.
            return "這幾套字的 unitsPerEm 不同，加粗、字距、行高的單位對不上，不能一起做。"
        }
        return nil
    }

    // MARK: Recipes and build

    /// One recipe per chosen style, encoded canonically and decoded strictly
    /// as `RecipeDraft.recipe(source:)` does, so the CLI reads back the same
    /// recipe and hash.
    func members(draft: RecipeDraft) throws -> [Member] {
        let localized = draft.localizedFamilyName.isEmpty ? [:] : ["zh-TW": draft.localizedFamilyName]
        return try StyleRole.allCases.compactMap { role in
            guard let source = chosen[role], let entry = library.entries.first(where: { $0.id == source.entryID })
            else { return nil }
            let weightClass = draft.emboldenWeight > 0 ? min(1000, source.weight + 100) : nil
            // Redrawn glyphs are absolute outlines of the font they were drawn
            // on: in another style they would put a Regular a into the Bold.
            var steps = draft.steps
            if !isEditorsFont(source, draft: draft) { steps.removeAll { $0.op == "outlines" } }
            let recipe = Recipe(
                source: Recipe.Source(
                    file: entry.fileName, sha256: entry.id, faceIndex: source.faceIndex, variation: source.variation),
                output: Recipe.Output(
                    familyName: draft.familyName, localizedFamilyName: localized, styleName: role.styleName,
                    weightClass: weightClass),
                steps: steps)
            return Member(role: role, source: source, recipe: try Recipe(json: recipe.canonicalJSON()))
        }
    }

    /// The face and instance the editor shows, the one its glyph edits were drawn on.
    private func isEditorsFont(_ source: StyleSource, draft: RecipeDraft) -> Bool {
        source.entryID == entry.id && source.faceIndex == draft.faceIndex && source.variation == draft.variation
    }

    /// Which styles carry the glyph editor's changes: only those built from
    /// the font they were drawn on. Nil without edits.
    func outlinesNote(draft: RecipeDraft) -> String? {
        guard !draft.outlines.isEmpty else { return nil }
        let roles = StyleRole.allCases.filter { chosen[$0].map { isEditorsFont($0, draft: draft) } ?? false }
        guard !roles.isEmpty else { return "逐字修改的造型是畫在另一套字上的，這幾份都不會帶。" }
        return "逐字修改的造型只用在 \(roles.map(\.styleName).joined(separator: "、"))：其他樣式的字形不一樣。"
    }

    var isBuilding: Bool {
        if case .running = build { return true }
        return false
    }

    /// The builds no longer match the draft or the styles chosen.
    func isStale(draft: RecipeDraft) -> Bool {
        (try? members(draft: draft)) != built.map(\.member)
    }

    /// Builds the set unless the finished one is of these settings; then
    /// waits for it. False when there is no current build to export.
    func buildIfNeeded(draft: RecipeDraft, rightsConfirmed: Bool) async -> Bool {
        if built.isEmpty || isStale(draft: draft) {
            startBuild(draft: draft, rightsConfirmed: rightsConfirmed)
            await buildTask?.value
        }
        if case .finished = build { return !isStale(draft: draft) }
        return false
    }

    /// One after another, so one font's worth of memory at a time; the
    /// progress names the member and counts its glyphs.
    func startBuild(draft: RecipeDraft, rightsConfirmed: Bool) {
        guard !isBuilding, problem == nil else { return }
        let members: [Member]
        do {
            members = try self.members(draft: draft)
        } catch {
            build = .failed(error.localizedDescription)
            return
        }
        let urls = members.map { member in
            library.entries.first { $0.id == member.source.entryID }.map(library.fontURL(for:))
        }
        buildRoles = members.map(\.role)
        built = []
        staged = []
        exported = []
        exportDestination = nil
        exportProblem = nil
        installSummary = nil
        let flag = CancelFlag()
        cancelFlag = flag
        let options = BuildOptions(iHaveRights: rightsConfirmed)
        // Running from the tap on, so a second tap cannot start another build.
        build = .running(member: 0, of: members.count, completed: 0, total: 0)
        buildTask = Task {
            var done: [Built] = []
            for (index, (member, url)) in zip(members, urls).enumerated() {
                build = .running(member: index, of: members.count, completed: 0, total: 0)
                let relay = ProgressRelay { [weak self] completed, total in
                    guard let self, self.cancelFlag === flag,
                        case .running(let shown, let count, let before, _) = self.build, shown == index
                    else { return }
                    self.build = .running(member: index, of: count, completed: max(before, completed), total: total)
                }
                let result = await Task.detached(priority: .userInitiated) {
                    Result { () throws -> Built in
                        guard let url else { throw CocoaError(.fileNoSuchFile) }
                        let built = try RecipeBuilder.build(
                            member.recipe, sourceData: try Data(contentsOf: url), options: options
                        ) { completed, total in
                            relay.report(completed, total)
                            return !flag.isCancelled
                        }
                        return Built(member: member, result: built, sha256: sha256Hex(built.fontData))
                    }
                }.value
                switch result {
                case .success(let one):
                    done.append(one)
                case .failure(let error) where error is CancellationError:
                    build = .cancelled
                    return
                case .failure(let error):
                    build = .failed("\(member.role.styleName)：\(error.localizedDescription)")
                    return
                }
            }
            built = done
            build = .finished
        }
    }

    func cancelBuild() {
        cancelFlag?.cancel()
    }

    // MARK: Export

    /// Writes every built font and its recipe into `folder`, with the
    /// sources' license text (once when they share it, as a family's files
    /// do: `<Family>-OFL.txt`), then reads each font back through CoreText
    /// against a preview of its own source instance, as a single export is
    /// checked. Nil when that failed; `exportProblem` says why. Not yet the
    /// export: `markExported` makes it one.
    func writeExport(to folder: URL, text: String) async -> [ExportCheck]? {
        let built = built
        guard !built.isEmpty else { return nil }
        let sources = built.map { one in
            library.entries.first { $0.id == one.member.source.entryID }.map {
                (font: library.fontURL(for: $0), license: library.licenseTextURL(for: $0), status: $0.license)
            }
        }
        do {
            let checks = try await Task.detached(priority: .userInitiated) {
                try StyleSetModel.write(built, sources: sources, to: folder, text: text)
            }.value
            staged = checks
            exportProblem = nil
            return checks
        } catch {
            exportProblem = error.localizedDescription
            return nil
        }
    }

    nonisolated private static func write(
        _ built: [Built], sources: [(font: URL, license: URL, status: LicenseStatus)?], to folder: URL, text: String
    ) throws -> [ExportCheck] {
        let manager = FileManager.default
        // License texts by content: one file for the family when they agree.
        var licenseTexts: [Data] = []
        for case let source? in sources {
            if let data = try? Data(contentsOf: source.license), !licenseTexts.contains(data) { licenseTexts.append(data) }
        }
        var checks: [ExportCheck] = []
        for (one, source) in zip(built, sources) {
            guard let source else { throw CocoaError(.fileNoSuchFile) }
            let fontURL = folder.appendingPathComponent(one.result.fileName)
            let recipeURL = fontURL.deletingPathExtension().appendingPathExtension("json")
            try one.result.fontData.write(to: fontURL, options: .atomic)
            try one.member.recipe.canonicalJSON().write(to: recipeURL, options: .atomic)
            var licenseURL: URL?
            if let license = try? Data(contentsOf: source.license) {
                let stem = fontURL.deletingPathExtension().lastPathComponent
                // "CTEbook-Bold" → "CTEbook": the PostScript family, without the style.
                let family = String(stem[..<(stem.lastIndex(of: "-") ?? stem.endIndex)])
                let url = folder.appendingPathComponent(
                    EditorModel.licenseFileName(stem: licenseTexts.count == 1 ? family : stem, license: source.status))
                try license.write(to: url, options: .atomic)
                licenseURL = url
            }
            let sourceFont = try Font(
                data: Data(contentsOf: source.font), faceIndex: one.member.source.faceIndex,
                variation: one.member.source.variation)
            var converter: S2TTextConverter?
            for case .s2t(let options) in one.member.recipe.steps {
                converter = try S2TTextConverter(font: sourceFont, options: options)
            }
            let expected = try PageText.preview(
                of: text, steps: one.member.recipe.steps, font: sourceFont, converter: converter
            ).page
            var check = try ExportCheck.run(
                fontURL: fontURL, recipeURL: recipeURL, sha256: one.sha256, recipe: one.member.recipe, text: text,
                expected: expected)
            check.licenseURL = licenseURL
            checks.append(check)
        }
        return checks
    }

    /// Every file written: fonts, recipes, and each license text once.
    static func files(of checks: [ExportCheck]) -> [URL] {
        var urls = checks.flatMap { [$0.fontURL, $0.recipeURL] }
        for case let license? in checks.map(\.licenseURL) where !urls.contains(license) { urls.append(license) }
        return urls
    }

    /// The checked files left the app: show them as the export.
    func markExported(_ checks: [ExportCheck], to destination: ExportDestination) {
        exported = checks
        exportDestination = destination
    }
}
