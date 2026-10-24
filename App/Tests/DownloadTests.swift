import FontsMakerKit
import Foundation
import Testing
import ZIPFoundation
import os

/// Stands in for the network: every URL a test serves is its own (a UUID
/// in the host or path), so tests running in parallel share the table
/// without seeing each other's replies. Anything else is a 404.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        /// `chunks` pieces, `pause` apart: long enough to cancel in between.
        case ok(Data, chunks: Int = 1, pause: Duration = .zero)
        case status(Int)
        case failure(URLError.Code)
    }

    private static let routes = OSAllocatedUnfairLock<[URL: Reply]>(initialState: [:])
    private static let served = OSAllocatedUnfairLock<[URL]>(initialState: [])
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    static func serve(_ replies: [URL: Reply]) {
        routes.withLock { $0.merge(replies) { $1 } }
    }

    static func requests(to url: URL) -> Int {
        served.withLock { $0.filter { $0 == url }.count }
    }

    static var fetcher: Fetcher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return Fetcher(session: URLSession(configuration: configuration))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        StubProtocol.served.withLock { $0.append(url) }
        let reply = StubProtocol.routes.withLock { $0[url] } ?? .status(404)
        switch reply {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code, userInfo: [NSURLErrorFailingURLErrorKey: url]))
        case .status(let status):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .ok(let data, let chunks, let pause):
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "\(data.count)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let size = max(1, (data.count + chunks - 1) / chunks)
            DispatchQueue.global().async { [self] in
                var offset = 0
                while offset < data.count {
                    if stopped.withLock({ $0 }) { return }
                    let end = min(offset + size, data.count)
                    client?.urlProtocol(self, didLoad: data.subdata(in: offset..<end))
                    offset = end
                    if pause > .zero && offset < data.count {
                        Thread.sleep(
                            forTimeInterval: Double(pause.components.attoseconds) / 1e18
                                + Double(pause.components.seconds))
                    }
                }
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }
}

/// A catalog entry for a stub URL, pinned to `data`.
func stubCatalogFont(
    serving data: Data, fileName: String = "ops.ttf", sha256: String? = nil, member: CatalogFont.ArchiveMember? = nil,
    license: Data = Data("SIL Open Font License 1.1 (test)".utf8), reply: StubProtocol.Reply? = nil
) -> CatalogFont {
    let base = URL(string: "https://stub-\(UUID().uuidString.lowercased()).test")!
    let url = base.appendingPathComponent(member == nil ? fileName : "fonts.zip")
    let licenseURL = base.appendingPathComponent("OFL.txt")
    StubProtocol.serve([url: reply ?? .ok(data), licenseURL: .ok(license)])
    return CatalogFont(
        id: base.host()!, name: "測試字", latinName: "Test", script: .latin, style: "Sans", blurb: "", publisher: "Test",
        license: "OFL-1.1", url: url, sha256: sha256 ?? sha256Hex(data), byteCount: data.count, member: member,
        fileName: fileName, licenseURL: licenseURL, variable: false, collection: false)
}

func makeZip(_ files: [(String, Data)]) throws -> Data {
    let archive = try Archive(data: Data(), accessMode: .create)
    for (path, data) in files {
        try archive.addEntry(
            with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate,
            provider: { position, size in data.subdata(in: Int(position)..<Int(position) + size) })
    }
    return try #require(archive.data)
}

@MainActor
struct DownloadTests {
    private func makeDownloads() throws -> (FontDownloads, URL) {
        let root = try temporaryDirectory()
        return (FontDownloads(library: LibraryModel(root: root), fetcher: StubProtocol.fetcher), root)
    }

    /// The catalog the user browses: every entry pinned to a file and to its
    /// license text over https, both tabs filled, and English with at least
    /// the four reading fonts the prototype offered (the user asked where
    /// the English fonts went).
    @Test func catalogEntriesArePinned() {
        let all = CatalogFont.all
        #expect(Set(all.map(\.id)).count == all.count && Set(all.map(\.fontSHA256)).count == all.count)
        for font in all {
            #expect(font.url.scheme == "https" && font.licenseURL.scheme == "https", "\(font.id)")
            for hash in [font.sha256, font.fontSHA256] {
                #expect(hash.count == 64 && hash.allSatisfy(\.isHexDigit), "\(font.id)")
            }
            #expect(font.byteCount > 0 && font.license == "OFL-1.1", "\(font.id)")
            #expect(FontArchive.fontExtensions.contains((font.fileName as NSString).pathExtension), "\(font.id)")
            #expect((font.member != nil) == (font.url.pathExtension == "zip"), "\(font.id)")
        }
        let latin = Set(all.filter { $0.script == .latin }.map(\.name))
        #expect(latin.isSuperset(of: ["Literata", "Source Serif 4", "EB Garamond", "Inter"]))
        #expect(all.filter { $0.script == .chinese }.count >= 5)
        #expect(all.contains { $0.isLarge } && all.contains { $0.collection } && all.contains { $0.variable })
    }

