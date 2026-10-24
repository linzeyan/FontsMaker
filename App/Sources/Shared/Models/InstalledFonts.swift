#if os(macOS)
    import CoreText
    import Foundation
    import Observation

    /// What `InstalledFonts` asks of CoreText. The tests stand in for it, so
    /// they never touch the font registry of the user running them.
    protocol FontRegistrar: Sendable {
        /// Registers the file for this user, across logins (`.user` scope).
        func register(_ url: URL) async throws
        func unregister(_ url: URL) async throws
        /// Files of the fonts this user can use under `postScriptName`,
        /// wherever they were installed from.
        func availableFiles(postScriptName: String) -> [URL]
    }

    /// CoreText refused a registration change; `code` is CTFontManagerError's.
    struct FontRegistrationError: Error, Equatable, LocalizedError {
        var code: Int
        /// CoreText's own description, kept for whatever the codes below miss.
        var detail: String

        static let notRegistered = 201

        var errorDescription: String? {
            let reason: String? =
                switch code {
                case 101: "找不到字型檔。"
                case 102: "沒有權限註冊這個字型檔。"
                case 103, 104: "系統認不得這個字型檔（格式不對或資料損毀）。"
                case 105: "這個字型檔已經註冊過。"
                case 201: "這個字型沒有註冊過。"
                case 202: "字型正在被使用，系統不讓移除。關掉正在用它的 App 再試一次。"
                case 203: "這是系統需要的字型，不能移除。"
                case 305: "系統裡已經有同名的字型。"
                default: nil
                }
            return "\(reason ?? detail)（CoreText 錯誤 \(code)）"
        }
    }

    struct CoreTextRegistrar: FontRegistrar {
        func register(_ url: URL) async throws {
            try await change(url) { urls, handler in CTFontManagerRegisterFontURLs(urls, .user, true, handler) }
        }

        func unregister(_ url: URL) async throws {
            try await change(url) { urls, handler in CTFontManagerUnregisterFontURLs(urls, .user, handler) }
        }

        /// Runs a CoreText registration call and collects the errors its
        /// handler reports until it says it is done. Nonisolated: the handler
        /// runs on CoreText's queue, and a closure isolated to the main actor
        /// traps there.
        private func change(
            _ url: URL, _ call: (CFArray, @escaping (CFArray, Bool) -> Bool) -> Void
        ) async throws {
            let errors: [FontRegistrationError] = await withCheckedContinuation { continuation in
                var collected: [FontRegistrationError] = []
                call([url] as CFArray) { errors, done in
                    for case let error as CFError in errors as [AnyObject] {
                        collected.append(
                            FontRegistrationError(
                                code: CFErrorGetCode(error), detail: CFErrorCopyDescription(error) as String))
                    }
                    if done { continuation.resume(returning: collected) }
                    return true
                }
            }
            if let first = errors.first { throw first }
        }

        func availableFiles(postScriptName: String) -> [URL] {
            let wanted = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: postScriptName] as CFDictionary)
            let mandatory = Set([kCTFontNameAttribute as String]) as CFSet
            let matches = CTFontDescriptorCreateMatchingFontDescriptors(wanted, mandatory) as? [CTFontDescriptor] ?? []
            return matches.compactMap { match in
                guard CTFontDescriptorCopyAttribute(match, kCTFontNameAttribute) as? String == postScriptName else {
                    return nil
                }
                return CTFontDescriptorCopyAttribute(match, kCTFontURLAttribute) as? URL
            }
        }
    }

    /// The fonts FontsMaker installed on this Mac. Each is a copy kept in
    /// `directory` (Application Support/FontsMaker/Installed) and registered
    /// from there, so the folder is the whole list: no index to drift from
    /// it, and nothing in ~/Library/Fonts, where the app could not tell its
    /// own fonts from the user's.
    @MainActor @Observable
    final class InstalledFonts {
        struct Item: Identifiable, Equatable, Sendable {
            var url: URL
            var postScriptName: String
            /// CoreText's display name, e.g. "GKTK Ebook Medium".
            var displayName: String
            var id: URL { url }
        }

        /// The latest install, for the finished export to report.
        struct Install: Equatable {
            enum State: Equatable {
                case installing
                case installed(Item)
                case failed(String)
            }

            /// The exported file that was installed (a copy of it is).
            var exportedFile: URL
            var state: State
        }

        enum InstallError: Error, LocalizedError {
            case unreadable(URL)
            case nameTaken(name: String, file: URL)
            case copyFailed(String)
            /// The new version did not install over an old one of the same name.
            case replaceFailed(reason: String, oldRestored: Bool)

            var errorDescription: String? {
                switch self {
                case .unreadable(let url):
                    "CoreText 讀不出 \(url.lastPathComponent) 的字型名稱，無法安裝。"
                case .nameTaken(let name, let file):
                    "這台 Mac 已經有同名的字型「\(name)」（\(file.path)），不是 FontsMaker 裝的。請在「字體簿」移除它，或在「字型名稱」換一個名稱再匯出。"
                case .copyFailed(let reason):
                    "字型檔無法放進 FontsMaker 的安裝資料夾：\(reason)"
                case .replaceFailed(let reason, true):
                    "新版沒有裝上：\(reason) 原本安裝的版本已經裝回，可以照常使用。"
                case .replaceFailed(let reason, false):
                    "新版沒有裝上：\(reason) 原本的版本也沒能裝回，請再安裝一次。"
                }
            }
        }

        let directory: URL
        private let registrar: any FontRegistrar
        private(set) var items: [Item] = []
        private(set) var lastInstall: Install?

        init(directory: URL, registrar: any FontRegistrar = CoreTextRegistrar()) {
            self.directory = directory
            self.registrar = registrar
            refresh()
        }

        /// Lists the folder again.
        func refresh() {
            let files =
                (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            // Named under `directory` as given: the listing resolves /var to
            // /private/var, and the registration must be undone by the URL it was made with.
            items = files.filter { $0.pathExtension.lowercased() == "ttf" }
                .map { directory.appendingPathComponent($0.lastPathComponent) }.compactMap(Self.read)
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        }

        nonisolated static func read(_ url: URL) -> Item? {
            guard
                let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                let descriptor = descriptors.first,
                let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
            else { return nil }
            let display = CTFontDescriptorCopyAttribute(descriptor, kCTFontDisplayNameAttribute) as? String
            return Item(url: url, postScriptName: name, displayName: display ?? name)
        }

        /// Installs a copy of `file`, replacing a font of the same name that
        /// FontsMaker installed before (never leaving two); the outcome is
        /// `lastInstall`.
        func install(_ file: URL) async {
            lastInstall = Install(exportedFile: file, state: .installing)
            let state: Install.State
            do {
                state = .installed(try await installCopy(of: file))
            } catch {
                state = .failed(error.localizedDescription)
            }
            lastInstall = Install(exportedFile: file, state: state)
        }

        private func installCopy(of file: URL) async throws -> Item {
            guard let font = Self.read(file) else { throw InstallError.unreadable(file) }
            let ours = directory.resolvingSymlinksInPath().path + "/"
            if let other = registrar.availableFiles(postScriptName: font.postScriptName).first(where: {
                !$0.resolvingSymlinksInPath().path.hasPrefix(ours)
            }) {
                throw InstallError.nameTaken(name: font.displayName, file: other)
            }
            // The old version has to go first (CoreText refuses a second font
            // of the same name, error 305), so its bytes are kept until the
            // new one is registered: if it is not, the old one goes back.
            // In memory, not a backup file: nothing is left behind to clean
            // up, and only a crash in between can lose it.
            let replaced = try items.filter { $0.postScriptName == font.postScriptName }.map {
                (item: $0, data: try Data(contentsOf: $0.url))
            }
            for old in replaced {
                try await remove(old.item)
            }
            let copy = directory.appendingPathComponent(font.postScriptName).appendingPathExtension("ttf")
            do {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.removeItem(at: copy) }
                    try FileManager.default.copyItem(at: file, to: copy)
                } catch {
                    throw InstallError.copyFailed(error.localizedDescription)
                }
                do {
                    try await registrar.register(copy)
                } catch {
                    // A copy CoreText refused is not installed: it must not be listed as if it were.
                    try? FileManager.default.removeItem(at: copy)
                    throw error
                }
            } catch {
                guard !replaced.isEmpty else {
                    refresh()
                    throw error
                }
                let restored = await reinstall(replaced)
                refresh()
                throw InstallError.replaceFailed(reason: error.localizedDescription, oldRestored: restored)
            }
            refresh()
            return Item(url: copy, postScriptName: font.postScriptName, displayName: font.displayName)
        }

        /// Puts back what a failed replacement removed, each from its own
        /// bytes at its own path. False when any did not come back; those
        /// are not left on disk, so the list shows only registered fonts.
        private func reinstall(_ fonts: [(item: Item, data: Data)]) async -> Bool {
            var all = true
            for font in fonts {
                do {
                    try font.data.write(to: font.item.url, options: .atomic)
                    try await registrar.register(font.item.url)
                } catch {
                    try? FileManager.default.removeItem(at: font.item.url)
                    all = false
                }
            }
            return all
        }

        /// Unregisters the font and deletes its copy. A font that is no
        /// longer registered (removed in Font Book, say) is still deleted;
        /// any other refusal keeps the file, so the list stays true.
        func remove(_ item: Item) async throws {
            do {
                try await registrar.unregister(item.url)
            } catch let error as FontRegistrationError where error.code == FontRegistrationError.notRegistered {
                // Nothing to undo in CoreText; the file is all that is left.
            }
            defer { refresh() }
            if FileManager.default.fileExists(atPath: item.url.path) {
                try FileManager.default.removeItem(at: item.url)
            }
            if case .installed(let installed)? = lastInstall?.state, installed.url == item.url {
                lastInstall = nil
            }
        }
    }
#endif
