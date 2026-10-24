import Foundation
import Observation
import ZIPFoundation

/// Why a download did not end in the library, in the app's language.
enum DownloadError: Error, Equatable {
    case http(status: Int, host: String)
    /// What arrived is not the file the catalog pinned, or the archive's
    /// member is not: never stored.
    case checksumMismatch(expected: String, actual: String)
    case notHTTPS
    case notAURL
    /// A page of a GitHub repository that is neither a release nor a file.
    case unrecognizedGitHubPage
    case noFontsInRelease(tag: String)
    case noFontsInArchive
    case archiveUnreadable
    case memberMissing(String)
    case gitHubRateLimited

    var message: String {
        switch self {
        case .http(404, _): "找不到檔案（HTTP 404）。來源可能已移除或改名。"
        case .http(let status, let host): "\(host) 回應錯誤（HTTP \(status)），請稍後再試。"
        case .checksumMismatch:
            "下載的檔案和目錄記錄的不一樣（sha256 不符），可能傳輸時損毀，或來源被改過。為了安全，沒有加入字型庫。"
        case .notHTTPS: "只支援 https:// 開頭的網址。"
        case .notAURL: "這不是網址。請貼上 GitHub release 頁面，或字型檔、zip 的下載網址。"
        case .unrecognizedGitHubPage: "這是 GitHub 專案裡的頁面，不是 release 或檔案。請貼 release 頁面，或字型檔的網址。"
        case .noFontsInRelease(let tag): "這個 release（\(tag)）沒有字型檔或 zip。"
        case .noFontsInArchive: "這個 zip 裡沒有字型檔（.ttf、.otf 或 .ttc）。"
        case .archiveUnreadable: "這個 zip 無法解開，檔案可能不完整。"
        case .memberMissing(let path): "zip 裡找不到「\(path)」。來源可能改版了。"
        case .gitHubRateLimited: "GitHub 暫時拒絕查詢（每小時的查詢次數用完了）。請稍後再試，或直接貼字型檔的網址。"
        }
    }

    /// Any error of a download, in Chinese: URLSession's own messages are
    /// in the system language and say nothing about what to do.
    static func describe(_ error: any Error) -> String {
        if let error = error as? DownloadError { return error.message }
        if let error = error as? URLError {
            let host = error.failingURL?.host() ?? "伺服器"
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return "沒有網路連線。已下載的字型照常可用；連上網路後再試一次。"
            case .timedOut: return "連線逾時，網路可能太慢。請稍後再試。"
            case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
                return "連不到 \(host)。請確認網址和網路連線。"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return "無法和 \(host) 建立安全連線。"
            case .appTransportSecurityRequiresSecureConnection: return DownloadError.notHTTPS.message
            case .badURL, .unsupportedURL: return DownloadError.notAURL.message
            default: return "下載失敗（\(error.code.rawValue)）：\(error.localizedDescription)"
            }
        }
        if error is DecodingError { return "GitHub 的回應看不懂，可能不是 release 頁面。" }
        return LibraryModel.describe(error)
    }

    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

/// HTTP GETs through one URLSession, which tests give a stub protocol, so
/// no test reaches the network.
struct Fetcher: Sendable {
    var session: URLSession = .shared

    /// The whole body. `progress` gets the bytes so far and the expected
    /// total, when the server says it.
    func data(
        _ request: URLRequest, progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }
    ) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let host = http.url?.host() ?? request.url?.host() ?? "伺服器"
            // GitHub answers an exhausted anonymous quota with 403 (or 429).
            if host == "api.github.com" && (http.statusCode == 403 || http.statusCode == 429) {
                throw DownloadError.gitHubRateLimited
            }
            throw DownloadError.http(status: http.statusCode, host: host)
        }
        let expected = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        var data = Data()
        if let expected { data.reserveCapacity(Int(expected)) }
        var chunk: [UInt8] = []
        let chunkSize = 64 * 1024
        chunk.reserveCapacity(chunkSize)
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count == chunkSize {
                data.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
                progress(Int64(data.count), expected)
                try Task.checkCancellation()
            }
        }
        data.append(contentsOf: chunk)
        progress(Int64(data.count), expected)
        return data
    }

    func data(from url: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }) async throws -> Data {
        try await data(URLRequest(url: url), progress: progress)
    }
}

