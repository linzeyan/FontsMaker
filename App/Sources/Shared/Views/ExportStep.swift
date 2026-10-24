import FontsMakerKit
import SwiftUI

/// ③: where the font goes, its name, one button that builds and saves, and
/// then what to do with the file. Beside it, the page as the font shows it.
struct ExportStep: View {
    @Bindable var app: AppModel
    @Bindable var editor: EditorModel
    @CompactWidth private var isCompact

    var body: some View {
        if isCompact {
            ScrollView {
                ExportPanel(app: app, editor: editor, showsBack: true).padding()
            }
            // For the UI flows, which scroll the controls to what they tap.
            .accessibilityIdentifier("controls")
        } else {
            HStack(alignment: .top, spacing: 28) {
                ScrollView {
                    ExportPanel(app: app, editor: editor, showsBack: true)
                        .padding(.vertical, 24)
                        .frame(maxWidth: 640, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("controls")
                ResultPreview(editor: editor).frame(width: 300).padding(.vertical, 24)
            }
            .padding(.horizontal, 28)
        }
    }
}

/// ② and ③ on one screen, for whoever turned the three steps off: the page,
/// the effects, and the export controls under them.
struct CombinedEditor: View {
    @Bindable var app: AppModel
    @Bindable var editor: EditorModel
    @CompactWidth private var isCompact

    var body: some View {
        if isCompact {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    header.padding(.horizontal).padding(.vertical, 8)
                    PreviewPane(editor: editor).frame(height: proxy.size.height * 0.45)
                    Divider()
                    ScrollView { controls.padding() }.accessibilityIdentifier("controls")
                }
            }
        } else {
            HStack(alignment: .top, spacing: 28) {
                PreviewPane(editor: editor).padding(.vertical, 16)
                VStack(alignment: .leading, spacing: 12) {
                    header
                    ScrollView { controls }.accessibilityIdentifier("controls")
                }
                .frame(width: 400)
                .padding(.vertical, 20)
            }
            .padding(.horizontal, 28)
        }
    }

    private var header: some View {
        HStack {
            Text(editor.entry.displayName).font(isCompact ? .title2.weight(.bold) : .title.weight(.bold)).lineLimit(1)
            Spacer()
            Button("換字型", systemImage: "square.grid.2x2") { app.goBack() }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            EffectCards(editor: editor)
            Divider()
            ExportPanel(app: app, editor: editor, showsBack: false)
        }
    }
}

/// Why 做出字型並存檔 cannot run yet, in the order the screen asks for it.
@MainActor func exportBlocker(_ app: AppModel, _ editor: EditorModel) -> String? {
    if app.installTarget == nil { return "先選要放到哪裡讀。" }
    if editor.nameProblem != nil { return "字型名稱需要修改，見上方「字型名稱」。" }
    return editor.licenseProblem
}

private struct ExportPanel: View {
    @Bindable var app: AppModel
    @Bindable var editor: EditorModel
    let showsBack: Bool
    @CompactWidth private var isCompact

    var body: some View {
        let set = app.styleSet(for: editor)
        VStack(alignment: .leading, spacing: 20) {
            Text("要放到哪裡讀？").font(isCompact || !showsBack ? .title2.weight(.bold) : .largeTitle.weight(.bold))
            TargetPicker(target: $app.installTarget)
            NameDisclosure(
                editor: editor,
                setStyles: set.isOn ? StyleRole.allCases.filter { set.chosen[$0] != nil }.map(\.styleName) : nil)
            StyleSetSection(set: set, editor: editor)
            if editor.entry.license == .unknown {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("我確認有權修改並散布這套字型", isOn: $editor.rightsConfirmed)
                        #if os(macOS)
                            .toggleStyle(.checkbox)
                        #endif
                    Text("FontsMaker 認不出這套字型的授權（不是 OFL）。").font(.caption).foregroundStyle(.secondary)
                }
            }
            ExportActions(app: app, editor: editor)
            if set.isOn {
                StyleSetDone(set: set, editor: editor)
            } else if editor.exportCheck != nil {
                // Where ③'s page beside it is not on screen, the done view shows the file's own.
                ExportDone(app: app, editor: editor, showsPage: isCompact || !showsBack)
            }
            if showsBack {
                Button("上一步：調整") { app.goBack() }
            }
        }
        // Again when the library changes, since an import may complete the
        // family, and once the font is known to be Latin (a CJK variable
        // font's default instance takes seconds to read).
        .task(id: "\(editor.fontHasCJK) " + app.library.entries.map(\.id).joined(separator: ",")) {
            if !editor.fontHasCJK { await set.search() }
        }
    }
}

