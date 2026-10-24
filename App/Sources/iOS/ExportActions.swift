import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

/// iOS's 做出字型並存檔 (product spec §4.7): build if the settings were never
/// built, then the font, its recipe and the source's license text go to Files, or with 分享… to the
/// share sheet. Either way they are first written to a staging folder and
/// read back through CoreText, as macOS does with the saved file, so what
/// leaves the app is the file that was checked. They count as exported only
/// once Files saved them or the share sheet completed: a cancelled export
/// never left the app.
struct ExportActions: View {
    @Bindable var app: AppModel
    @Bindable var editor: EditorModel
    /// Written and checked, not exported yet.
    @State private var staged: ExportCheck?
    @State private var savingToFiles = false
    private let log = Logger(subsystem: "app.fontsmaker.FontsMaker", category: "export")

    var body: some View {
        let blocker = exportBlocker(app, editor)
        let set = app.styleSet(for: editor)
        let busy = blocker != nil || editor.isBuilding || set.isBuilding || (set.isOn && set.problem != nil)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    Task { if await prepare() { savingToFiles = true } }
                } label: {
                    Label("做出字型並存檔", systemImage: "arrow.down.doc").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(busy)
                Button {
                    Task { if await prepare() { share() } }
                } label: {
                    Label("分享…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(busy)
            }
            if set.isOn { StyleSetStatus(set: set) } else { BuildStatus(editor: editor) }
            if let blocker {
                Text(blocker).font(.callout).foregroundStyle(.orange)
            }
            if let problem = set.isOn ? set.exportProblem : editor.exportProblem {
                Text(problem).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        // Files always asks where: an app cannot write into a folder it was
        // not just given, so exporting again goes through the exporter too.
        .onChange(of: editor.exportRequest, initial: true) { _, request in
            guard request != nil else { return }
            editor.exportRequest = nil
            Task { if await prepare() { savingToFiles = true } }
        }
        .fileExporter(
            isPresented: $savingToFiles, documents: stagedFiles, contentTypes: [.data],
            onCompletion: { result in
                switch result {
                case .success(let urls):
                    log.info("saved to Files: \(urls.map(\.path).joined(separator: ", "), privacy: .public)")
                    // One exporter, one folder: either URL says where. Their
                    // order is not the documents' order.
                    let set = app.styleSet(for: editor)
                    if set.isOn, let saved = urls.first {
                        set.markExported(
                            set.staged,
                            to: .files(folder: filesFolder(of: saved), font: nil, recipe: nil, license: nil))
                        return
                    }
                    guard let staged, let saved = urls.first else {
                        log.error("Files reported a save without the saved files")
                        return
                    }
                    let names = ExportDestination.savedNames(urls)
                    editor.markExported(
                        staged,
                        to: .files(
                            folder: filesFolder(of: saved), font: names.font, recipe: names.recipe,
                            license: names.license))
                case .failure(let error):
                    log.error("saving to Files failed: \(error.localizedDescription, privacy: .public)")
                }
            },
            onCancellation: { log.info("saving to Files cancelled") })
    }

    /// Builds if needed and stages the result. False when it cannot be
    /// exported; the panel shows why (`BuildStatus`, `exportProblem`).
    private func prepare() async -> Bool {
        guard exportBlocker(app, editor) == nil, !editor.isBuilding else { return false }
        let set = app.styleSet(for: editor)
        if set.isOn {
            guard set.problem == nil,
                await set.buildIfNeeded(draft: editor.draft, rightsConfirmed: editor.rightsConfirmed)
            else { return false }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ExportSet", isDirectory: true)
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return await set.writeExport(to: folder, text: editor.sampleText) != nil
        }
        if editor.startBuildIfNeeded() { await editor.buildSettled() }
        guard editor.outcome != nil, !editor.outcomeIsStale else { return false }
        return await stage()
    }

    /// Files' names for the folder `url` was saved into, read while the URL's
    /// security scope is open (`ExportDestination.filesFolder`).
    private func filesFolder(of url: URL) -> [String] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let container = (try? url.resourceValues(forKeys: [.ubiquitousItemContainerDisplayNameKey]))?
            .ubiquitousItemContainerDisplayName
        return ExportDestination.filesFolder(
            of: url, device: UIDevice.current.model, iCloudContainer: container
        ) { folder in
            (try? folder.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
        }
    }

    private var stagedFiles: [StagedFile] {
        let set = app.styleSet(for: editor)
        if set.isOn { return StyleSetModel.files(of: set.staged).map(StagedFile.init(url:)) }
        guard let staged else { return [] }
        return ([staged.fontURL, staged.recipeURL] + [staged.licenseURL].compactMap { $0 }).map(StagedFile.init(url:))
    }

    /// Writes the build into a fresh staging folder. False when that failed
    /// (`exportProblem` says why).
    private func stage() async -> Bool {
        guard let outcome = editor.outcome else { return false }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Export", isDirectory: true)
        // Only the latest export is kept: a font is 14–19 MB.
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        staged = await editor.writeExport(to: folder.appendingPathComponent(outcome.result.fileName))
        return staged != nil
    }

    /// ShareLink needs its items when it is drawn, and these files exist only
    /// once staged, so the share sheet is presented from UIKit.
    private func share() {
        let set = app.styleSet(for: editor)
        let items: [URL]
        if set.isOn {
            items = StyleSetModel.files(of: set.staged)
        } else if let staged {
            items = [staged.fontURL, staged.recipeURL] + [staged.licenseURL].compactMap { $0 }
        } else {
            return
        }
        let (single, setStaged) = (set.isOn ? nil : staged, set.isOn ? set.staged : [])
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let log = log
        let editor = editor
        activity.completionWithItemsHandler = { type, completed, _, error in
            if let error {
                log.error("share failed: \(error.localizedDescription, privacy: .public)")
            } else if completed {
                log.info("shared via \(type?.rawValue ?? "?", privacy: .public)")
                MainActor.assumeIsolated {
                    if let single {
                        editor.markExported(single, to: .shared(activity: type?.rawValue))
                    } else {
                        set.markExported(setStaged, to: .shared(activity: type?.rawValue))
                    }
                }
            } else {
                log.info("share sheet dismissed without sharing")
            }
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard var top = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow?.rootViewController
        else { return }
        while let presented = top.presentedViewController { top = presented }
        // On iPad the sheet is a popover, which needs an anchor.
        if let popover = activity.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(activity, animated: true)
    }
}

/// A staged file handed to the Files exporter unchanged: its name and bytes.
struct StagedFile: FileDocument {
    static let readableContentTypes: [UTType] = [.data]
    let url: URL

    init(url: URL) {
        self.url = url
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url)
    }
}