/// A zip from a release: what fonts it holds, and its license file.
enum FontArchive {
    static let fontExtensions: Set<String> = ["ttf", "otf", "ttc"]

    struct Member: Hashable, Sendable {
        var path: String
        var byteCount: Int
        var fileName: String { (path as NSString).lastPathComponent }
    }

    static func isZip(_ data: Data) -> Bool { data.starts(with: [0x50, 0x4B, 0x03, 0x04]) }

    private static func open(_ data: Data) throws -> Archive {
        do {
            return try Archive(data: data, accessMode: .read)
        } catch {
            throw DownloadError.archiveUnreadable
        }
    }

    /// Font files, in archive order; macOS resource forks (`__MACOSX/`, `._*`) are not fonts.
    static func fonts(in data: Data) throws -> [Member] {
        try open(data).compactMap { entry in
            let name = (entry.path as NSString).lastPathComponent
            guard entry.type == .file, !entry.path.hasPrefix("__MACOSX/"), !name.hasPrefix("._"),
                fontExtensions.contains((name as NSString).pathExtension.lowercased())
            else { return nil }
            return Member(path: entry.path, byteCount: Int(entry.uncompressedSize))
        }
    }

    static func extract(_ path: String, from data: Data) throws -> Data {
        let archive = try open(data)
        guard let entry = archive[path] else { throw DownloadError.memberMissing(path) }
        var out = Data()
        out.reserveCapacity(Int(entry.uncompressedSize))
        do {
            _ = try archive.extract(entry) { out.append($0) }
        } catch {
            throw DownloadError.archiveUnreadable
        }
        return out
    }

    /// The first file named like a license (OFL.txt, LICENSE, SIL_Open_Font_License_1.1.txt…).
    static func licenseText(in data: Data) -> String? {
        guard let archive = try? open(data) else { return nil }
        let entry = archive.first { entry in
            let name = (entry.path as NSString).lastPathComponent.lowercased()
            return entry.type == .file && !entry.path.hasPrefix("__MACOSX/") && !name.hasPrefix("._")
                && (name.hasPrefix("ofl") || name.hasPrefix("licen") || name.contains("open_font_license")
                    || name.contains("open font license"))
        }
        guard let entry, let data = try? extract(entry.path, from: data) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// What a pasted link points at.
enum SourceLink: Equatable, Sendable {
    /// `tag` nil: the latest release.
    case gitHubRelease(owner: String, repo: String, tag: String?)
    case file(URL)

    static func parse(_ text: String) throws -> SourceLink {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Pasted from an address bar that hides the scheme.
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host()?.lowercased(), host.contains(".") else {
            throw DownloadError.notAURL
        }
        guard url.scheme?.lowercased() == "https" else { throw DownloadError.notHTTPS }
        guard host == "github.com" || host == "www.github.com" else { return .file(url) }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { throw DownloadError.unrecognizedGitHubPage }
        let (owner, repo) = (parts[0], parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1])
        let rest = Array(parts.dropFirst(2))
        switch rest.first {
        case nil:
            return .gitHubRelease(owner: owner, repo: repo, tag: nil)
        case "releases":
            if rest.count == 1 || rest[1] == "latest" { return .gitHubRelease(owner: owner, repo: repo, tag: nil) }
            if rest[1] == "tag", rest.count >= 3 { return .gitHubRelease(owner: owner, repo: repo, tag: rest[2]) }
            if rest[1] == "download", rest.count >= 4 { return .file(url) }
            throw DownloadError.unrecognizedGitHubPage
        case "blob" where rest.count >= 3:
            // The page that shows a file; its bytes are on raw.githubusercontent.com.
            let path = rest.dropFirst().joined(separator: "/")
            guard let raw = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(path)") else {
                throw DownloadError.notAURL
            }
            return .file(raw)
        case "raw" where rest.count >= 3:
            return .file(url)
        default:
            throw DownloadError.unrecognizedGitHubPage
        }
    }
}

