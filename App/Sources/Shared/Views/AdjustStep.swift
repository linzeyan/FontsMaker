import FontsMakerKit
import SwiftUI

/// ②: the page, and beside it (below it on a phone) the effect cards.
struct AdjustStep: View {
    @Bindable var app: AppModel
    @Bindable var editor: EditorModel
    @CompactWidth private var isCompact

    var body: some View {
        if isCompact {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    PreviewPane(editor: editor).frame(height: proxy.size.height * 0.5)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            title
                            EffectCards(editor: editor)
                        }
                        .padding()
                    }
                    // For the UI flows, which scroll the controls to what they tap.
                    .accessibilityIdentifier("controls")
                    navigation.padding(.horizontal).padding(.vertical, 8)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 28) {
                PreviewPane(editor: editor).padding(.vertical, 16)
                VStack(alignment: .leading, spacing: 14) {
                    title
                    ScrollView { EffectCards(editor: editor) }.accessibilityIdentifier("controls")
                    navigation
                }
                .frame(width: 360)
                .padding(.vertical, 24)
            }
            .padding(.horizontal, 28)
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(editor.entry.displayName).font(isCompact ? .title2.weight(.bold) : .title.weight(.bold))
            Text(isCompact ? "打開需要的效果，上面即時更新。" : "打開需要的效果，左邊即時更新。").foregroundStyle(.secondary)
        }
    }

    private var navigation: some View {
        HStack {
            Button("上一步") { app.goBack() }
            Spacer()
            Button("下一步：匯出") { app.goForward() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

/// The effects in plain words, each a switch and, once on, its own few
/// controls (product spec §4.4); the recipe's terms stay out of sight. Which
/// cards show depends on the font: a Latin font gets 字距 and 行高 and the
/// width option of 加粗, a CJK font 直排閱讀 and 簡體書顯示繁體, which would
/// find nothing to turn or convert in a Latin font. A card that is on always
/// shows, so a draft from elsewhere can still be switched off.
struct EffectCards: View {
    @Bindable var editor: EditorModel

    private var latin: Bool { !editor.fontHasCJK }
    private var unitsPerEm: Int { Int(editor.sourceFont?.font.unitsPerEm ?? 1000) }

    var body: some View {
        VStack(spacing: 10) {
            if StyleCard.applies(to: editor) { StyleCard(editor: editor) }
            EffectCard(
                title: "加粗", detail: "電子紙上字太細時用", systemImage: "bold",
                isOn: Binding(
                    get: { editor.draft.emboldenWeight > 0 },
                    set: { editor.draft.emboldenWeight = $0 ? RecipeDraft.defaultWeight : 0 })
            ) {
                HStack {
                    Text("細").font(.caption)
                    Slider(value: $editor.draft.emboldenWeight, in: 1...RecipeDraft.maxWeight, step: 1)
                        .accessibilityLabel("粗細")
                    Text("粗").font(.caption)
                }
                Text(
                    "筆畫增厚 \(Int(editor.draft.emboldenWeight)) 單位（字身 \(editor.sourceFont?.font.unitsPerEm ?? 1000) 單位）"
                )
                .font(.caption).foregroundStyle(.secondary)
                // Latin letters are spaced by their side bearings, which bolder
                // strokes eat into; CJK keeps its em grid.
                if latin || editor.draft.widen {
                    // A monospaced font stays monospaced: every glyph gets the
                    // same extra width, so the promise differs (design §5.6).
                    OptionToggle(
                        title: editor.sourceFont?.font.monospacedAdvance != nil
                            ? "字寬跟著加寬（等寬字型：每個字加一樣寬，仍然等寬）" : "字寬跟著加寬（字母不擠在一起）",
                        isOn: $editor.draft.widen)
                }
                let skipped = editor.draft.skip.count
                let lighter = editor.draft.perCharacter.count
                if skipped + lighter > 0 {
                    Text("檢查過的字：\(skipped) 字不加粗、\(lighter) 字較小粗細").font(.caption)
                }
            }
            if latin || editor.draft.tracking != 0 { tracking }
            if latin || editor.draft.lineHeight != nil { lineHeight }
            if !latin || editor.draft.pseudoVertical != nil { pseudoVertical }
            if !latin || editor.draft.s2t != nil { s2t }
            if !latin || editor.draft.replacement != nil { ReplaceCard(editor: editor) }
            if GlyphEditCard.applies(to: editor) { GlyphEditCard(editor: editor) }
        }
    }

    private var tracking: some View {
        EffectCard(
            title: "字距", detail: "加粗後字母太擠時拉開", systemImage: "arrow.left.and.right",
            isOn: Binding(
                get: { editor.draft.tracking != 0 },
                set: { editor.draft.tracking = $0 ? RecipeDraft.defaultTracking(unitsPerEm: unitsPerEm) : 0 })
        ) {
            HStack {
                Text("緊").font(.caption)
                Slider(
                    value: Binding(
                        get: { Double(editor.draft.tracking) }, set: { editor.draft.tracking = Int($0.rounded()) }),
                    in: 1...Double(RecipeDraft.maxTracking(unitsPerEm: unitsPerEm)), step: 1
                )
                .accessibilityLabel("字距大小")
                Text("鬆").font(.caption)
            }
            Text("每個字母後多 \(editor.draft.tracking) 單位（字身 \(unitsPerEm) 單位）")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var lineHeight: some View {
        // pseudoVertical sets the line itself, as the column pitch; the
        // engine refuses both (only a draft from a CJK font can have it here).
        let blocked = editor.draft.pseudoVertical != nil
        return EffectCard(
            title: "行高", detail: blocked ? "直排閱讀會自己決定欄距，兩者不能同時使用" : "行與行的距離；閱讀器的行距以它為 1 倍",
            systemImage: "arrow.up.and.down",
            isOn: Binding(
                get: { editor.draft.lineHeight != nil },
                set: { editor.draft.lineHeight = $0 ? editor.suggestedLineHeight : nil })
        ) {
            if let units = editor.draft.lineHeight {
                Slider(
                    value: Binding(
                        get: { Double(units) / Double(unitsPerEm) },
                        set: { editor.draft.lineHeight = Int(($0 * Double(unitsPerEm)).rounded()) }),
                    in: RecipeDraft.lineHeightRange, step: 0.05
                )
                .accessibilityLabel("行高大小")
                Text(
                    "行高 \(RecipeDraft.formatEm(units, unitsPerEm: unitsPerEm))"
                        + (editor.sourceLineHeight.map {
                            "（原本 \(RecipeDraft.formatEm($0, unitsPerEm: unitsPerEm))）"
                        } ?? "")
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(blocked && editor.draft.lineHeight == nil)
    }

    private var pseudoVertical: some View {
        EffectCard(
            title: "直排閱讀", detail: "閱讀器不支援直排時，每個字轉 90°", systemImage: "rotate.right",
            isOn: Binding(
                get: { editor.draft.pseudoVertical != nil },
                set: { editor.draft.pseudoVertical = $0 ? PseudoVerticalOptions(punctuation: .centered) : nil })
        ) {
            if let options = editor.draft.pseudoVertical {
                // Labelled beside it: outside a Form, an iOS menu picker shows only its value.
                LabeledContent("句讀標點") {
                    Picker(
                        "句讀標點",
                        selection: Binding(
                            get: { options.punctuation }, set: { editor.draft.pseudoVertical?.punctuation = $0 })
                    ) {
                        Text("置中（台灣慣例）").tag(PunctuationMode.centered)
                        Text("直排字形（右上）").tag(PunctuationMode.verticalForms)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }

    private var s2t: some View {
        EffectCard(
            title: "簡體書顯示繁體", detail: "依詞彙轉換，里程碑不會變成裡程碑", systemImage: "character.book.closed",
            isOn: Binding(
                get: { editor.draft.s2t != nil },
                set: { editor.draft.s2t = $0 ? RecipeDraft.defaultS2T : nil })
        ) {
            if let options = editor.draft.s2t {
                DisclosureGroup("更多選項") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("一對多的字") {
                            Picker(
                                "一對多的字",
                                selection: Binding(get: { options.mode }, set: { editor.draft.s2t?.mode = $0 })
                            ) {
                                Text("取最常用的繁體").tag(S2TMode.single)
                                Text("不轉換").tag(S2TMode.skipAmbiguous)
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        OptionToggle(
                            title: "台灣異體字（爲→為、裏→裡）",
                            isOn: Binding(
                                get: { options.taiwanVariants }, set: { editor.draft.s2t?.taiwanVariants = $0 }))
                        OptionToggle(
                            title: "依詞彙轉換（里程碑不會變成裡程碑）",
                            isOn: Binding(get: { options.phrases }, set: { editor.draft.s2t?.phrases = $0 }),
                            enabled: options.mode == .single)
                        Text(
                            options.mode == .single
                                ? "詞彙規則由閱讀器排版時套用；不套用的閱讀器仍顯示逐字轉換的結果。"
                                : "詞彙規則照 OpenCC 的轉換結果，一對多的字選「取最常用的繁體」才能使用。"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                }
            }
        }
    }
}

/// One effect: what it is for in a line, its switch, and its controls when on.
struct EffectCard<Extra: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    @Binding var isOn: Bool
    @ViewBuilder let extra: Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline)
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: systemImage).frame(width: 24)
                }
                .accessibilityHidden(true)
                Spacer()
                Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden()
            }
            if isOn { extra }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A switch whose label fades with it when it cannot be changed: a plain
/// Toggle on iOS greys only the switch, and the label reads as available.
private struct OptionToggle: View {
    let title: String
    @Binding var isOn: Bool
    var enabled = true

    var body: some View {
        HStack {
            Text(title).foregroundStyle(enabled ? .primary : .secondary).accessibilityHidden(true)
            Spacer()
            Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden()
        }
        .font(.callout)
        .disabled(!enabled)
    }
}

/// Which font of a collection and which instance of a variable font to
/// start from (the recipe's `source.faceIndex` and `source.variation`):
/// a named instance, or each axis by its slider.
private struct StyleCard: View {
    @Bindable var editor: EditorModel

    static func applies(to editor: EditorModel) -> Bool {
        guard let source = editor.sourceFont else { return false }
        return source.faces.count > 1 || editor.face?.axes.contains { !$0.hidden } == true
    }

    var body: some View {
        let faces = editor.sourceFont?.faces ?? []
        let axes = editor.face?.axes.filter { !$0.hidden } ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("字型樣式").font(.headline)
                        Text(faces.count > 1 ? "這個檔有 \(faces.count) 套字，先選要改的那套" : "先選粗細，再套用下面的效果")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "textformat.size").frame(width: 24)
                }
                Spacer()
                if editor.isApplyingStyle { ProgressView().controlSize(.small).accessibilityLabel("套用樣式中") }
            }
            if faces.count > 1 {
                LabeledContent("字形") {
                    Picker("字形", selection: Binding(get: { editor.draft.faceIndex }, set: editor.chooseFace)) {
                        ForEach(faces, id: \.index) { face in
                            Text(face.fullName ?? "第 \(face.index + 1) 套").tag(face.index)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            if let face = editor.face, !face.namedInstances.isEmpty, !axes.isEmpty {
                LabeledContent("樣式") {
                    Picker("樣式", selection: instanceBinding(face)) {
                        ForEach(face.namedInstances.indices, id: \.self) { index in
                            Text(face.namedInstances[index].name ?? "樣式 \(index + 1)").tag(Optional(index))
                        }
                        Text("自訂").tag(Int?.none)
                    }
                    .labelsHidden().fixedSize()
                }
            }
            ForEach(axes, id: \.tag) { axis in
                AxisSlider(editor: editor, axis: axis)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    /// The named instance the axis values are at, if any; choosing one sets every axis.
    private func instanceBinding(_ face: FontFace) -> Binding<Int?> {
        Binding(
            get: {
                let values = editor.axisValues
                return face.namedInstances.firstIndex { instance in
                    face.axes.allSatisfy { (instance.coordinates[$0.tag] ?? $0.defaultValue) == values[$0.tag] }
                }
            },
            set: { index in
                guard let index else { return }
                editor.setAxes(face.namedInstances[index].coordinates)
            })
    }
}

private struct AxisSlider: View {
    @Bindable var editor: EditorModel
    let axis: VariationAxis

    /// The registered axes in words; a font's own axes by the name it gives them.
    private var title: String {
        switch axis.tag {
        case "wght": "字重"
        case "wdth": "字寬"
        case "opsz": "光學尺寸"
        case "slnt": "傾斜"
        case "ital": "斜體"
        default: axis.name ?? axis.tag
        }
    }

    /// Whole units on the usual axes (wght 100–900); tenths on short ones such as ital 0–1.
    private var step: Double { axis.maximum - axis.minimum >= 10 ? 1 : 0.1 }

    var body: some View {
        let value = editor.axisValues[axis.tag] ?? axis.defaultValue
        HStack {
            Text(title).font(.callout).frame(minWidth: 56, alignment: .leading)
            Slider(
                value: Binding(
                    get: { value },
                    set: { newValue in
                        var values = editor.axisValues
                        values[axis.tag] = (newValue / step).rounded() * step
                        editor.setAxes(values)
                    }),
                in: axis.minimum...axis.maximum
            )
            .accessibilityLabel(title)
            Text(value.formatted(.number.precision(.fractionLength(0...1))))
                .font(.callout).monospacedDigit().frame(minWidth: 36, alignment: .trailing)
        }
    }
}
