import SwiftUI

/// 英文字母換成另一套字型 (design §5.7), offered for CJK fonts: the Latin
/// letters a CJK font carries are often an afterthought. The letters come
/// from a library font, scaled to the CJK font's x-height; 大小 adjusts from
/// there. A font not in the library yet is one trip to ①'s English catalog.
struct ReplaceCard: View {
    @Bindable var editor: EditorModel

    var body: some View {
        let candidates = editor.replacementCandidates.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        EffectCard(
            title: "英文字母換成另一套字型", detail: "中文字型附的英文不合用時，借一套英文字型的字母",
            systemImage: "textformat.abc",
            isOn: Binding(
                get: { editor.draft.replacement != nil || editor.choosingReplacement },
                set: { on in
                    editor.choosingReplacement = on && candidates.isEmpty
                    editor.draft.replacement = on ? candidates.first.map(replacement(from:)) : nil
                })
        ) {
            if candidates.isEmpty {
                Text("字型庫裡還沒有可用的英文字型（OFL 授權）。").font(.callout)
            } else {
                LabeledContent("英文字型") {
                    Picker("英文字型", selection: selection(candidates)) {
                        // Also when the chosen font was deleted from the library.
                        if !candidates.contains(where: { $0.id == editor.draft.replacement?.sha256 }) {
                            Text("請選擇").tag(editor.draft.replacement?.sha256)
                        }
                        ForEach(candidates) { Text($0.displayName).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if let size = editor.draft.replacement?.size {
                HStack {
                    Text("小").font(.caption)
                    Slider(
                        value: Binding(get: { size }, set: { editor.draft.replacement?.size = ($0 * 100).rounded() / 100 }),
                        in: RecipeDraft.replacementSizeRange, step: 0.01
                    )
                    .accessibilityLabel("英文字母大小")
                    Text("大").font(.caption)
                }
                Text(size == 1 ? "英文字母與原本的 x 高相同" : "英文字母是原本 x 高的 \(Int((size * 100).rounded()))%")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let problem = editor.replacementProblem {
                Label(problem, systemImage: "xmark.circle.fill").font(.callout).foregroundStyle(.red)
            }
            if let browse = editor.browseCatalog {
                Button("到目錄挑英文字型…", systemImage: "square.grid.2x2") { browse(.latin) }
            }
            Text("換掉 A–Z、a–z、數字、半形標點與 é、ü 這類字母；中文與全形標點不變。換進來的字母沒有字距微調（kerning）。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func replacement(from entry: LibraryEntry) -> RecipeDraft.Replacement {
        RecipeDraft.Replacement(sha256: entry.id, fileName: entry.fileName)
    }

    /// Another font keeps the size chosen: it is relative to the x-height either way.
    private func selection(_ candidates: [LibraryEntry]) -> Binding<LibraryEntry.ID?> {
        Binding(
            get: { editor.draft.replacement?.sha256 },
            set: { id in
                guard let entry = candidates.first(where: { $0.id == id }) else { return }
                var chosen = replacement(from: entry)
                chosen.size = editor.draft.replacement?.size ?? 1
                editor.draft.replacement = chosen
                editor.choosingReplacement = false
            })
    }
}