/// The places a font is read in, as large tiles; the choice is remembered.
private struct TargetPicker: View {
    @Binding var target: InstallTarget?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], alignment: .leading, spacing: 12) {
            ForEach(InstallTarget.available) { item in
                let selected = target == item
                Button {
                    target = item
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: item.symbol).font(.title)
                        Text(item.title).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 84)
                    .contentShape(Rectangle())
                    .background(
                        selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10).strokeBorder(
                            selected ? Color.accentColor : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// The names, folded away: they are suggested, and checked by the engine's
/// rules; it opens by itself when they need changing.
private struct NameDisclosure: View {
    @Bindable var editor: EditorModel
    /// The styles a family export writes, each with its own style name;
    /// nil when one font is exported.
    let setStyles: [String]?
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("英文名稱", text: $editor.draft.familyName, prompt: Text("例如 Ebook Kai"))
                TextField("中文名稱（選填）", text: $editor.draft.localizedFamilyName, prompt: Text("例如 電子書楷"))
                if setStyles == nil {
                    // Labelled beside it: outside a Form, an iOS menu picker shows only its value.
                    LabeledContent("樣式") {
                        Picker("樣式", selection: $editor.draft.styleName) {
                            ForEach(editor.styleChoices, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                } else {
                    Text("每一份照下面選的樣式命名。").font(.caption).foregroundStyle(.secondary)
                }
                if let problem = editor.nameProblem {
                    Label(problem, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.callout)
                }
                // Product spec §4.3: names reserved outside the font file cannot be checked.
                Text("若要散布，請確認名稱沒有用到原作者保留的名稱（RFN），他們常只寫在授權或說明檔裡。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #if os(macOS)
                .textFieldStyle(.roundedBorder)
            #endif
            .padding(.top, 6)
        } label: {
            Text(label).foregroundStyle(editor.nameProblem == nil ? Color.primary : .orange)
        }
        .onChange(of: editor.nameProblem != nil, initial: true) { _, problem in
            if problem { expanded = true }
        }
    }

    private var label: String {
        let draft = editor.draft
        if editor.nameProblem != nil { return "字型名稱：需要修改" }
        if let setStyles { return "字型名稱：\(draft.familyName)（\(setStyles.joined(separator: "／"))）" }
        return "字型名稱：\(draft.familyName) \(draft.styleName)"
    }
}

/// A running build's progress with its cancel button, or how the last one ended.
struct BuildStatus: View {
    let editor: EditorModel

    var body: some View {
        switch editor.build {
        case .running(let completed, let total):
            HStack {
                if total > 0 && completed < total {
                    ProgressView(value: Double(completed), total: Double(total)) {
                        Text("加粗 \(completed.formatted()) / \(total.formatted()) 字形")
                    }
                } else {
                    ProgressView { Text(total > 0 ? "寫出字型…" : "準備中…") }
                }
                Button("取消", role: .cancel) { editor.cancelBuild() }
            }
            .frame(maxWidth: 480)
        case .failed(let message):
            Text("做不出字型：\(message)").font(.callout).foregroundStyle(.red).textSelection(.enabled)
        case .cancelled:
            Text("已取消。").font(.callout).foregroundStyle(.secondary)
        case .idle, .finished:
            EmptyView()
        }
    }
}

/// After the files left the app: where they are, what to do with them on
/// the device chosen, risky glyphs to look at, and the details a P2 user
/// checks, folded away.
private struct ExportDone: View {
    @Bindable var app: AppModel
    @Bindable var editor: EditorModel
    let showsPage: Bool
    @State private var showsReview = false
    @StoredPageSettings private var settings

    var body: some View {
        if let check = editor.exportCheck, let destination = editor.exportDestination {
            VStack(alignment: .leading, spacing: 14) {
                Label(saved(check, destination), systemImage: "checkmark.circle.fill")
                    .font(.title3.weight(.semibold)).foregroundStyle(.green)
                Text(place(check, destination)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                licenseNote(check)
                if editor.outcomeIsStale {
                    Text("設定在匯出後改過了；再按一次「做出字型並存檔」，存出的才是現在的設定。")
                        .font(.callout).foregroundStyle(.orange)
                }
                #if os(macOS)
                    if app.installTarget == .mac {
                        InstallStatus(installed: app.installed, exportedFile: check.fontURL)
                    }
                #endif
                riskNotice
                // What to do next comes before the page, which on a phone fills the screen.
                if let target = app.installTarget, guideApplies(target, check) {
                    InstallGuide(target: target)
                }
                if showsPage && !editor.outcomeIsStale {
                    PageView(page: check.page, settings: settings, orientation: editor.exportOrientation)
                        .frame(maxWidth: 320)
                        .accessibilityIdentifier("exportPage")
                    Text("由 CoreText 讀取匯出的字型檔排版、繪製。").font(.caption).foregroundStyle(.secondary)
                }
                FileDetails(editor: editor, check: check, destination: destination)
            }
            .sheet(isPresented: $showsReview) {
                RiskReviewSheet(editor: editor) { showsReview = false }
            }
        }
    }

    /// This Mac's steps say the font is installed: only once it is.
    private func guideApplies(_ target: InstallTarget, _ check: ExportCheck) -> Bool {
        #if os(macOS)
            if target == .mac,
                case .installed? = app.installed.lastInstall.flatMap({
                    $0.exportedFile == check.fontURL ? $0.state : nil
                })
            {
                return true
            }
            return target != .mac
        #else
            return true
        #endif
    }

    /// Files may have saved under another name than the one offered.
    private func saved(_ check: ExportCheck, _ destination: ExportDestination) -> String {
        switch destination {
        case .files(_, let font?, _, _): "已存好 \(font)"
        case .files: "已存好字型與配方"
        case .savedFile, .shared: "已存好 \(check.fontURL.lastPathComponent)"
        }
    }

    private func place(_ check: ExportCheck, _ destination: ExportDestination) -> String {
        /// "配方 X、授權全文 Y": what went beside the font, by the names they were saved under.
        func beside(recipe: String?, license: String?) -> String {
            let license = check.licenseURL == nil ? nil : "授權全文" + (license.map { " \($0)" } ?? "")
            return (["配方" + (recipe.map { " \($0)" } ?? "")] + [license].compactMap { $0 }).joined(separator: "、")
        }
        switch destination {
        case .savedFile:
            return
                "在 \(check.fontURL.deletingLastPathComponent().path)，\(beside(recipe: check.recipeURL.lastPathComponent, license: check.licenseURL?.lastPathComponent)) 在同一個資料夾。"
        case .files(let folder, _, let recipe, let license):
            return "存到「\(ExportDestination.path(folder))」，\(beside(recipe: recipe, license: license)) 在同一個資料夾。"
        case .shared(let activity):
            return "分享給「\(ExportDestination.activityName(activity))」；存到哪裡由接收的 App 決定，FontsMaker 無從得知。"
        }
    }

    /// The OFL lets the font be passed on only with its license (condition
    /// 2): said whether the export carries it, and what to do when not.
    @ViewBuilder private func licenseNote(_ check: ExportCheck) -> some View {
        if check.licenseURL != nil {
            Label("已附上來源字型的授權全文；轉給別人時，請連同它一起給。", systemImage: "doc.text")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Label(
                "沒有附上授權全文：這套字型是從檔案匯入的，FontsMaker 沒有它的授權檔。要轉給別人時，請附上原作者的授權"
                    + (editor.entry.licenseURL.map { "（\($0)）" } ?? "") + "。",
                systemImage: "exclamationmark.triangle"
            )
            .font(.callout).foregroundStyle(.orange)
        }
    }

    /// Glyphs whose bolding may have filled in their counters (grades A and B).
    @ViewBuilder private var riskNotice: some View {
        if let outcome = editor.outcome {
            let risky = outcome.riskyGlyphs
            if risky > 0 {
                HStack {
                    Image(systemName: "eye")
                    Text("有 \(risky) 個字加粗後筆畫可能黏在一起")
                    Spacer(minLength: 8)
                    Button("檢查這些字") { showsReview = true }
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

/// The review as a sheet over ③; 套用並重新匯出 closes it and exports again.
private struct RiskReviewSheet: View {
    @Bindable var editor: EditorModel
    let close: () -> Void

    var body: some View {
        NavigationStack {
            RiskReviewView(
                editor: editor,
                apply: {
                    close()
                    editor.exportRequest = .again
                },
                // ① is under the sheet: close it first. The decisions so far
                // are in the draft, and 檢查這些字 opens the review again.
                browseChinese: editor.browseCatalog.map { browse in
                    {
                        close()
                        browse(.chinese)
                    }
                })
            .navigationTitle("檢查加粗後的字")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: close)
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 820, minHeight: 600)
        #endif
    }
}

private struct InstallGuide: View {
    let target: InstallTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(target == .fileOnly ? "接下來" : "接下來：放進\(target.title)").font(.headline)
                if target.needsDeviceCheck {
                    Text("步驟待實機驗證")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .foregroundStyle(.secondary)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
            }
            ForEach(Array(target.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(String(index + 1)).font(.callout.weight(.bold)).frame(width: 22, height: 22)
                        .background(Color.accentColor.opacity(0.15), in: Circle())
                    Text(step).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// CoreText's check of the written file (product spec §4.6), its hash, the
/// recipe's path and the build's step reports.
private struct FileDetails: View {
    let editor: EditorModel
    let check: ExportCheck
    let destination: ExportDestination

    var body: some View {
        DisclosureGroup("檔案資訊") {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("CoreText").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Label(
                                "已載入「\(check.fullName)」；\(check.matchingGlyphs)/\(check.checkedGlyphs) 個字的字形與預覽相同",
                                systemImage: check.matchingGlyphs == check.checkedGlyphs
                                    ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(check.matchingGlyphs == check.checkedGlyphs ? .green : .orange)
                            if let note = checkedCopyNote {
                                Text(note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    GridRow {
                        Text("字型檔").foregroundStyle(.secondary)
                        Text(shown(check.fontURL)).textSelection(.enabled)
                    }
                    GridRow {
                        Text("配方").foregroundStyle(.secondary)
                        Text(shown(check.recipeURL)).textSelection(.enabled)
                    }
                    GridRow {
                        Text("授權全文").foregroundStyle(.secondary)
                        Text(check.licenseURL.map(shown) ?? "沒有附上").textSelection(.enabled)
                    }
                    GridRow {
                        Text("sha256").foregroundStyle(.secondary)
                        Text(check.sha256).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    if let outcome = editor.outcome {
                        GridRow {
                            Text("建置").foregroundStyle(.secondary)
                            Text(
                                "\(ByteCountFormatter.string(fromByteCount: Int64(outcome.result.fontData.count), countStyle: .file))，\(outcome.seconds.formatted(.number.precision(.fractionLength(1)))) 秒"
                            )
                        }
                    }
                }
                .font(.callout)
                if let outcome = editor.outcome {
                    Text("步驟報告").font(.callout.weight(.semibold))
                    let font = SwiftUI.Font(Specimen.reportFont(source: editor.fontURL, size: 11))
                    ForEach(Array(outcome.result.reports.enumerated()), id: \.offset) { _, report in
                        // The s2t phrases line runs to several hundred
                        // characters: it must wrap, never truncate.
                        Text(report.summary).font(font).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    /// A saved file is the file the check read, so its path says where it
    /// is. Files and the share sheet got a copy of a staged file, whose path
    /// means nothing to the user; the line above says where they went.
    private func shown(_ url: URL) -> String {
        destination == .savedFile ? url.path : url.lastPathComponent
    }

    /// The check cannot read what Files saved or the share sheet sent, only
    /// the staged file they copied. The sha256 shown is of those same bytes.
    private var checkedCopyNote: String? {
        switch destination {
        case .savedFile: nil
        case .files: "檢查的是 App 內交給「檔案」前的那一份，與存出的檔案位元組相同（sha256 同上）。"
        case .shared: "檢查的是 App 內分享前的那一份，與分享出去的檔案位元組相同（sha256 同上）。"
        }
    }
}

/// The product as a small page beside ③: CoreText's rendering of the
/// exported file once it is current, the live preview until then.
private struct ResultPreview: View {
    @Bindable var editor: EditorModel
    @StoredPageSettings private var settings

    var body: some View {
        let exported = editor.exportCheck.flatMap { editor.outcomeIsStale ? nil : $0 }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(exported == nil ? "成品預覽" : "匯出的字型檔").font(.headline)
                Spacer()
                // Beside the title, not on the page: this page is narrow, and
                // a tag in its corner covered the end of the first line.
                if exported == nil && editor.previewPage != nil { PreviewUpdatingTag(editor: editor) }
            }
            PageView(
                page: exported?.page ?? editor.previewPage, settings: settings,
                orientation: exported == nil ? editor.previewOrientation : editor.exportOrientation
            )
            .accessibilityIdentifier(exported == nil ? "resultPreview" : "exportPage")
            .overlay {
                if exported == nil && editor.previewPage == nil { PreviewUpdating(editor: editor, hasPage: false) }
            }
            Text(exported == nil ? "引擎即時處理預覽用到的字。" : "由 CoreText 讀取匯出的字型檔排版、繪製。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
