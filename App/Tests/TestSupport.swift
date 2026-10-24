import FontsMakerKit
import Foundation
import Testing

/// Fonts the app tests use: the package's committed fixtures and the shared
/// reference-font cache (technical design D7).
enum TestFonts {
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func fixture(_ name: String) -> URL {
        repository.appendingPathComponent("Tests/FontsMakerKitTests/Fixtures").appendingPathComponent(name)
    }

    /// A missing cache fails the test rather than skipping it.
    static func reference(_ name: String) throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        // On the iOS Simulator the home directory is the simulated device's;
        // the cache is in the Mac user's.
        let home = environment["SIMULATOR_HOST_HOME"] ?? NSHomeDirectory()
        let directory =
            environment["FONTSMAKER_FIXTURES"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/FontsMaker/fixtures")
        let url = directory.appendingPathComponent(name)
        try #require(
            FileManager.default.fileExists(atPath: url.path),
            "Reference font \(name) is missing from \(directory.path). Run `bash scripts/fetch-fixtures.sh` first.")
        return url
    }
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("fontsmaker-app-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A library in a fresh directory with the given fonts imported, and an
/// editor on the first of them.
@MainActor
func makeEditor(_ fonts: [URL]) async throws -> (LibraryModel, EditorModel, URL) {
    let root = try temporaryDirectory()
    let library = LibraryModel(root: root)
    let ids = await library.importFonts(fonts)
    try #require(library.problems.isEmpty, "import problems: \(library.problems)")
    let entry = try #require(library.entries.first { $0.id == ids.first })
    let editor = EditorModel(
        entry: entry, fontURL: library.fontURL(for: entry), draftURL: library.draftURL(for: entry),
        licenseTextURL: library.licenseTextURL(for: entry), library: library,
        persistRights: { library.setRightsConfirmed($0, for: entry.id) })
    await editor.load()
    return (library, editor, root)
}
