#if os(macOS)
    import FontsMakerKit
    import Foundation
    import Testing
    import os

    /// Stands in for CoreText's registry, so the tests never install fonts
    /// for the user running them. `available` is what CoreText would match by
    /// PostScript name: what was registered here, plus fonts from elsewhere.
    final class FakeRegistrar: FontRegistrar {
        struct State {
            var registered: [URL] = []
            var calls: [String] = []
            var elsewhere: [String: URL] = [:]
            var refuseRegister: FontRegistrationError?
            /// How many registrations `refuseRegister` refuses; nil, all of them.
            var refusalsLeft: Int?
            var refuseUnregister: FontRegistrationError?
        }

        let state = OSAllocatedUnfairLock(initialState: State())

        func register(_ url: URL) async throws {
            try state.withLock { state in
                state.calls.append("register \(url.lastPathComponent)")
                if let refusal = state.refuseRegister, state.refusalsLeft ?? 1 > 0 {
                    state.refusalsLeft = state.refusalsLeft.map { $0 - 1 }
                    throw refusal
                }
                state.registered.append(url)
            }
        }

        func unregister(_ url: URL) async throws {
            try state.withLock { state in
                state.calls.append("unregister \(url.lastPathComponent)")
                if let refusal = state.refuseUnregister { throw refusal }
                guard let index = state.registered.firstIndex(of: url) else {
                    throw FontRegistrationError(code: FontRegistrationError.notRegistered, detail: "not registered")
                }
                state.registered.remove(at: index)
            }
        }

        func availableFiles(postScriptName: String) -> [URL] {
            state.withLock { state in
                state.registered.filter { InstalledFonts.read($0)?.postScriptName == postScriptName }
                    + [state.elsewhere[postScriptName]].compactMap { $0 }
            }
        }
    }

    /// The fonts FontsMaker installs on this Mac: a copy each in its own
    /// folder, which is the whole list (no index), registered from there;
    /// one font per name; removal undoes both; refusals are reported.
    @MainActor
    struct InstalledFontsTests {
        /// Two builds of ops.ttf under one name (same PostScript name,
        /// different bytes), as a re-export after a change gives.
        private func builds(in folder: URL) throws -> (URL, URL) {
            let data = try Data(contentsOf: TestFonts.fixture("ops.ttf"))
            var urls: [URL] = []
            for weight in [4.0, 8.0] {
                let recipe = Recipe(
                    source: Recipe.Source(file: "ops.ttf", sha256: sha256Hex(data)),
                    output: Recipe.Output(familyName: "FO Ebook", styleName: "Medium"),
                    steps: [.embolden(EmboldenStep(weight: weight))])
                let built = try RecipeBuilder.build(recipe, sourceData: data, options: BuildOptions())
                let url = folder.appendingPathComponent("w\(Int(weight))").appendingPathComponent(built.fileName)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try built.fontData.write(to: url)
                urls.append(url)
            }
            return (urls[0], urls[1])
        }

        private func ttfFiles(_ directory: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
        }

        @Test func installReplaceAndRemove() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let (first, second) = try builds(in: root.appendingPathComponent("exports"))
            let directory = root.appendingPathComponent("Installed")
            let registrar = FakeRegistrar()
            let installed = InstalledFonts(directory: directory, registrar: registrar)
            #expect(installed.items.isEmpty)

            await installed.install(first)
            let item = try #require(installed.items.first)
            #expect(installed.lastInstall == .init(exportedFile: first, state: .installed(item)))
            #expect(item.postScriptName == "FOEbook-Medium" && item.displayName == "FO Ebook Medium")
            // The copy is what is registered: the export may be moved or deleted.
            #expect(item.url == directory.appendingPathComponent("FOEbook-Medium.ttf"))
            #expect(try Data(contentsOf: item.url) == Data(contentsOf: first))
            #expect(registrar.state.withLock { $0.registered } == [item.url])

            // The folder is the list: a relaunch finds the font without an index.
            #expect(InstalledFonts(directory: directory, registrar: registrar).items == [item])

            // The same name again replaces it: never two copies of one font.
            await installed.install(second)
            #expect(installed.items.count == 1 && ttfFiles(directory) == ["FOEbook-Medium.ttf"])
            #expect(
                try Data(contentsOf: directory.appendingPathComponent("FOEbook-Medium.ttf")) == Data(contentsOf: second)
            )
            #expect(
                registrar.state.withLock { $0.calls }
                    == ["register FOEbook-Medium.ttf", "unregister FOEbook-Medium.ttf", "register FOEbook-Medium.ttf"])
            #expect(registrar.state.withLock { $0.registered.count } == 1)

            try await installed.remove(try #require(installed.items.first))
            #expect(installed.items.isEmpty && ttfFiles(directory).isEmpty)
            #expect(registrar.state.withLock { $0.registered }.isEmpty)
            #expect(installed.lastInstall == nil, "the export screen no longer shows it installed")
        }

        /// CoreText's refusals reach the user: a refused registration leaves
        /// no copy listed as installed; a refused removal keeps the file, so
        /// the list still shows the font that is still there. A font gone
        /// from CoreText already (removed in Font Book) is still deleted.
        @Test func refusalsAreReported() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let (first, _) = try builds(in: root.appendingPathComponent("exports"))
            let directory = root.appendingPathComponent("Installed")
            let registrar = FakeRegistrar()
            let installed = InstalledFonts(directory: directory, registrar: registrar)

            registrar.state.withLock { $0.refuseRegister = FontRegistrationError(code: 102, detail: "denied") }
            await installed.install(first)
            guard case .failed(let reason)? = installed.lastInstall?.state else {
                Issue.record("a refused registration must fail, got \(String(describing: installed.lastInstall))")
                return
            }
            #expect(reason == "沒有權限註冊這個字型檔。（CoreText 錯誤 102）")
            #expect(installed.items.isEmpty && ttfFiles(directory).isEmpty)

            registrar.state.withLock { $0.refuseRegister = nil }
            await installed.install(first)
            let item = try #require(installed.items.first)
            registrar.state.withLock { $0.refuseUnregister = FontRegistrationError(code: 202, detail: "in use") }
            await #expect(throws: FontRegistrationError(code: 202, detail: "in use")) {
                try await installed.remove(item)
            }
            #expect(installed.items == [item] && FileManager.default.fileExists(atPath: item.url.path))
            #expect(
                FontRegistrationError(code: 202, detail: "in use").localizedDescription
                    == "字型正在被使用，系統不讓移除。關掉正在用它的 App 再試一次。（CoreText 錯誤 202）")

            registrar.state.withLock {
                $0.refuseUnregister = nil
                $0.registered = []
            }
            try await installed.remove(item)
            #expect(installed.items.isEmpty && ttfFiles(directory).isEmpty)
        }

        /// Reinstalling a font of the same name must not cost the user the
        /// one they had: when CoreText refuses the new build, the old one is
        /// registered again from its own bytes, and the failure says so. Only
        /// when the old one cannot come back either does the list go empty,
        /// and the message says that too.
        @Test func refusedReplacementKeepsTheOldVersion() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let (first, second) = try builds(in: root.appendingPathComponent("exports"))
            let directory = root.appendingPathComponent("Installed")
            let registrar = FakeRegistrar()
            let installed = InstalledFonts(directory: directory, registrar: registrar)
            await installed.install(first)
            let item = try #require(installed.items.first)

            // Refuses the new build only, not the old one put back after it.
            registrar.state.withLock {
                $0.refuseRegister = FontRegistrationError(code: 104, detail: "bad font")
                $0.refusalsLeft = 1
            }
            await installed.install(second)
            guard case .failed(let reason)? = installed.lastInstall?.state else {
                Issue.record("a refused registration must fail, got \(String(describing: installed.lastInstall))")
                return
            }
            #expect(reason.contains("系統認不得這個字型檔") && reason.contains("原本安裝的版本已經裝回"))
            #expect(installed.items == [item], "the old version is still listed")
            #expect(try Data(contentsOf: item.url) == Data(contentsOf: first), "with its own bytes")
            #expect(registrar.state.withLock { $0.registered } == [item.url], "and registered")

            // Neither comes in: nothing listed, and the message says the old one is gone too.
            registrar.state.withLock { $0.refusalsLeft = nil }
            await installed.install(second)
            guard case .failed(let lost)? = installed.lastInstall?.state else {
                Issue.record("expected a failure, got \(String(describing: installed.lastInstall))")
                return
            }
            #expect(lost.contains("原本的版本也沒能裝回"))
            #expect(installed.items.isEmpty && ttfFiles(directory).isEmpty)
            #expect(registrar.state.withLock { $0.registered }.isEmpty)
        }

        /// A font of the same name that FontsMaker did not install (in
        /// ~/Library/Fonts, say) is not replaced, nor shadowed by a second
        /// one: the install stops and says where the other one is.
        @Test func nameTakenByAnotherFontIsRefused() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let (first, _) = try builds(in: root.appendingPathComponent("exports"))
            let registrar = FakeRegistrar()
            let theirs = URL(fileURLWithPath: "/Users/someone/Library/Fonts/FOEbook-Medium.ttf")
            registrar.state.withLock { $0.elsewhere["FOEbook-Medium"] = theirs }
            let installed = InstalledFonts(directory: root.appendingPathComponent("Installed"), registrar: registrar)
            await installed.install(first)
            guard case .failed(let reason)? = installed.lastInstall?.state else {
                Issue.record("expected a refusal")
                return
            }
            #expect(reason.contains("FO Ebook Medium") && reason.contains(theirs.path))
            #expect(installed.items.isEmpty && registrar.state.withLock { $0.calls }.isEmpty)
        }
    }
#endif