/// A GitHub release, through the REST API: its font files and zips.
struct GitHubRelease: Sendable, Equatable {
    struct Asset: Hashable, Sendable, Identifiable {
        var name: String
        var byteCount: Int
        var url: URL
        var id: URL { url }
    }

    var owner: String
    var repo: String
    var tag: String
    var assets: [Asset]

    private struct Response: Decodable {
        struct Asset: Decodable {
            var name: String
            var size: Int
            var browser_download_url: URL
        }
        var tag_name: String
        var assets: [Asset]
    }

    private static func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(path)")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return request
    }

    static func fetch(owner: String, repo: String, tag: String?, fetcher: Fetcher) async throws -> GitHubRelease {
        let path = "\(owner)/\(repo)/releases/" + (tag.map { "tags/\($0)" } ?? "latest")
        let data = try await fetcher.data(request(path))
        let response = try JSONDecoder().decode(Response.self, from: data)
        let wanted = FontArchive.fontExtensions.union(["zip"])
        let assets = response.assets.filter { wanted.contains(($0.name as NSString).pathExtension.lowercased()) }
        guard !assets.isEmpty else { throw DownloadError.noFontsInRelease(tag: response.tag_name) }
        return GitHubRelease(
            owner: owner, repo: repo, tag: response.tag_name,
            assets: assets.map { Asset(name: $0.name, byteCount: $0.size, url: $0.browser_download_url) })
    }

    /// The repository's license file, which a release's font files rarely
    /// come with. Nil when there is none or it cannot be read: the license
    /// gate decides from the font itself either way.
    static func licenseText(owner: String, repo: String, fetcher: Fetcher) async -> String? {
        struct License: Decodable { var content: String }
        guard let data = try? await fetcher.data(request("\(owner)/\(repo)/license")),
            let license = try? JSONDecoder().decode(License.self, from: data),
            let text = Data(base64Encoded: license.content, options: .ignoreUnknownCharacters)
        else { return nil }
        return String(decoding: text, as: UTF8.self)
    }
}

/// Downloads into the library: catalog fonts, checked against the sha256
/// the catalog pins, and fonts from a pasted link (plan, Phase 4b). Either
/// way the font then meets the license gate like an imported file (product
/// spec §4.2), and its license text is kept beside it.
@MainActor @Observable
final class FontDownloads {
    enum Progress: Equatable {
        case downloading(received: Int64, total: Int64?)
        case failed(String)
    }

    /// The pasted-link sheet, one step at a time.
    enum CustomStep: Equatable {
        case idle
        case resolving
        case chooseAsset(GitHubRelease)
        case downloading(name: String, received: Int64, total: Int64?)
        /// A zip with several fonts: the user picks which to add.
        case chooseFonts(name: String, members: [FontArchive.Member])
        case failed(String)
    }

    let library: LibraryModel
    private let fetcher: Fetcher
    /// Fonts added from a link: opened in ②, as an imported file is.
    var onImported: (@MainActor ([LibraryEntry.ID]) -> Void)?

    /// Catalog fonts being downloaded or that failed; none once in the library.
    private(set) var catalog: [CatalogFont.ID: Progress] = [:]
    private var catalogTasks: [CatalogFont.ID: Task<Void, Never>] = [:]

    private(set) var custom = CustomStep.idle
    /// The fonts the last link added; the sheet closes when it changes.
    private(set) var lastImported: [LibraryEntry.ID] = []
    private var customTask: Task<Void, Never>?
    /// The zip the user is choosing fonts from, and the license that came with it.
    private var pendingArchive: (data: Data, license: String?)?

