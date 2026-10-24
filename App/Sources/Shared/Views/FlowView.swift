import SwiftUI
import UniformTypeIdentifiers

/// The window: ① 挑字型 → ② 調整 → ③ 匯出並安裝 (plan, Phase 4e). The steps
/// are the navigation; with 「每次都分三步走」 off, ② and ③ are one screen and
/// ① is reached through 換字型.
struct FlowView: View {
    @Bindable var app: AppModel
    @AppStorage(AppModel.Key.threeSteps) private var threeSteps = true
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if threeSteps {
                StepBar(app: app)
                Divider()
            }
            Group {
                if app.step == .pick {
                    PickStep(app: app)
                } else if let editor = app.currentEditor {
                    EditorSteps(app: app, editor: editor, threeSteps: threeSteps).id(editor.entry.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Any file, not only fonts: picking an .otf, .ttc or .woff must show
        // why it is refused rather than being greyed out.
        .fileImporter(isPresented: $app.importRequested, allowedContentTypes: [.item], allowsMultipleSelection: true) {
            result in
            switch result {
            case .success(let urls): Task { await app.importFonts(urls) }
            case .failure(let error): app.library.problems = [error.localizedDescription]
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await app.importFonts(urls) }
            return !urls.isEmpty
        } isTargeted: {
            dropTargeted = $0
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 3).padding(6)
                    .allowsHitTesting(false)
            }
        }
        .alert(
            "有檔案無法匯入",
            isPresented: Binding(
                get: { !app.library.problems.isEmpty }, set: { if !$0 { app.library.problems = [] } })
        ) {
            Button("好") { app.library.problems = [] }
        } message: {
            Text(app.library.problems.joined(separator: "\n\n"))
        }
        .alert(
            "這套字型的授權禁止修改",
            isPresented: Binding(get: { app.refusedFont != nil }, set: { if !$0 { app.refusedFont = nil } })
        ) {
            Button("好") { app.refusedFont = nil }
        } message: {
            Text("「\(app.refusedFont?.displayName ?? "")」的 OS/2 fsType 設有 Restricted License，FontsMaker 不會處理它。")
        }
        .safeAreaInset(edge: .bottom) {
            if let problem = app.startupProblem {
                Text(problem)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
        }
    }
}

/// ① ② ③ across the top; a step can be gone back to, and forward once a
/// font is picked.
struct StepBar: View {
    @Bindable var app: AppModel
    @CompactWidth private var isCompact

    var body: some View {
        HStack(spacing: 0) {
            ForEach(FlowStep.allCases, id: \.self) { step in
                Button {
                    app.go(to: step)
                } label: {
                    HStack(spacing: 8) {
                        Text(String(step.rawValue + 1))
                            .font(.callout.weight(.bold))
                            .frame(width: 26, height: 26)
                            .foregroundStyle(step <= app.step ? .white : .secondary)
                            .background(
                                step <= app.step ? Color.accentColor : Color.secondary.opacity(0.2), in: Circle())
                        Text(step.title)
                            .font(
                                isCompact
                                    ? .callout.weight(step == app.step ? .semibold : .regular)
                                    : .title3.weight(step == app.step ? .semibold : .regular)
                            )
                            .foregroundStyle(step == app.step ? .primary : .secondary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!app.canGo(to: step))
                .accessibilityLabel("第 \(step.rawValue + 1) 步：\(step.title)")
                .accessibilityAddTraits(step == app.step ? .isSelected : [])
                if step != .export {
                    Rectangle().fill(.quaternary).frame(width: isCompact ? 16 : 60, height: 2)
                        .padding(.horizontal, isCompact ? 6 : 14)
                }
            }
        }
        .padding(.vertical, isCompact ? 8 : 14)
        .padding(.horizontal)
        .frame(maxWidth: .infinity)
    }
}

/// ② and ③ of one font, once it has loaded: as two steps, or as one screen
/// when the three steps are off.
private struct EditorSteps: View {
    @Bindable var app: AppModel
    @Bindable var editor: EditorModel
    let threeSteps: Bool
    /// App-wide, one per kind of font: the text a user typed to check CJK
    /// fonts with is no test of a Latin font, which would draw it as empty
    /// boxes. Empty while the user has not typed one: the font then shows its
    /// own default, English for a Latin font (`EditorModel`).
    @AppStorage("preview.sampleText") private var savedSampleText = ""
    @AppStorage("preview.sampleText.latin") private var savedLatinSampleText = ""

    var body: some View {
        Group {
            switch editor.loading {
            case .loading:
                ProgressView("讀取字型…")
            case .failed(let message):
                ContentUnavailableView(
                    "無法讀取字型", systemImage: "exclamationmark.triangle", description: Text(message))
            case .loaded:
                if !threeSteps {
                    CombinedEditor(app: app, editor: editor)
                } else if app.step == .export {
                    ExportStep(app: app, editor: editor)
                } else {
                    AdjustStep(app: app, editor: editor)
                }
            }
        }
        // A font's default is not the user's text: kept, it would follow to the next font.
        .onChange(of: editor.sampleText) { _, text in
            let saved = text == editor.defaultSampleText ? "" : text
            if editor.fontHasCJK { savedSampleText = saved } else { savedLatinSampleText = saved }
        }
        .task {
            // Read before loading: the kind of font is known once it has
            // loaded, and load's switch to the font's default clears its key.
            let cjk = savedSampleText
            let latin = savedLatinSampleText
            await editor.load()
            let saved = editor.fontHasCJK ? cjk : latin
            if !saved.isEmpty { editor.sampleText = saved }
        }
    }
}

/// True where the layout has to stack: an iPhone, or an iPad app in a
/// narrow split. A Mac window is always laid out wide.
@propertyWrapper
struct CompactWidth: DynamicProperty {
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var wrappedValue: Bool {
        #if os(iOS)
            sizeClass == .compact
        #else
            false
        #endif
    }
}
