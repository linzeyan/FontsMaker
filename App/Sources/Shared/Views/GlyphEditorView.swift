import FontsMakerKit
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// ②'s way into the glyph editor (Phase 4f): shown for fonts with Latin
/// letters or figures, and whenever the draft already redraws some.
struct GlyphEditCard: View {
    @Bindable var editor: EditorModel
    @State private var model: GlyphEditorModel?

    static func applies(to editor: EditorModel) -> Bool {
        guard let font = editor.sourceFont?.font else { return false }
        return !editor.draft.outlines.isEmpty || GlyphEditorModel.applies(to: font)
    }

    private var editedCharacters: String {
        editor.draft.outlines.keys.sorted { $0.unicodeScalars.first!.value < $1.unicodeScalars.first!.value }
            .joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("逐字修改造型").font(.headline)
                        Text("英文字母、數字與標點，一個字一個字改外框").font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "scribble.variable").frame(width: 24)
                }
                .accessibilityHidden(true)
                Spacer()
                Button(editor.draft.outlines.isEmpty ? "編輯字形…" : "繼續編輯…") {
                    model = GlyphEditorModel(editor: editor)
                }
                .disabled(editor.isApplyingStyle)
            }
            if !editor.draft.outlines.isEmpty {
                Text("已修改 \(editor.draft.outlines.count) 個字：\(editedCharacters)").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        #if os(macOS)
            .sheet(item: $model) { model in
                GlyphEditorView(model: model).frame(minWidth: 1040, idealWidth: 1180, minHeight: 700, idealHeight: 820)
            }
        #else
            .fullScreenCover(item: $model) { GlyphEditorView(model: $0) }
        #endif
    }
}

/// The editor itself: the characters, the canvas with nodes and handles,
/// side bearings, and the glyph in running text. On an iPhone it only shows
/// (plan: iPhone views, Mac and iPad edit).
struct GlyphEditorView: View {
    @Bindable var model: GlyphEditorModel
    @Environment(\.dismiss) private var dismiss
    @CompactWidth private var isCompact