    init(library: LibraryModel, fetcher: Fetcher = Fetcher()) {
        self.library = library
        self.fetcher = fetcher
    }

    // MARK: Catalog

    /// The library entry of a downloaded catalog font: the same file
    /// imported by hand counts too, as it has the same sha256.
    func entry(for font: CatalogFont) -> LibraryEntry? {
        library.entries.first { $0.id == font.fontSHA256 }
    }

    func download(_ font: CatalogFont) {
        guard catalogTasks[font.id] == nil, entry(for: font) == nil else { return }
        catalog[font.id] = .downloading(received: 0, total: Int64(font.byteCount))
        let fetcher = fetcher
        let relay = DownloadRelay { [weak self] received, _ in
            guard let self, case .downloading = self.catalog[font.id] else { return }
            self.catalog[font.id] = .downloading(received: received, total: Int64(font.byteCount))
        }
        catalogTasks[font.id] = Task {
            do {
                // Not detached: cancelling this task must reach the download.
                // A nonisolated async function runs off the main actor anyway.
                let fetched = try await FontDownloads.fetch(font, fetcher: fetcher, progress: relay.report)
                try Task.checkCancellation()
                let ids = await library.importDownloaded(
                    [LibraryModel.IncomingFont(fileName: font.fileName, data: fetched.font)],
                    licenseText: fetched.license)
                if ids.isEmpty {
                    catalog[font.id] = .failed(library.problems.joined(separator: "\n"))
                    library.problems = []
                } else {
                    catalog[font.id] = nil
                }
            } catch  where DownloadError.isCancellation(error) {
                catalog[font.id] = nil
            } catch {
                catalog[font.id] = .failed(DownloadError.describe(error))
            }
            catalogTasks[font.id] = nil
        }
    }

    func cancel(_ font: CatalogFont) {
        catalogTasks[font.id]?.cancel()
    }

    /// Clears a failure, so the card offers the download again.
    func dismissFailure(_ font: CatalogFont) {
        if case .failed = catalog[font.id] { catalog[font.id] = nil }
    }

    /// Waits for a catalog download, for tests.
    func settled(_ font: CatalogFont) async {
        await catalogTasks[font.id]?.value
    }