    /// The fonts added for 4g (the user asked for more open fonts like 思源黑體,
    /// in English too): each pinned like the rest, to google/fonts at a
    /// commit, with the OFL.txt of its own folder at the same commit.
    @Test func addedFontsArePinnedToGoogleFonts() {
        let added: [String: String] = [
            "noto-serif-tc": "notoseriftc", "cactus-classical-serif": "cactusclassicalserif",
            "chocolate-classical-sans": "chocolateclassicalsans", "lxgw-marker-gothic": "lxgwmarkergothic",
            "ibm-plex-serif": "ibmplexserif", "lora": "lora", "source-sans-3": "sourcesans3",
            "atkinson-hyperlegible-next": "atkinsonhyperlegiblenext", "ibm-plex-sans": "ibmplexsans",
            "jetbrains-mono": "jetbrainsmono", "source-code-pro": "sourcecodepro", "ibm-plex-mono": "ibmplexmono",
            "fira-mono": "firamono", "atkinson-hyperlegible-mono": "atkinsonhyperlegiblemono",
        ]
        for (id, folder) in added {
            guard let font = CatalogFont.all.first(where: { $0.id == id }) else {
                Issue.record("\(id) is not in the catalog")
                continue
            }
            let file = font.url.absoluteString
            let license = font.licenseURL.absoluteString
            let commit = file.split(separator: "/").dropFirst(4).first.map(String.init) ?? ""
            #expect(file.hasPrefix("https://raw.githubusercontent.com/google/fonts/") && commit.count == 40, "\(id)")
            #expect(file.contains("/\(commit)/ofl/\(folder)/"), "\(id): \(file)")
            #expect(license.hasSuffix("/\(commit)/ofl/\(folder)/OFL.txt"), "\(id): \(license)")
            #expect(font.member == nil && font.sha256.count == 64 && font.byteCount > 0, "\(id)")
            // Not the 50 MB the catalog leaves out (technical design §4.4).
            #expect(font.byteCount < 50_000_000, "\(id)")
        }
    }

    /// English is three groups, in reading order: serif, sans, and the
    /// monospaced fonts apart (the user asked for them to be). Every English
    /// font is in one; Chinese fonts are in none.
    @Test func englishFontsAreGroupedWithMonoApart() {
        let latin = CatalogFont.all.filter { $0.script == .latin }
        #expect(CatalogFont.LatinGroup.allCases.map(\.rawValue) == ["Serif", "Sans", "Mono"])
        for font in latin { #expect(font.latinGroup != nil, "\(font.id): style \(font.style)") }
        #expect(CatalogFont.all.filter { $0.script == .chinese }.allSatisfy { $0.latinGroup == nil })
        func names(_ group: CatalogFont.LatinGroup) -> Set<String> {
            Set(latin.filter { $0.latinGroup == group }.map(\.name))
        }
        // Checked in the files: one advance for every letter and figure.
        #expect(
            names(.mono) == [
                "JetBrains Mono", "Source Code Pro", "IBM Plex Mono", "Fira Mono", "Atkinson Hyperlegible Mono",
            ])
        #expect(names(.serif).isSuperset(of: ["Literata", "Source Serif 4", "EB Garamond", "IBM Plex Serif"]))
        #expect(names(.sans).isSuperset(of: ["Inter", "Source Sans 3", "Atkinson Hyperlegible Next", "IBM Plex Sans"]))
    }

