import CryptoKit
import FontsMakerKit
import Foundation
import Observation

/// A font in the library: the copy kept in Application Support, plus what
/// the list shows without parsing 14 MB again.
struct LibraryEntry: Codable, Hashable, Identifiable, Sendable {
    /// sha256 of the file: names the stored copy and is the recipe's `source.sha256`.
    var id: String
    /// Name of the imported file; exported recipes name the source by it (`source.file`).
    var fileName: String
    var familyName: String
    /// The Traditional Chinese family name when the font has one that differs.
    var localizedFamilyName: String?
    var glyphCount: Int
    var characterCount: Int
    /// `LicenseStatus` raw value; the engine type is not Codable.
    var licenseRawValue: String
    /// Name ID 14, shown with the Reserved Font Name notice.
    var licenseURL: String?
    /// The user confirmed they may modify and redistribute a font whose license is not recognized.
    var rightsConfirmed: Bool
    /// What the user renamed the font to in ①. Only the library shows it:
    /// the font file, the recipe and the suggested export names keep the
    /// font's own family name.
    var customName: String?

    var license: LicenseStatus { LicenseStatus(rawValue: licenseRawValue) ?? .unknown }
    var displayName: String { customName ?? fontName }
    /// The name the font itself gives, in Chinese when it has one.
    var fontName: String { localizedFamilyName ?? familyName }
}

extension LibraryEntry {
    init(sha256: String, fileName: String, font: Font) {
        func name(_ ids: [UInt16], language: UInt16?) -> String? {
            for id in ids {
                let record = font.names.first {
                    $0.nameID == id && $0.platformID == 3 && (language == nil || $0.languageID == language)
                }
                if let text = record?.string, !text.isEmpty { return text }
            }
            return nil
        }
        // Typographic family (16) first: name ID 1 of a Medium font is "Family Medium".
        let english = name([16, 1], language: 0x0409) ?? name([16, 1], language: nil) ?? fileName
        let chinese = name([16, 1], language: 0x0404)
        self.init(
            id: sha256, fileName: fileName, familyName: english,
            localizedFamilyName: chinese == english ? nil : chinese, glyphCount: font.glyphs.count,
            characterCount: font.characterMap.mappings.count, licenseRawValue: font.licenseStatus.rawValue,
            licenseURL: font.names.first { $0.nameID == 14 }?.string, rightsConfirmed: false)
    }
}

/// The imported fonts, persisted as `library.json` plus one `Fonts/<sha256>.ttf`
/// per font under `root` (Application Support/FontsMaker in the app). The
/// editors keep their drafts beside them, as `Drafts/<sha256>.json`, and
/// downloaded fonts their license text, as `Licenses/<sha256>.txt`.
@MainActor @Observable
final class LibraryModel {
    private(set) var entries: [LibraryEntry] = []
    /// One line per file the last import could not add, or a storage failure.
    var problems: [String] = []
    private(set) var isImporting = false
    let root: URL

    init(root: URL) {
        self.root = root
        load()
    }