    /// The license text first: it is small, and a font must not be stored
    /// without it. Then the font, checked against the pinned sha256 before
    /// anything is unpacked from it.
    nonisolated static func fetch(
        _ font: CatalogFont, fetcher: Fetcher, progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> (font: Data, license: String) {
        let license = try await fetcher.data(from: font.licenseURL)
        let download = try await fetcher.data(from: font.url, progress: progress)
        let actual = sha256Hex(download)
        guard actual == font.sha256 else { throw DownloadError.checksumMismatch(expected: font.sha256, actual: actual) }
        guard let member = font.member else { return (download, String(decoding: license, as: UTF8.self)) }
        let data = try FontArchive.extract(member.path, from: download)
        let memberHash = sha256Hex(data)
        guard memberHash == member.sha256 else {
            throw DownloadError.checksumMismatch(expected: member.sha256, actual: memberHash)
        }
        return (data, String(decoding: license, as: UTF8.self))
    }

    // MARK: A pasted link

    /// A release lists its files to choose from; a file link downloads at once.
    func resolve(_ text: String) {
        customTask?.cancel()
        let link: SourceLink
        do {
            link = try SourceLink.parse(text)
        } catch {
            custom = .failed(DownloadError.describe(error))
            return
        }
        switch link {
        case .file(let url):
            fetchFile(url, licenseFrom: nil)
        case .gitHubRelease(let owner, let repo, let tag):
            custom = .resolving
            let fetcher = fetcher
            customTask = Task {
                do {
                    let release = try await GitHubRelease.fetch(owner: owner, repo: repo, tag: tag, fetcher: fetcher)
                    // One file needs no choosing.
                    if release.assets.count == 1 {
                        fetchFile(release.assets[0].url, licenseFrom: release)
                    } else {
                        custom = .chooseAsset(release)
                    }
                } catch  where DownloadError.isCancellation(error) {
                    custom = .idle
                } catch {
                    custom = .failed(DownloadError.describe(error))
                }
            }
        }
    }

    func fetch(_ asset: GitHubRelease.Asset, of release: GitHubRelease) {
        fetchFile(asset.url, licenseFrom: release)
    }

    private func fetchFile(_ url: URL, licenseFrom release: GitHubRelease?) {
        customTask?.cancel()
        let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        custom = .downloading(name: name, received: 0, total: nil)
        let fetcher = fetcher
        let relay = DownloadRelay { [weak self] received, total in
            guard let self, case .downloading(let shown, _, _) = self.custom, shown == name else { return }
            self.custom = .downloading(name: name, received: received, total: total)
        }
        customTask = Task {
            do {
                // Alongside the file, which takes far longer.
                let repositoryLicense = Task { () -> String? in
                    guard let release else { return nil }
                    return await GitHubRelease.licenseText(owner: release.owner, repo: release.repo, fetcher: fetcher)
                }
                let data = try await fetcher.data(from: url, progress: relay.report)
                let license = await repositoryLicense.value
                try Task.checkCancellation()
                guard FontArchive.isZip(data) else {
                    await finish([LibraryModel.IncomingFont(fileName: name, data: data)], licenseText: license)
                    return
                }
                let (members, archiveLicense) = try await Task.detached(priority: .userInitiated) {
                    (try FontArchive.fonts(in: data), FontArchive.licenseText(in: data))
                }.value
                guard !members.isEmpty else { throw DownloadError.noFontsInArchive }
                pendingArchive = (data, archiveLicense ?? license)
                if members.count == 1 {
                    importMembers(members)
                } else {
                    custom = .chooseFonts(name: name, members: members)
                }
            } catch  where DownloadError.isCancellation(error) {
                custom = .idle
            } catch {
                custom = .failed(DownloadError.describe(error))
            }
        }
    }

    /// Unpacks the chosen fonts of the zip and adds them to the library.
    func importMembers(_ members: [FontArchive.Member]) {
        guard let archive = pendingArchive, !members.isEmpty else { return }
        customTask = Task {
            do {
                let fonts = try await Task.detached(priority: .userInitiated) {
                    try members.map {
                        LibraryModel.IncomingFont(
                            fileName: $0.fileName, data: try FontArchive.extract($0.path, from: archive.data))
                    }
                }.value
                pendingArchive = nil
                await finish(fonts, licenseText: archive.license)
            } catch {
                custom = .failed(DownloadError.describe(error))
            }
        }
    }

    private func finish(_ fonts: [LibraryModel.IncomingFont], licenseText: String?) async {
        let ids = await library.importDownloaded(fonts, licenseText: licenseText)
        if ids.isEmpty {
            // The library says why (WOFF, not a font, …), in Chinese.
            custom = .failed(library.problems.joined(separator: "\n"))
            library.problems = []
            return
        }
        custom = .idle
        lastImported = ids
        onImported?(ids)
    }

    func cancelCustom() {
        customTask?.cancel()
        customTask = nil
        pendingArchive = nil
        custom = .idle
    }

    /// Waits for the pasted link's current step, for tests.
    func customSettled() async {
        await customTask?.value
    }
}

/// Carries download progress to the main actor, at most once per 64 KB
/// chunk (the fetcher's) and so a few hundred hops for a large font.
final class DownloadRelay: Sendable {
    private let deliver: @MainActor @Sendable (Int64, Int64?) -> Void

    init(deliver: @escaping @MainActor @Sendable (Int64, Int64?) -> Void) {
        self.deliver = deliver
    }

    @Sendable func report(_ received: Int64, _ total: Int64?) {
        let deliver = deliver
        Task { @MainActor in deliver(received, total) }
    }
}