    /// A catalog download that matches its sha256 lands in the library under
    /// the upstream file name, with the license text kept beside it; the
    /// card then finds it, and asking again downloads nothing.
    @Test func catalogDownloadIsStoredWithItsLicense() async throws {
        let (downloads, root) = try makeDownloads()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try Data(contentsOf: TestFonts.fixture("ops.ttf"))
        let font = stubCatalogFont(serving: data, fileName: "Ops[wght].ttf")
        downloads.download(font)
        #expect(downloads.catalog[font.id] == .downloading(received: 0, total: Int64(data.count)))
        await downloads.settled(font)

        #expect(downloads.catalog[font.id] == nil)
        let entry = try #require(downloads.entry(for: font))
        #expect(entry.id == sha256Hex(data) && entry.fileName == "Ops[wght].ttf")
        #expect(try Data(contentsOf: downloads.library.fontURL(for: entry)) == data)
        #expect(downloads.library.licenseText(for: entry) == "SIL Open Font License 1.1 (test)")
        downloads.download(font)
        #expect(downloads.catalog[font.id] == nil && StubProtocol.requests(to: font.url) == 1)
    }

    /// A file that is not what the catalog pinned (damaged, or changed
    /// upstream) is refused, says why in Chinese, and leaves nothing behind.
    @Test func checksumMismatchIsRefused() async throws {
        let (downloads, root) = try makeDownloads()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try Data(contentsOf: TestFonts.fixture("ops.ttf"))
        let font = stubCatalogFont(serving: data, sha256: String(repeating: "0", count: 64))
        downloads.download(font)
        await downloads.settled(font)

        #expect(downloads.catalog[font.id] == .failed(DownloadError.checksumMismatch(expected: "", actual: "").message))
        #expect(downloads.library.entries.isEmpty && downloads.entry(for: font) == nil)
        let stored = root.appendingPathComponent("Fonts")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: stored.path))?.isEmpty ?? true)
        downloads.dismissFailure(font)
        #expect(downloads.catalog[font.id] == nil)
    }

    /// A zipped catalog font: the zip is checked, then the member, which is
    /// the file stored (and the recipe's sha256). A member that differs
    /// from the pin is refused like a whole file.
    @Test func zippedCatalogFontIsCheckedTwice() async throws {
        let (downloads, root) = try makeDownloads()
        defer { try? FileManager.default.removeItem(at: root) }
        let ops = try Data(contentsOf: TestFonts.fixture("ops.ttf"))
        let zip = try makeZip([("OFL.txt", Data("license".utf8)), ("fonts/Ops-Regular.ttf", ops)])
        let good = stubCatalogFont(
            serving: zip, fileName: "Ops-Regular.ttf",
            member: CatalogFont.ArchiveMember(path: "fonts/Ops-Regular.ttf", sha256: sha256Hex(ops)))
        downloads.download(good)
        await downloads.settled(good)
        let entry = try #require(downloads.entry(for: good))
        #expect(entry.id == sha256Hex(ops) && entry.fileName == "Ops-Regular.ttf")

        // Pinned to a font not in the library yet, so the download runs.
        let minimal = try Data(contentsOf: TestFonts.fixture("minimal.ttf"))
        let wrongMember = stubCatalogFont(
            serving: zip, member: CatalogFont.ArchiveMember(path: "OFL.txt", sha256: sha256Hex(minimal)))
        downloads.download(wrongMember)
        await downloads.settled(wrongMember)
        #expect(
            downloads.catalog[wrongMember.id]
                == .failed(DownloadError.checksumMismatch(expected: "", actual: "").message))
        #expect(downloads.library.entries.count == 1)
    }

    /// Offline: the catalog is part of the app, so it still lists every font;
    /// a download says there is no connection, in Chinese, and the fonts
    /// already downloaded stay usable.
    @Test func offlineKeepsTheCatalogAndTheLibrary() async throws {
        let (downloads, root) = try makeDownloads()
        defer { try? FileManager.default.removeItem(at: root) }
        let ops = try Data(contentsOf: TestFonts.fixture("ops.ttf"))
        let downloaded = stubCatalogFont(serving: ops)
        downloads.download(downloaded)
        await downloads.settled(downloaded)

        let minimal = try Data(contentsOf: TestFonts.fixture("minimal.ttf"))
        let offline = stubCatalogFont(serving: minimal, reply: .failure(.notConnectedToInternet))
        // The license comes first; offline, it fails first.
        StubProtocol.serve([offline.licenseURL: .failure(.notConnectedToInternet)])
        downloads.download(offline)
        await downloads.settled(offline)
        guard case .failed(let message) = downloads.catalog[offline.id] else {
            Issue.record("offline download did not fail")
            return
        }
        #expect(message.hasPrefix("沒有網路連線"))
        #expect(!CatalogFont.all.isEmpty && downloads.entry(for: downloaded) != nil)
        #expect(downloads.library.entries.map(\.id) == [sha256Hex(ops)])
    }

    /// Cancelling stops the transfer part way and stores nothing; the card
    /// goes back to offering the download.
    @Test func cancelStopsTheDownload() async throws {
        let (downloads, root) = try makeDownloads()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data((0..<1_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let font = stubCatalogFont(serving: data, reply: .ok(data, chunks: 50, pause: .milliseconds(40)))
        downloads.download(font)
        var received: Int64 = 0
        while received == 0 {
            if case .downloading(let bytes, _)? = downloads.catalog[font.id] { received = bytes }
            try await Task.sleep(for: .milliseconds(5))
        }
        downloads.cancel(font)
        await downloads.settled(font)
        #expect(received < data.count)
        #expect(downloads.catalog[font.id] == nil && downloads.library.entries.isEmpty)
    }

    /// What a pasted link means: release pages (latest or a tag), files on
    /// GitHub and elsewhere; anything that cannot be downloaded says why.
    @Test func linksAreRecognized() throws {
        let release = SourceLink.gitHubRelease(owner: "ButTaiwan", repo: "iansui", tag: "v1.020")
        #expect(try SourceLink.parse("https://github.com/ButTaiwan/iansui/releases/tag/v1.020") == release)
        #expect(try SourceLink.parse(" github.com/ButTaiwan/iansui/releases/tag/v1.020\n") == release)
        let latest = SourceLink.gitHubRelease(owner: "lxgw", repo: "LxgwWenkaiTC", tag: nil)
        #expect(try SourceLink.parse("https://github.com/lxgw/LxgwWenkaiTC") == latest)
        #expect(try SourceLink.parse("https://github.com/lxgw/LxgwWenkaiTC.git") == latest)
        #expect(try SourceLink.parse("https://github.com/lxgw/LxgwWenkaiTC/releases") == latest)
        #expect(try SourceLink.parse("https://github.com/lxgw/LxgwWenkaiTC/releases/latest") == latest)
        let asset = "https://github.com/lxgw/LxgwWenkaiTC/releases/download/v1.522/LXGWWenKaiTC-Regular.ttf"
        #expect(try SourceLink.parse(asset) == .file(URL(string: asset)!))
        #expect(
            try SourceLink.parse("https://github.com/Chenyu-otf/chenyuluoyan_thin/blob/main/ChenYuluoyan-2.0-Thin.ttf")
                == .file(
                    URL(
                        string:
                            "https://raw.githubusercontent.com/Chenyu-otf/chenyuluoyan_thin/main/ChenYuluoyan-2.0-Thin.ttf"
                    )!
                ))
        let elsewhere = "https://example.org/fonts/Some%20Font.otf"
        #expect(try SourceLink.parse(elsewhere) == .file(URL(string: elsewhere)!))

        #expect(throws: DownloadError.notHTTPS) { try SourceLink.parse("http://example.org/a.ttf") }
        #expect(throws: DownloadError.notAURL) { try SourceLink.parse("原俠正楷") }
        #expect(throws: DownloadError.unrecognizedGitHubPage) {
            try SourceLink.parse("https://github.com/lxgw/LxgwWenkaiTC/issues/3")
        }
        #expect(throws: DownloadError.unrecognizedGitHubPage) { try SourceLink.parse("https://github.com/lxgw") }
    }

    /// A release link: the release's font files and zips to choose from
    /// (other assets left out); a zip with several fonts asks which; the
    /// chosen font is added with the zip's license and opened.
    @Test func releaseLinkListsAndUnpacks() async throws {
        let (downloads, root) = try makeDownloads()
        defer { try? FileManager.default.removeItem(at: root) }
        var opened: [LibraryEntry.ID] = []
        downloads.onImported = { opened = $0 }
        let owner = "stub\(UUID().uuidString.prefix(8))"
        let ops = try Data(contentsOf: TestFonts.fixture("ops.ttf"))
        let minimal = try Data(contentsOf: TestFonts.fixture("minimal.ttf"))
        let zip = try makeZip([
            ("Ops/OFL.txt", Data("zip license".utf8)), ("Ops/Ops-Regular.ttf", ops), ("Ops/Minimal.ttf", minimal),
            ("__MACOSX/Ops/._Ops-Regular.ttf", Data([0])),
        ])
        let zipURL = URL(string: "https://github.com/\(owner)/fonts/releases/download/v2/Ops.zip")!
        let api = URL(string: "https://api.github.com/repos/\(owner)/fonts/releases/tags/v2")!
        let json = """
            {"tag_name": "v2", "assets": [
              {"name": "Ops.zip", "size": \(zip.count), "browser_download_url": "\(zipURL)"},
              {"name": "Ops.ttf", "size": \(ops.count), "browser_download_url": "https://github.com/\(owner)/fonts/releases/download/v2/Ops.ttf"},
              {"name": "checksums.txt", "size": 10, "browser_download_url": "https://github.com/\(owner)/fonts/releases/download/v2/checksums.txt"}
            ]}
            """
        StubProtocol.serve([api: .ok(Data(json.utf8)), zipURL: .ok(zip)])

        downloads.resolve("https://github.com/\(owner)/fonts/releases/tag/v2")
        await downloads.customSettled()
        guard case .chooseAsset(let release) = downloads.custom else {
            Issue.record("no asset choice: \(downloads.custom)")
            return
        }
        #expect(release.tag == "v2" && release.assets.map(\.name) == ["Ops.zip", "Ops.ttf"])

        downloads.fetch(release.assets[0], of: release)
        await downloads.customSettled()
        guard case .chooseFonts(let name, let members) = downloads.custom else {
            Issue.record("no font choice: \(downloads.custom)")
            return
        }
        #expect(name == "Ops.zip" && members.map(\.path) == ["Ops/Ops-Regular.ttf", "Ops/Minimal.ttf"])

        downloads.importMembers([members[0]])
        await downloads.customSettled()
        let entry = try #require(downloads.library.entries.first)
        #expect(
            downloads.library.entries.count == 1 && entry.id == sha256Hex(ops) && entry.fileName == "Ops-Regular.ttf")
        #expect(downloads.library.licenseText(for: entry) == "zip license")
        #expect(downloads.custom == .idle && opened == [entry.id] && downloads.lastImported == [entry.id])
    }

    /// GitHub's anonymous quota runs out after 60 queries an hour: that is
    /// said plainly, with what to do instead, not as an HTTP error.
    @Test func gitHubRateLimitIsExplained() async throws {
        let (downloads, root) = try makeDownloads()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = "stub\(UUID().uuidString.prefix(8))"
        StubProtocol.serve([URL(string: "https://api.github.com/repos/\(owner)/x/releases/latest")!: .status(403)])
        downloads.resolve("https://github.com/\(owner)/x/releases")
        await downloads.customSettled()
        #expect(downloads.custom == .failed(DownloadError.gitHubRateLimited.message))

        let missing = "https://stub-\(UUID().uuidString.lowercased()).test/gone.ttf"
        downloads.resolve(missing)
        await downloads.customSettled()
        #expect(downloads.custom == .failed(DownloadError.http(status: 404, host: "").message))
    }

    /// Downloaded fonts meet the license gate exactly as imported files do
    /// (product spec §4.2): a restricted font from a link is listed but never
    /// opens; an unrecognized license builds only once the user confirms.
    @Test func licenseGateAppliesToDownloads() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "fontsmaker-app-tests-\(UUID().uuidString)"
        let app = AppModel(root: root, defaults: UserDefaults(suiteName: name)!, fetcher: StubProtocol.fetcher)
        let base = "https://stub-\(UUID().uuidString.lowercased()).test"
        let restricted = URL(string: "\(base)/restricted.ttf")!
        let unknown = URL(string: "\(base)/minimal.ttf")!
        StubProtocol.serve([
            restricted: .ok(try Data(contentsOf: TestFonts.fixture("restricted.ttf"))),
            unknown: .ok(try Data(contentsOf: TestFonts.fixture("minimal.ttf"))),
        ])

        app.downloads.resolve(restricted.absoluteString)
        await app.downloads.customSettled()
        let refused = try #require(app.library.entries.first)
        #expect(refused.license == .restricted && refused.fileName == "restricted.ttf")
        #expect(app.step == .pick && app.refusedFont == refused && app.currentFontID == nil)

        app.refusedFont = nil
        app.downloads.resolve(unknown.absoluteString)
        await app.downloads.customSettled()
        let editor = try #require(app.currentEditor)
        #expect(app.step == .adjust && editor.entry.fileName == "minimal.ttf" && editor.entry.license == .unknown)
        await editor.load()
        editor.draft.familyName = "Ebook Test"
        #expect(editor.licenseProblem != nil && !editor.canBuild)
        editor.rightsConfirmed = true
        #expect(editor.canBuild)
        UserDefaults().removePersistentDomain(forName: name)
    }
}
