import SwiftUI

/// The editor's main view (product spec §4.6): the sample text on an
/// e-reader page as large as the space allows. 成品 is the page the recipe
/// gives, from outlines the engine processed for just these characters and
/// updated as the controls change; 原字 is the same text, page settings and
/// orientation in the unmodified source font, so flipping between them shows
/// exactly what the steps change.
struct PreviewPane: View {
    @Bindable var editor: EditorModel
    @StoredPageSettings private var settings
    @State private var showsSource = false
    @State private var showsPageSettings = false
    /// The sample text is edited on the page itself, so it takes no room
    /// from the page the rest of the time.
    @State private var editingText = false
    @FocusState private var textFocused: Bool
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        PageColumn(spacing: 10, alignsTop: isCompact) {
            controls
            if showsPageSettings && !editingText {
                PageSettingsBar(settings: $settings, orientation: $editor.previewOrientation)
            }
            Group {
                if editingText { textEditor } else { page }
            }
            .layoutValue(key: IsPage.self, value: true)
            caption
        }
        .animation(.snappy(duration: 0.25), value: showsPageSettings)
        .padding(.horizontal)
        .padding(.bottom, 12)
        // A step changed: show what it did, not the source it leaves alone.
        .onChange(of: editor.draft.steps) { showsSource = false }
    }

    private var page: some View {
        PageView(
            page: showsSource ? editor.sourcePage : editor.previewPage, settings: settings,
            orientation: editor.previewOrientation
        )
        .accessibilityIdentifier("previewPage")
        .overlay {
            // The page underneath predates the change: veil it rather than
            // let it pass for the current settings. 原字 has no s2t to wait for.
            if editor.preparingPhraseRules && !showsSource {
                ZStack {
                    PageView.paper.opacity(0.75)
                    ProgressView("正在準備詞彙規則…")
                }
                .environment(\.colorScheme, .light)
            } else {
                PreviewUpdating(
                    editor: editor, hasPage: (showsSource ? editor.sourcePage : editor.previewPage) != nil)
            }
        }
    }

    private var textEditor: some View {
        TextEditor(text: $editor.sampleText)
            .focused($textFocused)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(12)
            .background(PageView.paper)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(.black.opacity(0.25)))
            // The paper stays paper in dark mode, and so must the text and caret on it.
            .environment(\.colorScheme, .light)
            .accessibilityIdentifier("sampleText")
            .onAppear { textFocused = true }
    }

    // MARK: Controls

    /// Above the page and as wide as it: the text on the left, 原字／成品 in
    /// the middle, the page settings on the right (a reader's "Aa").
    private var controls: some View {
        ZStack {
            if editingText {
                Text("預覽文字").font(.headline)
            } else {
                Picker("對照", selection: $showsSource) {
                    Text("原字").tag(true)
                    Text("成品").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(minWidth: 150)
                .fixedSize()
                .help("原字是來源字型原樣，成品套用目前的效果")
            }
            HStack {
                if editingText {
                    Button("還原預設") { editor.sampleText = editor.defaultSampleText }
                        .disabled(editor.sampleText == editor.defaultSampleText)
                } else {
                    iconButton("編輯預覽文字", systemImage: "character.cursor.ibeam", isOn: false) { startEditing() }
                }
                Spacer()
                if editingText {
                    Button("完成") { editingText = false }
                        .buttonStyle(.borderedProminent)
                } else {
                    iconButton("字級與版面", systemImage: "textformat.size", isOn: showsPageSettings) {
                        showsPageSettings.toggle()
                    }
                }
            }
        }
        #if os(iOS)
            .controlSize(.large)
        #endif
    }

    /// A glyph-only button with the platform's hit target (44 pt on iOS),
    /// tinted behind while what it toggles is shown.
    private func iconButton(
        _ title: String, systemImage: String, isOn: Bool, action: @escaping () -> Void
    ) -> some View {
        #if os(iOS)
            let side: CGFloat = 44
        #else
            let side: CGFloat = 28
        #endif
        return Button(action: action) {
            Image(systemName: systemImage)
                .imageScale(.large)
                .frame(width: side, height: side)
                .background(isOn ? Color.accentColor.opacity(0.15) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help(title)
    }

    private func startEditing() {
        showsSource = false
        editingText = true
    }

    /// What the page shows, in a line: what 原字 leaves out, or what 成品 applies.
    @ViewBuilder private var caption: some View {
        Group {
            if let problem = editor.previewProblem {
                Text(problem).foregroundStyle(.red)
            } else if !editingText {
                Text(showsSource ? sourceCaption : resultCaption).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var sourceCaption: String {
        let draft = editor.draft
        var unchanged: [String] = []
        if draft.replacement != nil { unchanged.append("英文未換字型") }
        if !draft.outlines.isEmpty { unchanged.append("字形未修改") }
        if draft.emboldenWeight > 0 { unchanged.append("未加粗") }
        if draft.emboldenWeight > 0 && !draft.borrowed.isEmpty { unchanged.append("沒有取用其他字型的字") }
        if draft.tracking != 0 { unchanged.append("字距原樣") }
        if draft.lineHeight != nil { unchanged.append("行高原樣") }
        if draft.s2t != nil { unchanged.append("簡體照原樣") }
        // On the turned page the source's CJK lies on its side: the problem
        // pseudoVertical solves.
        if draft.pseudoVertical != nil { unchanged.append("字未轉 90°，所以側躺") }
        let name = editor.entry.displayName
        return unchanged.isEmpty ? "\(name)原樣" : "\(name)原樣：" + unchanged.joined(separator: "、")
    }

    private var resultCaption: String {
        let draft = editor.draft
        var applied: [String] = []
        if let name = editor.replacementName { applied.append("英文換成 \(name)") }
        if !draft.outlines.isEmpty { applied.append("改了 \(draft.outlines.count) 個字的造型") }
        if draft.emboldenWeight > 0 {
            applied.append("加粗 \(Int(draft.emboldenWeight))" + (draft.widen ? "（字寬加寬）" : ""))
            // Risk review's 從另一套字型取代; it counts only with 加粗.
            if !draft.borrowed.isEmpty { applied.append("\(draft.borrowed.count) 個字取自其他字型") }
        }
        if draft.tracking != 0 { applied.append("字距 +\(draft.tracking)") }
        if let lineHeight = draft.lineHeight, let unitsPerEm = editor.sourceFont?.font.unitsPerEm {
            applied.append("行高 " + RecipeDraft.formatEm(lineHeight, unitsPerEm: Int(unitsPerEm)))
        }
        if let s2t = draft.s2t { applied.append(s2t.phrases ? "簡轉繁（依詞彙）" : "簡轉繁") }
        if draft.pseudoVertical != nil { applied.append("每字轉 90°") }
        return applied.isEmpty ? "還沒有套用效果，與原字相同" : "套用：" + applied.joined(separator: "、")
    }

    private var isCompact: Bool {
        #if os(iOS)
            sizeClass == .compact
        #else
            false
        #endif
    }
}

/// Over a live page while `EditorModel.isUpdatingPreview`: with no page yet
/// a spinner in the middle of the paper, otherwise a small 更新中 tag in the
/// corner over the last page, which stays readable. It fades in only once an
/// update has taken a moment, so the quick ones of a slider drag do not
/// flicker; it goes at once when the page lands.
struct PreviewUpdating: View {
    let editor: EditorModel
    let hasPage: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if hasPage {
                PreviewUpdatingTag(editor: editor).padding(8)
            } else {
                ProgressView(editor.sourceFont == nil ? "正在讀取字型…" : "正在排版預覽…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .fadingWhileUpdating(editor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        // The paper stays paper in dark mode.
        .environment(\.colorScheme, .light)
        .allowsHitTesting(false)
    }
}

/// The small 更新中 tag, for a page whose last version stays on screen. On
/// its own where the page is too narrow for the tag to sit in its top
/// margin (③'s, beside its title).
struct PreviewUpdatingTag: View {
    let editor: EditorModel

    var body: some View {
        Label {
            Text("更新中…")
        } icon: {
            ProgressView().controlSize(.small)
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
        .fadingWhileUpdating(editor)
    }
}

extension View {
    /// Shown while the preview updates, fading in only once an update has
    /// taken a moment, so the quick ones of a slider drag do not flicker.
    fileprivate func fadingWhileUpdating(_ editor: EditorModel) -> some View {
        let updating = editor.isUpdatingPreview
        return
            self
            .opacity(updating ? 1 : 0)
            .animation(updating ? .easeIn(duration: 0.2).delay(0.3) : nil, value: updating)
            .accessibilityHidden(!updating)
            .accessibilityIdentifier("previewUpdating")
    }
}

private struct IsPage: LayoutValueKey {
    static let defaultValue = false
}

/// A 3:4 page as large as the space allows, with the views above and below
/// it as wide as the page: controls that line up with its edges, a caption
/// that wraps at its width. Centred in the space; at the top on a phone, so
/// the page starts right under the step bar.
private struct PageColumn: Layout {
    var spacing: CGFloat
    var alignsTop: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Takes all the space it is offered, as the page would.
        let space = proposal.replacingUnspecifiedDimensions(by: CGSize(width: 360, height: 640))
        let frames = frames(in: CGRect(origin: .zero, size: space), subviews: subviews)
        let used = frames.reduce(CGRect.null) { $0.union($1) }
        return CGSize(width: proposal.width ?? used.width, height: proposal.height ?? used.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(in: bounds, subviews: subviews)) {
            subview.place(at: frame.origin, proposal: ProposedViewSize(frame.size))
        }
    }

    /// The views above and below a page that is short of room (②'s half
    /// screen on an iPhone) stay wide enough for the controls not to overlap.
    private func barWidth(_ pageWidth: CGFloat, in bounds: CGRect) -> CGFloat {
        max(pageWidth, min(bounds.width, 320))
    }

    private func frames(in bounds: CGRect, subviews: Subviews) -> [CGRect] {
        guard let pageIndex = subviews.firstIndex(where: { $0[IsPage.self] }) else { return [] }
        let gaps = spacing * CGFloat(max(subviews.count - 1, 0))
        func heights(at width: CGFloat) -> [CGFloat] {
            subviews.indices.map { index in
                index == pageIndex
                    ? 0
                    : subviews[index].sizeThatFits(ProposedViewSize(width: barWidth(width, in: bounds), height: nil))
                        .height
            }
        }
        // Twice: at the page's width the caption may wrap to more lines than
        // at the full width, leaving less height for the page.
        var width = bounds.width
        for _ in 0..<2 {
            let others = heights(at: width).reduce(0, +)
            width = max(0, min(bounds.width, (bounds.height - gaps - others) * 3 / 4))
        }
        var sizes = heights(at: width).map { CGSize(width: barWidth(width, in: bounds), height: $0) }
        sizes[pageIndex] = CGSize(width: width, height: width * 4 / 3)
        let total = sizes.reduce(gaps) { $0 + $1.height }
        var y = alignsTop ? bounds.minY : bounds.minY + max(0, (bounds.height - total) / 2)
        return sizes.map { size in
            defer { y += size.height + spacing }
            return CGRect(origin: CGPoint(x: bounds.midX - size.width / 2, y: y), size: size)
        }
    }
}
