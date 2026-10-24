import SwiftUI

/// A catalog font in ①. Once in the library it is drawn in itself and opens
/// in ② like any library font; before that its specimen is greyed system
/// type and the card downloads it, with progress, cancel and the reason
/// when it fails.
struct CatalogCard: View {
    @Bindable var app: AppModel
    let font: CatalogFont

    var body: some View {
        if let entry = app.downloads.entry(for: font) {
            let restricted = entry.license == .restricted
            Button {
                app.open(entry.id)
            } label: {
                content(entry: entry) {
                    Text("開始調整")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: Capsule())
                }
                .contentShape(Rectangle())
                .overlay {
                    if app.currentFontID == entry.id {
                        RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(restricted)
            .accessibilityLabel(font.name)
            .accessibilityIdentifier("fontCard")
            .modifier(LibraryFontMenu(app: app, entry: entry, title: font.name, isCatalog: true))
        } else {
            content(entry: nil) { DownloadControl(downloads: app.downloads, font: font) }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("catalogCard")
        }
    }

    private func content<Action: View>(entry: LibraryEntry?, @ViewBuilder action: () -> Action) -> some View {
        let file = entry.flatMap { Specimen.font(app.library.fontURL(for: $0), size: 30) }
        let specimen =
            font.script == .chinese ? Specimen.chinese : font.latinGroup == .mono ? Specimen.mono : Specimen.latin
        return VStack(alignment: .leading, spacing: 8) {
            Text(specimen)
                // Before the download, the system's monospaced face: the
                // Mono group reads as monospaced before any font is fetched.
                .font(
                    file.map { SwiftUI.Font($0) }
                        ?? .system(size: 30, design: font.latinGroup == .mono ? .monospaced : .default))
                .foregroundStyle(file == nil ? .secondary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                // Clear of the ⋯ button a downloaded font's card has there.
                .padding(.trailing, LibraryFontMenu.buttonSize)
            HStack(alignment: .firstTextBaseline) {
                Text(font.name).font(.headline).lineLimit(1)
                Text(font.style).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if font.variable { Text("可選粗細").font(.caption2).foregroundStyle(.secondary) }
                if font.collection { Text("多套字形").font(.caption2).foregroundStyle(.secondary) }
            }
            Text(font.blurb).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Text("OFL · \(font.publisher)").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                action()
            }
            if entry == nil { DownloadStatus(downloads: app.downloads, font: font) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

extension Int {
    /// "9.4 MB", as the system writes file sizes.
    var byteCountText: String { Int64(self).formatted(.byteCount(style: .file)) }
}

/// 下載 with the size, or 取消 while it runs.
private struct DownloadControl: View {
    @Bindable var downloads: FontDownloads
    let font: CatalogFont

    var body: some View {
        if case .downloading = downloads.catalog[font.id] {
            Button("取消", systemImage: "xmark.circle.fill") { downloads.cancel(font) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .accessibilityLabel("取消下載「\(font.name)」")
        } else {
            Button("下載 · \(font.byteCount.byteCountText)") {
                downloads.dismissFailure(font)
                downloads.download(font)
            }
            .controlSize(.small)
            .accessibilityLabel("下載「\(font.name)」")
        }
    }
}

/// Progress under the card, or why it failed; the size up front when it is large.
private struct DownloadStatus: View {
    @Bindable var downloads: FontDownloads
    let font: CatalogFont

    var body: some View {
        switch downloads.catalog[font.id] {
        case .downloading(let received, let total)?:
            let total = total ?? Int64(font.byteCount)
            ProgressView(value: Double(received), total: Double(max(total, 1))) {
                Text("下載中 \(Int(received).byteCountText) / \(Int(total).byteCountText)")
                    .font(.caption2).monospacedDigit()
            }
        case .failed(let message)?:
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case nil:
            if font.isLarge {
                Text("檔案較大（\(font.byteCount.byteCountText)），網路慢時要等好幾分鐘。")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }
}

/// What a library font's card offers, in its context menu (right click on
/// the Mac, long press on iOS, which has no right click) and in a ⋯ button
/// on the card, which is there to be found: 編輯 (開始調整 for a catalog
/// font), 重新命名… for the user's own fonts, 在 Finder 中顯示 on the Mac,
/// 查看授權全文 for a font that came with one, and 刪除… — 移除下載… for a
/// catalog font, which can be downloaded again.
struct LibraryFontMenu: ViewModifier {
    @Bindable var app: AppModel
    let entry: LibraryEntry
    /// The name on the card: the catalog's for a catalog font.
    let title: String
    let isCatalog: Bool
    @State private var showsLicense = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmsRemoval = false
    @State private var removalProblem: String?

    #if os(macOS)
        static let buttonSize: CGFloat = 28
    #else
        /// A finger's width.
        static let buttonSize: CGFloat = 44
    #endif

    func body(content: Content) -> some View {
        let license = app.library.licenseText(for: entry)
        content
            .contextMenu { items(hasLicense: license != nil) }
            .overlay(alignment: .topTrailing) {
                Menu {
                    items(hasLicense: license != nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .imageScale(.large)
                        .frame(width: LibraryFontMenu.buttonSize, height: LibraryFontMenu.buttonSize)
                        .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
                .buttonStyle(.borderless)
                .fixedSize()
                .padding(4)
                .accessibilityLabel("「\(title)」的更多動作")
            }
            .sheet(isPresented: $showsLicense) {
                if let license { LicenseSheet(text: license, title: title) }
            }
            .alert("重新命名", isPresented: $renaming) {
                TextField("名稱", text: $newName)
                Button("取消", role: .cancel) {}
                Button("儲存") { app.rename(entry.id, to: newName) }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("只改字型庫裡顯示的名稱；字型檔裡的名稱與匯出時建議的名稱都不變。")
            }
            .confirmationDialog(
                isCatalog ? "移除「\(title)」的下載？" : "刪除「\(title)」？", isPresented: $confirmsRemoval,
                titleVisibility: .visible
            ) {
                Button(isCatalog ? "移除下載" : "刪除", role: .destructive) {
                    do {
                        try app.remove(entry.id)
                    } catch {
                        removalProblem = error.localizedDescription
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(removalMessage)
            }
            .alert(
                "無法刪除「\(title)」",
                isPresented: Binding(get: { removalProblem != nil }, set: { if !$0 { removalProblem = nil } })
            ) {
                Button("好") { removalProblem = nil }
            } message: {
                Text(removalProblem ?? "")
            }
    }

    @ViewBuilder private func items(hasLicense: Bool) -> some View {
        Button(isCatalog ? "開始調整" : "編輯", systemImage: "slider.horizontal.3") { app.open(entry.id) }
            .disabled(entry.license == .restricted)
        if !isCatalog {
            Button("重新命名…", systemImage: "pencil") {
                newName = entry.displayName
                renaming = true
            }
        }
        #if os(macOS)
            Button("在 Finder 中顯示", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([app.library.fontURL(for: entry)])
            }
        #endif
        if hasLicense {
            Button("查看授權全文", systemImage: "doc.text") { showsLicense = true }
        }
        Divider()
        Button(isCatalog ? "移除下載…" : "刪除…", systemImage: "trash", role: .destructive) { confirmsRemoval = true }
    }

    private var removalMessage: String {
        let kept: String
        #if os(macOS)
            kept = "已經匯出的檔案與安裝到這台 Mac 的字型不受影響。"
        #else
            kept = "已經匯出的檔案不受影響。"
        #endif
        let gone = "字型檔、調整到一半的設定與授權全文都會從 FontsMaker 刪除"
        return isCatalog ? "\(gone)，之後可以再下載。\(kept)" : "\(gone)，無法復原。\(kept)"
    }
}

private struct LicenseSheet: View {
    let text: String
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text).font(.callout.monospaced()).textSelection(.enabled).padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("「\(title)」的授權")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        #if os(macOS)
            .frame(minWidth: 560, minHeight: 480)
        #endif
    }
}

/// 從網址加入: a GitHub release lists its files, a zip with several fonts
/// asks which to add, and every font then meets the license gate (product
/// spec §4.2) as an imported file does.
struct LinkSheet: View {
    @Bindable var downloads: FontDownloads
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var chosen: Set<FontArchive.Member> = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("網址", text: $text, prompt: Text("https://github.com/…/releases/tag/…"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        #endif
                        .onSubmit(resolve)
                    Button("取得", action: resolve)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
                } footer: {
                    Text("GitHub release 頁面、字型檔（.ttf、.otf、.ttc）或 zip 的網址都可以。下載後一樣檢查授權：OFL 直接可用，認不出的要你確認有權修改，禁止修改的不會處理。")
                }
                step
            }
            .formStyle(.grouped)
            .navigationTitle("從網址加入")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isBusy ? "取消" : "關閉") {
                        downloads.cancelCustom()
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 520, minHeight: 420)
        #endif
        .onChange(of: downloads.lastImported) { dismiss() }
    }

    private var isBusy: Bool {
        switch downloads.custom {
        case .resolving, .downloading: true
        default: false
        }
    }

    private func resolve() {
        guard !isBusy else { return }
        downloads.resolve(text)
    }

    @ViewBuilder private var step: some View {
        switch downloads.custom {
        case .idle:
            EmptyView()
        case .resolving:
            Section { ProgressView("查詢 release…") }
        case .chooseAsset(let release):
            Section("\(release.owner)/\(release.repo) \(release.tag)：選一個檔案") {
                ForEach(release.assets) { asset in
                    Button {
                        downloads.fetch(asset, of: release)
                    } label: {
                        LabeledContent(asset.name, value: asset.byteCount.byteCountText)
                    }
                }
            }
        case .downloading(let name, let received, let total):
            Section {
                if let total {
                    ProgressView(value: Double(received), total: Double(max(total, 1))) {
                        Text("下載 \(name)：\(Int(received).byteCountText) / \(Int(total).byteCountText)")
                            .monospacedDigit()
                    }
                } else {
                    ProgressView { Text("下載 \(name)：\(Int(received).byteCountText)").monospacedDigit() }
                }
            }
        case .chooseFonts(let name, let members):
            Section("\(name) 裡有 \(members.count) 個字型檔，要加入哪些？") {
                ForEach(members, id: \.self) { member in
                    Toggle(
                        isOn: Binding(
                            get: { chosen.contains(member) },
                            set: { if $0 { chosen.insert(member) } else { chosen.remove(member) } })
                    ) {
                        LabeledContent(member.fileName, value: member.byteCount.byteCountText)
                    }
                }
                Button("加入 \(chosen.count) 個字型") {
                    downloads.importMembers(members.filter(chosen.contains))
                }
                .disabled(chosen.isEmpty)
            }
        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
    }
}