    static func defaultRoot() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("FontsMaker", isDirectory: true)
    }

    var indexURL: URL { root.appendingPathComponent("library.json") }

    func fontURL(for entry: LibraryEntry) -> URL {
        root.appendingPathComponent("Fonts", isDirectory: true).appendingPathComponent("\(entry.id).ttf")
    }

    /// A file per font rather than a field in `library.json`: the draft is
    /// rewritten as the user edits, and one that cannot be read must cost only
    /// that draft, never the library's index.
    func draftURL(for entry: LibraryEntry) -> URL {
        root.appendingPathComponent("Drafts", isDirectory: true).appendingPathComponent("\(entry.id).json")
    }

    private func load() {
        // No index yet is a first launch; an unreadable one must not pass for an empty library.
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return }
        do {
            entries = try JSONDecoder().decode([LibraryEntry].self, from: Data(contentsOf: indexURL))
        } catch {
            problems = ["字型庫索引無法讀取（\(indexURL.path)）：\(error.localizedDescription)"]
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: indexURL, options: .atomic)
        } catch {
            problems.append("字型庫無法儲存：\(error.localizedDescription)")
        }
    }

    /// Copies each readable font into the library and returns the IDs of
    /// the files given, imported now or already there. Unsupported files are
    /// reported with why, in the app's language (`describe`).
    @discardableResult
    func importFonts(_ urls: [URL]) async -> [LibraryEntry.ID] {
        await add(
            urls.map { url in
                (
                    url.lastPathComponent,
                    {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        return try Data(contentsOf: url)
                    }
                )
            }, licenseText: nil)
    }

    /// A downloaded font: its bytes and the name it is known by upstream.
    struct IncomingFont: Sendable {
        var fileName: String
        var data: Data
    }

    /// Adds downloaded fonts like imported files, keeping `licenseText` (the
    /// license that came with them) beside each one (`licenseTextURL`).
    @discardableResult
    func importDownloaded(_ fonts: [IncomingFont], licenseText: String?) async -> [LibraryEntry.ID] {
        await add(fonts.map { font in (font.fileName, { font.data }) }, licenseText: licenseText)
    }

    private func add(
        _ files: [(name: String, read: @Sendable () throws -> Data)], licenseText: String?
    ) async -> [LibraryEntry.ID] {
        isImporting = true
        defer { isImporting = false }
        var problems: [String] = []
        var ids: [LibraryEntry.ID] = []
        let root = root
        for file in files {
            let known = Set(entries.map(\.id))
            do {
                // Reading, hashing and parsing 14 MB takes long enough to stall the UI.
                let entry = try await Task.detached(priority: .userInitiated) {
                    try LibraryModel.store(
                        try file.read(), named: file.name, in: root, skipping: known, licenseText: licenseText)
                }.value
                if !known.contains(entry.id) { entries.append(entry) }
                ids.append(entry.id)
            } catch {
                problems.append("\(file.name)：\(LibraryModel.describe(error))")
            }
        }
        self.problems = problems
        sortEntries()
        save()
        return ids
    }

    private func sortEntries() {
        entries.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Renames the font in the library only. A blank name is refused (false);
    /// the font's own name clears the custom one, so the card follows the
    /// font again.
    @discardableResult
    func rename(_ id: LibraryEntry.ID, to name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries[index].customName = name == entries[index].fontName ? nil : name
        sortEntries()
        save()
        return true
    }

    /// Removes the font and everything the library keeps for it: the draft,
    /// the license text and the file. Fonts installed on the Mac are copies
    /// in `Installed/` and stay. Drafts of other fonts that take letters from
    /// it keep its sha256 and say it is missing.
    /// The font file goes last and the entry only after it: a failure part
    /// way leaves a font that still opens, never an entry without its file.
    func remove(_ id: LibraryEntry.ID) throws {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        for url in [draftURL(for: entry), licenseTextURL(for: entry), fontURL(for: entry)] {
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                // No draft yet, or no license text for an imported font.
            }
        }
        entries.removeAll { $0.id == id }
        save()
    }

    /// Why a file is refused, in Chinese like the rest of the app: the
    /// engine explains in English, for the CLI.
    nonisolated static func describe(_ error: any Error) -> String {
        guard let error = error as? FontLoadError else { return error.localizedDescription }
        switch error {
        case .woff, .woff2:
            return "這是網頁字型（WOFF），目前不支援。請先轉成 .ttf 或 .otf。"
        case .faceIndexOutOfRange(let index, let faceCount):
            return "這個檔裡沒有第 \(index + 1) 套字（只有 \(faceCount) 套）。"
        case .notVariable:
            return "這不是可變字型，不能指定軸的值。"
        case .unknownAxis(let tag, let available):
            return "這套可變字型沒有「\(tag)」軸（有的是 \(available.joined(separator: "、"))）。"
        case .axisValueOutOfRange(let tag, let value, let minimum, let maximum):
            return "「\(tag)」軸的值 \(value.formatted()) 超出範圍（\(minimum.formatted())～\(maximum.formatted())）。"
        case .outlineConversion(let detail):
            return "無法把這套字型的外框轉成 TrueType（\(detail)）。"
        case .notAFont:
            return "這個檔案不是字型。"
        case .missingTable(let tag):
            return "字型缺少必要的「\(tag)」表，無法處理。"
        case .unsupported(let detail):
            return "字型用到目前不支援的功能（\(detail)）。"
        case .malformed(let detail):
            return "字型檔已損毀（\(detail)）。"
        }
    }

    func setRightsConfirmed(_ confirmed: Bool, for id: LibraryEntry.ID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].rightsConfirmed = confirmed
        save()
    }

    nonisolated private static func store(
        _ data: Data, named fileName: String, in root: URL, skipping known: Set<String>, licenseText: String?
    ) throws -> LibraryEntry {
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let font = try Font(data: data)
        let entry = LibraryEntry(sha256: sha256, fileName: fileName, font: font)
        let directory = root.appendingPathComponent("Fonts", isDirectory: true)
        if !known.contains(sha256) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("\(sha256).ttf"), options: .atomic)
        }
        // Also for a font already there: imported by hand first, it had none.
        if let licenseText {
            let url = licenseTextURL(root: root, id: sha256)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(licenseText.utf8).write(to: url, options: .atomic)
        }
        return entry
    }

    nonisolated private static func licenseTextURL(root: URL, id: LibraryEntry.ID) -> URL {
        root.appendingPathComponent("Licenses", isDirectory: true).appendingPathComponent("\(id).txt")
    }

    /// The license text that came with a downloaded font.
    func licenseTextURL(for entry: LibraryEntry) -> URL {
        LibraryModel.licenseTextURL(root: root, id: entry.id)
    }

    /// Nil for a font imported from a file: its license is in its name table.
    func licenseText(for entry: LibraryEntry) -> String? {
        try? String(contentsOf: licenseTextURL(for: entry), encoding: .utf8)
    }
}