    private var canEdit: Bool {
        #if os(iOS)
            UIDevice.current.userInterfaceIdiom != .phone
        #else
            true
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isCompact {
                VStack(spacing: 8) {
                    GlyphCanvas(model: model, editable: false).frame(height: 300)
                    PreviewStrip(model: model).frame(height: 56).padding(.horizontal)
                    if !canEdit {
                        Text("在 iPad 或 Mac 上可以修改外框。").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    GlyphGrid(model: model)
                }
            } else {
                HStack(spacing: 0) {
                    GlyphGrid(model: model).frame(width: 268)
                    Divider()
                    VStack(spacing: 10) {
                        if canEdit { ToolBar(model: model) }
                        GlyphCanvas(model: model, editable: canEdit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if canEdit { MetricsBar(model: model) }
                        PreviewStrip(model: model).frame(height: 64)
                    }
                    .padding(14)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("逐字修改造型").font(.title2.weight(.bold))
                Text(model.editor.entry.displayName).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if canEdit {
                Button {
                    model.undo()
                } label: {
                    Label("復原", systemImage: "arrow.uturn.backward")
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)
                Button {
                    model.redo()
                } label: {
                    Label("重做", systemImage: "arrow.uturn.forward")
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
            }
            Button("完成") {
                model.finishPen()
                dismiss()
            }
            // No Return shortcut: Return commits a side-bearing field, and
            // closing the editor on it lost the user's place mid-edit.
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// The characters the font has, in groups; a dot marks the redrawn ones.
private struct GlyphGrid: View {
    @Bindable var model: GlyphEditorModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(model.groups) { group in
                    Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 4)], spacing: 4) {
                        ForEach(group.characters, id: \.self) { character in
                            cell(character)
                        }
                    }
                }
            }
            .padding(12)
        }
        .accessibilityIdentifier("glyphGrid")
    }

    private func cell(_ character: Character) -> some View {
        let selected = model.selected == character
        let edited = model.isEdited(character)
        return Button {
            model.select(character)
        } label: {
            GlyphThumbnail(path: model.gridPath(character), font: model.font)
                .frame(height: 44)
                .frame(maxWidth: .infinity)
                .background(
                    selected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .overlay(alignment: .topTrailing) {
                    if edited { Circle().fill(Color.accentColor).frame(width: 6, height: 6).padding(4) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("字形 \(String(character))\(edited ? "，已修改" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A glyph fitted to its cell: the em from descender to ascender, centred.
private struct GlyphThumbnail: View {
    let path: CGPath?
    let font: FontsMakerKit.Font

    var body: some View {
        Canvas { context, size in
            guard let path else { return }
            let ascender = Double(font.hhea.ascender)
            let descender = Double(font.hhea.descender)
            let scale = size.height * 0.84 / (ascender - descender)
            let box = path.boundingBoxOfPath
            let x = size.width / 2 - (box.isNull ? 0 : box.midX) * scale
            let transform = CGAffineTransform(translationX: x, y: size.height * 0.08 + ascender * scale)
                .scaledBy(x: scale, y: -scale)
            context.fill(Path(path).applying(transform), with: .color(.primary))
        }
    }
}

private struct ToolBar: View {
    @Bindable var model: GlyphEditorModel

    var body: some View {
        HStack(spacing: 12) {
            Picker("工具", selection: $model.tool) {
                Label("選取", systemImage: "cursorarrow").tag(GlyphEditorModel.Tool.select)
                Label("加點", systemImage: "plus.circle").tag(GlyphEditorModel.Tool.addPoint)
                Label("鋼筆", systemImage: "pencil.tip").tag(GlyphEditorModel.Tool.pen)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("tools")
            Button(model.selectedNode?.smooth == true ? "改成尖角" : "改成平滑") { model.toggleSmooth() }
                .disabled(model.selectedNode == nil)
            Button("刪除點", role: .destructive) { model.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(model.selectedNode == nil)
            Spacer()
            Toggle("原字疊圖", isOn: $model.showsOriginal)
                .toggleStyle(.switch)
                .fixedSize()
            Button("還原這個字") { model.revert() }
                .disabled(model.working == model.original)
        }
        .font(.callout)
        .overlay(alignment: .bottomLeading) {
            if model.tool == .pen {
                Text(
                    model.pendingContour.isEmpty
                        ? "按一下放尖角點，按住拖曳拉出平滑點的把手。" : "按第一個點收尾；換工具時，三個點以上的輪廓會自動收尾。"
                )
                .font(.caption).foregroundStyle(.secondary)
                .offset(y: 20)
            }
        }
    }
}

/// Side bearings and advance in font units, and how close the editable
/// outline is to the source.
private struct MetricsBar: View {
    @Bindable var model: GlyphEditorModel

    var body: some View {
        HStack(spacing: 18) {
            field("左側邊距", value: model.leftSideBearing, keyPath: \.leftSideBearingField)
            field("右側邊距", value: model.rightSideBearing, keyPath: \.rightSideBearingField)
            field("字寬", value: model.working?.advance, keyPath: \.advanceField)
            Spacer()
            if let working = model.working {
                Text(
                    "\(working.nodeCount) 個點・與原字最多差 \(model.simplificationError.formatted(.number.precision(.fractionLength(1)))) 單位（字身 \(model.font.unitsPerEm)）"
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private func field(
        _ title: String, value: Int?, keyPath: ReferenceWritableKeyPath<GlyphEditorModel, Int>
    ) -> some View {
        LabeledContent(title) {
            MetricField(title: title, model: model, keyPath: keyPath)
                .disabled(value == nil)
        }
        .fixedSize()
    }
}

/// A number that is applied when it is committed (Return or leaving the
/// field), not on every keystroke: typing 40 must not make 4 a step of its
/// own, in the glyph or in the undo history.
private struct MetricField: View {
    let title: String
    let model: GlyphEditorModel
    let keyPath: ReferenceWritableKeyPath<GlyphEditorModel, Int>
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text)
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { if !focused { commit() } }
            .onChange(of: model[keyPath: keyPath], initial: true) { if !focused { show() } }
            .onChange(of: model.selected) { show() }
            #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
            #endif
    }

    /// The character the text was shown for: typing left behind when another
    /// character is picked is dropped, not applied to the new one.
    @State private var shownFor: Character?

    private func show() {
        text = String(model[keyPath: keyPath])
        shownFor = model.selected
    }

    private func commit() {
        if shownFor == model.selected, let value = Int(text.trimmingCharacters(in: .whitespaces)),
            value != model[keyPath: keyPath]
        {
            model[keyPath: keyPath] = value
        }
        show()
    }
}

/// Font units ↔ view points: y up in the font, down on screen.
private struct CanvasMapping {
    let scale: Double
    let originX: Double
    let baselineY: Double

    init(size: CGSize, font: FontsMakerKit.Font, advance: Int, ink: CGRect?) {
        let unitsPerEm = Double(font.unitsPerEm)
        let top = max(Double(font.hhea.ascender), ink.map { Double($0.maxY) } ?? 0) + unitsPerEm * 0.06
        let bottom = min(Double(font.hhea.descender), ink.map { Double($0.minY) } ?? 0) - unitsPerEm * 0.06
        let left = min(0, ink.map { Double($0.minX) } ?? 0) - unitsPerEm * 0.12
        let right = max(Double(advance), ink.map { Double($0.maxX) } ?? 0) + unitsPerEm * 0.12
        scale = min(size.width / (right - left), size.height / (top - bottom))
        originX = (size.width - (right - left) * scale) / 2 - left * scale
        baselineY = (size.height - (top - bottom) * scale) / 2 + top * scale
    }

    var transform: CGAffineTransform {
        CGAffineTransform(translationX: originX, y: baselineY).scaledBy(x: scale, y: -scale)
    }

    func view(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: originX + x * scale, y: baselineY - y * scale) }
    func view(_ p: OutlinePoint) -> CGPoint { view(Double(p.x), Double(p.y)) }
    func font(_ p: CGPoint) -> (x: Double, y: Double) { ((p.x - originX) / scale, (baselineY - p.y) / scale) }
    func fontPoint(_ p: CGPoint) -> OutlinePoint {
        let (x, y) = font(p)
        return OutlinePoint(x: Int(x.rounded()), y: Int(y.rounded()))
    }
}

/// The glyph being edited: metric lines, the source glyph faint behind it,
/// the outline, and its nodes (squares for corners, circles for smooth
/// nodes) with their handles.
private struct GlyphCanvas: View {
    @Bindable var model: GlyphEditorModel
    let editable: Bool
    @State private var pressing = false
    @State private var dragging = false
    // A press on the canvas takes the keyboard focus from the metrics
    // fields, so Delete removes the selected node instead of editing
    // whichever field last had focus.
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { proxy in
            let mapping = mapping(for: proxy.size)
            Canvas { context, size in
                draw(&context, size: size, mapping: mapping)
            }
            .contentShape(Rectangle())
            .gesture(editable ? press(mapping) : nil)
        }
        .focusable(editable)
        .focused($focused)
        .focusEffectDisabled()
        .defaultFocus($focused, true)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("glyphCanvas")
        .accessibilityLabel("字形 \(model.selected.map { String($0) } ?? "")")
    }

    private func mapping(for size: CGSize) -> CanvasMapping {
        CanvasMapping(
            size: size, font: model.font, advance: model.working?.advance ?? Int(model.font.unitsPerEm),
            ink: model.original?.inkBounds)
    }

    private func press(_ mapping: CanvasMapping) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let hitRadius = 9 / mapping.scale
                if !pressing {
                    pressing = true
                    focused = true
                    if model.tool == .select {
                        let (x, y) = mapping.font(value.startLocation)
                        if let target = model.target(atX: x, y: y, radius: hitRadius) {
                            model.beginDrag(target)
                            dragging = true
                        } else {
                            model.selection = nil
                        }
                    }
                }
                if dragging {
                    model.drag(
                        by: Int((value.translation.width / mapping.scale).rounded()),
                        Int((-value.translation.height / mapping.scale).rounded()),
                        breakingSmooth: optionDown)
                }
            }
            .onEnded { value in
                defer {
                    pressing = false
                    dragging = false
                }
                switch model.tool {
                case .select:
                    if dragging { model.endDrag() }
                case .addPoint:
                    let (x, y) = mapping.font(value.location)
                    model.addPoint(atX: x, y: y, radius: 12 / mapping.scale)
                case .pen:
                    let moved = hypot(
                        value.location.x - value.startLocation.x, value.location.y - value.startLocation.y)
                    model.penPress(
                        at: mapping.fontPoint(value.startLocation),
                        handle: moved > 4 ? mapping.fontPoint(value.location) : nil, radius: 10 / mapping.scale)
                }
            }
    }

    /// ⌥-dragging a handle breaks a smooth node into a corner, as in Illustrator.
    private var optionDown: Bool {
        #if os(macOS)
            NSEvent.modifierFlags.contains(.option)
        #else
            false
        #endif
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, mapping: CanvasMapping) {
        let font = model.font
        let advance = Double(model.working?.advance ?? 0)
        var guides = Path()
        for y in [0, Double(font.hhea.ascender), Double(font.hhea.descender)] {
            guides.move(to: mapping.view(-10_000, y))
            guides.addLine(to: mapping.view(10_000, y))
        }
        for x in [0, advance] {
            guides.move(to: mapping.view(x, Double(font.hhea.descender)))
            guides.addLine(to: mapping.view(x, Double(font.hhea.ascender)))
        }
        context.stroke(guides, with: .color(.secondary.opacity(0.45)), lineWidth: 1)

        if model.showsOriginal, let selected = model.selected, let source = model.sourcePaths[selected] {
            context.fill(Path(source).applying(mapping.transform), with: .color(.orange.opacity(0.16)))
        }
        guard let working = model.working else { return }
        let outline = Path(working.path).applying(mapping.transform)
        context.fill(outline, with: .color(.primary.opacity(model.tool == .pen ? 0.08 : 0.14)))
        context.stroke(outline, with: .color(.primary), lineWidth: 1.2)

        // Read-only (iPhone): the outline is what there is to see.
        guard editable else { return }
        var handles = Path()
        for contour in working.contours {
            for node in contour {
                for handle in [node.handleIn, node.handleOut].compactMap({ $0 }) {
                    handles.move(to: mapping.view(node.point))
                    handles.addLine(to: mapping.view(handle))
                }
            }
        }
        context.stroke(handles, with: .color(.blue.opacity(0.6)), lineWidth: 1)
        let selection = model.selection
        for (c, contour) in working.contours.enumerated() {
            for (n, node) in contour.enumerated() {
                let parts: [(GlyphEditorModel.Target.Part, OutlinePoint?)] = [
                    (.handleIn, node.handleIn), (.handleOut, node.handleOut),
                ]
                for (part, handle) in parts {
                    guard let handle else { continue }
                    let p = mapping.view(handle)
                    let chosen = selection == GlyphEditorModel.Target(contour: c, index: n, part: part)
                    let dot = Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7))
                    context.fill(dot, with: .color(chosen ? .accentColor : .blue))
                }
                let p = mapping.view(node.point)
                let chosen = selection?.contour == c && selection?.index == n
                let rect = CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)
                let shape = node.smooth ? Path(ellipseIn: rect) : Path(rect)
                context.fill(shape, with: .color(chosen ? .accentColor : Color(white: 0.98)))
                context.stroke(shape, with: .color(chosen ? .accentColor : .primary), lineWidth: 1.2)
            }
        }
        if !model.pendingContour.isEmpty {
            var pen = Path()
            let nodes = model.pendingContour
            pen.move(to: mapping.view(nodes[0].point))
            for index in nodes.indices.dropFirst() {
                let a = nodes[index - 1]
                let b = nodes[index]
                if a.handleOut == nil && b.handleIn == nil {
                    pen.addLine(to: mapping.view(b.point))
                } else {
                    pen.addCurve(
                        to: mapping.view(b.point), control1: mapping.view(a.handleOut ?? a.point),
                        control2: mapping.view(b.handleIn ?? b.point))
                }
            }
            context.stroke(pen, with: .color(.accentColor), lineWidth: 1.5)
            for node in nodes {
                let p = mapping.view(node.point)
                context.fill(Path(CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.accentColor))
            }
        }
    }
}

/// The glyph in running text, through the whole recipe (加粗 shows).
private struct PreviewStrip: View {
    @Bindable var model: GlyphEditorModel

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(PageView.paper))
            guard let preview = model.preview else { return }
            let text = GlyphEditorModel.previewText(for: model.selected)
            let ascender = Double(preview.hhea.ascender)
            let descender = Double(preview.hhea.descender)
            let scale = size.height * 0.8 / (ascender - descender)
            var x = 12.0
            for scalar in text.unicodeScalars {
                guard let glyph = preview.glyphs[scalar.value] else { continue }
                let transform = CGAffineTransform(translationX: x, y: size.height * 0.1 + ascender * scale)
                    .scaledBy(x: scale, y: -scale)
                context.fill(Path(glyph.path).applying(transform), with: .color(.black))
                x += Double(glyph.advanceWidth) * scale
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("預覽：\(GlyphEditorModel.previewText(for: model.selected))")
    }
}
