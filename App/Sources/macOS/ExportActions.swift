import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// macOS's 做出字型並存檔 (product spec §4.7): build if the settings were
/// never built, a save panel for the font (the recipe goes next to it under
/// the same stem), and for 這台 Mac the install. ⌘E and the review's
/// 套用並重新匯出 come in as `EditorModel.exportRequest`.
struct ExportActions: View {
    @Bindable var app: AppModel
    @Bindable var editor: EditorModel

    var body: some View {
        let blocker = exportBlocker(app, editor)
        let set = app.styleSet(for: editor)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await export(again: false) }
            } label: {
                Label("做出字型並存檔", systemImage: "arrow.down.doc").frame(minWidth: 220)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .help("⌘E")
            .disabled(blocker != nil || editor.isBuilding || set.isBuilding || (set.isOn && set.problem != nil))
            if set.isOn { StyleSetStatus(set: set) } else { BuildStatus(editor: editor) }
            if let blocker {
                Text(blocker).font(.callout).foregroundStyle(.orange)
            }
            if let problem = set.isOn ? set.exportProblem : editor.exportProblem {
                Text(problem).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .onChange(of: editor.exportRequest, initial: true) { _, request in
            guard let request else { return }
            editor.exportRequest = nil
            Task { await export(again: request == .again) }
        }
    }

    private func export(again: Bool) async {
        let set = app.styleSet(for: editor)
        if set.isOn { return await exportSet(set) }
        guard exportBlocker(app, editor) == nil, !editor.isBuilding else { return }
        // Read before the build, which clears the export it replaces.
        let previous = editor.exportDestination == .savedFile ? editor.exportCheck?.fontURL : nil
        if editor.startBuildIfNeeded() { await editor.buildSettled() }
        guard let outcome = editor.outcome, !editor.outcomeIsStale else { return }
        // The review's decisions keep the font's name: the place chosen for
        // it the first time is the place for the corrected file.
        let url: URL
        if again, let previous, previous.lastPathComponent == outcome.result.fileName {
            url = previous
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = outcome.result.fileName
            panel.allowedContentTypes = [UTType(filenameExtension: "ttf") ?? .font]
            panel.canCreateDirectories = true
            let stem = (outcome.result.fileName as NSString).deletingPathExtension
            panel.message =
                editor.hasLicenseText
                ? "配方與授權全文會一併存成同一資料夾的 \(stem).json、\(EditorModel.licenseFileName(stem: stem, license: editor.entry.license))"
                : "配方會一併存成同一資料夾的 \(stem).json"
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }
        // The panel already chose the destination: the written file is the export.
        guard let check = await editor.writeExport(to: url) else { return }
        editor.markExported(check, to: .savedFile)
        if app.installTarget == .mac {
            await app.installed.install(url)
        }
    }

    /// The set goes into a folder the user picks, each file under its own
    /// name; files of those names already there are replaced only once the
    /// user says so (a folder panel, unlike a save panel, does not ask).
    private func exportSet(_ set: StyleSetModel) async {
        guard exportBlocker(app, editor) == nil, !set.isBuilding, set.problem == nil else { return }
        guard await set.buildIfNeeded(draft: editor.draft, rightsConfirmed: editor.rightsConfirmed) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "存到這裡"
        panel.message = "\(set.built.count) 個字型與各自的配方會存進選的資料夾"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let taken = set.built.flatMap { one in
            [one.result.fileName, (one.result.fileName as NSString).deletingPathExtension + ".json"]
        }.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        if !taken.isEmpty {
            let alert = NSAlert()
            alert.messageText = "要取代資料夾裡同名的 \(taken.count) 個檔案嗎？"
            alert.informativeText = taken.joined(separator: "、")
            alert.addButton(withTitle: "取代")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        guard let checks = await set.writeExport(to: folder, text: editor.sampleText) else { return }
        set.markExported(checks, to: .savedFile)
        guard app.installTarget == .mac else { return }
        var failed: [String] = []
        for check in checks {
            await app.installed.install(check.fontURL)
            if case .failed(let reason)? = app.installed.lastInstall?.state {
                failed.append("\(check.fontURL.lastPathComponent)：\(reason)")
            }
        }
        set.installSummary =
            failed.isEmpty
            ? "已安裝 \(checks.count) 個字型到這台 Mac。" : "有 \(failed.count) 個沒裝上：" + failed.joined(separator: "；")
    }
}
