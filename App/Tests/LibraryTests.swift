import FontsMakerKit
import Foundation
import Testing

@MainActor
struct LibraryTests {
    /// Import keeps a copy keyed by sha256, lists what the sidebar shows and
    /// survives a relaunch; importing the same file again adds nothing.
    @Test func importStoresAndPersists() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryModel(root: root)
        let ops = TestFonts.fixture("ops.ttf")
        let ids = await library.importFonts([ops])

        let entry = try #require(library.entries.first)
        let data = try Data(contentsOf: ops)
        #expect(ids == [sha256Hex(data)] && entry.id == sha256Hex(data))
        #expect(entry.fileName == "ops.ttf")
        #expect(entry.familyName == "FM Ops" && entry.localizedFamilyName == "運算測試")
        #expect(entry.license == .openFontLicense && entry.licenseURL == "https://openfontlicense.org")
        let font = try Font(data: data)
        #expect(entry.glyphCount == font.glyphs.count && entry.characterCount == font.characterMap.mappings.count)
        #expect(try Data(contentsOf: library.fontURL(for: entry)) == data)

        await library.importFonts([ops])
        #expect(library.entries.count == 1)

        library.setRightsConfirmed(true, for: entry.id)
        let reopened = LibraryModel(root: root)
        #expect(reopened.entries == library.entries && reopened.entries.first?.rightsConfirmed == true)
        #expect(reopened.problems.isEmpty)
    }

    /// Unsupported formats are refused with why, in Chinese like the rest of
    /// the app (the engine explains in English, for the CLI), one line per
    /// file, and the importable files still get in.
    @Test func unsupportedFormatsExplainWhy() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryModel(root: root)
        let rejects = ["reject-woff.woff", "reject-woff2.woff2"]
        await library.importFonts(rejects.map(TestFonts.fixture) + [TestFonts.fixture("restricted.ttf")])

        let expected: [FontLoadError] = [.woff, .woff2]
        #expect(library.problems == zip(rejects, expected).map { "\($0)：\(LibraryModel.describe($1))" })
        #expect(library.problems[0] == "reject-woff.woff：這是網頁字型（WOFF），目前不支援。請先轉成 .ttf 或 .otf。")
        for (problem, error) in zip(library.problems, expected) {
            #expect(!problem.contains(error.localizedDescription), "no English engine message: \(problem)")
        }
        // A restricted font is listed (with its badge) but cannot be built.
        #expect(library.entries.map(\.license) == [.restricted])
    }

    /// Every reason the engine gives has its own Chinese line: an English
    /// sentence from the engine in an alert of the Chinese app reads as a crash.
    @Test func everyLoadErrorIsExplainedInChinese() {
        let errors: [FontLoadError] = [
            .woff, .woff2, .notAFont, .missingTable("glyf"), .unsupported("x"), .malformed("x"),
            .faceIndexOutOfRange(index: 3, faceCount: 2), .notVariable,
            .unknownAxis(tag: "wdth", available: ["wght"]),
            .axisValueOutOfRange(tag: "wght", value: 1000, minimum: 100, maximum: 900),
            .outlineConversion("x"),
        ]
        for error in errors {
            let line = LibraryModel.describe(error)
            #expect(line != error.localizedDescription && line.unicodeScalars.contains { $0.value >= 0x4E00 }, "\(error)")
        }
        #expect(LibraryModel.describe(FontLoadError.faceIndexOutOfRange(index: 3, faceCount: 2)) == "這個檔裡沒有第 4 套字（只有 2 套）。")
    }

    /// ①'s 重新命名 names the font in the library and survives a relaunch;
    /// the font's own names stay, as the file and recipe know it by them. A
    /// blank name would leave a card without a title, so it is refused; the
    /// font's own name clears the custom one.
    @Test func renameIsKeptAndBlankIsRefused() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryModel(root: root)
        let ids = await library.importFonts([TestFonts.fixture("ops.ttf")])
        let id = try #require(ids.first)

        #expect(library.rename(id, to: "  電子書用\n"))
        let renamed = try #require(library.entries.first)
        #expect(renamed.displayName == "電子書用" && renamed.customName == "電子書用")
        #expect(renamed.familyName == "FM Ops" && renamed.localizedFamilyName == "運算測試" && renamed.fileName == "ops.ttf")
        #expect(LibraryModel(root: root).entries.first?.displayName == "電子書用", "kept across a relaunch")

        for blank in ["", "   ", "\n\t"] {
            #expect(!library.rename(id, to: blank), "\(blank.debugDescription) refused")
        }
        #expect(library.entries.first?.displayName == "電子書用")
        #expect(LibraryModel(root: root).entries.first?.displayName == "電子書用")

        #expect(library.rename(id, to: "運算測試"))
        #expect(library.entries.first?.customName == nil && library.entries.first?.displayName == "運算測試")
    }

    /// 刪除 takes everything the library keeps for the font: the file, the
    /// draft and the license text, and its entry, also after a relaunch.
    /// The other fonts, and the copies installed on the Mac (another file,
    /// in Installed/), stay.
    @Test func removeDeletesTheFontsFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryModel(root: root)
        let ops = try Data(contentsOf: TestFonts.fixture("ops.ttf"))
        let ids = await library.importDownloaded(
            [LibraryModel.IncomingFont(fileName: "ops.ttf", data: ops)], licenseText: "SIL Open Font License")
        await library.importFonts([TestFonts.fixture("minimal.ttf")])
        let entry = try #require(library.entries.first { $0.id == ids.first })
        let draft = library.draftURL(for: entry)
        try FileManager.default.createDirectory(at: draft.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: draft)
        let installed = root.appendingPathComponent("Installed/FMOps-Ebook.ttf")
        try FileManager.default.createDirectory(
            at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ops.write(to: installed)
        let files = [library.fontURL(for: entry), draft, library.licenseTextURL(for: entry)]
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        try library.remove(entry.id)
        for file in files {
            #expect(!FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent) is gone")
        }
        #expect(library.entries.map(\.fileName) == ["minimal.ttf"])
        #expect(LibraryModel(root: root).entries.map(\.fileName) == ["minimal.ttf"])
        #expect(FileManager.default.fileExists(atPath: installed.path), "the installed copy is not the library's")
        let minimal = try #require(library.entries.first)
        #expect(FileManager.default.fileExists(atPath: library.fontURL(for: minimal).path))
        // A font never edited and imported from a file has no draft and no license text.
        try library.remove(minimal.id)
        #expect(library.entries.isEmpty)
    }

    /// An index that cannot be read is reported, not treated as an empty library.
    @Test func unreadableIndexIsReported() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not json".utf8).write(to: root.appendingPathComponent("library.json"))
        let library = LibraryModel(root: root)
        #expect(library.entries.isEmpty && library.problems.count == 1)
    }
}
