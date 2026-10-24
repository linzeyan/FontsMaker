import SwiftUI

/// ③'s 「Regular／Italic／Bold／Bold Italic 一起匯出」 (technical design
/// §5.6): shown when the library holds more styles of this Latin family;
/// once on, which file or instance each style is built from.
struct StyleSetSection: View {
    @Bindable var set: StyleSetModel
    let editor: EditorModel

    var body: some View {
        Group {
            if set.isAvailable && !editor.fontHasCJK {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $set.isOn) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Regular／Italic／Bold／Bold Italic 一起匯出")
                            Text("同一個家族名稱，閱讀器的粗體、斜體才找得到對的檔。效果與行高每一份都相同。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    #if os(macOS)
                        .toggleStyle(.checkbox)
                    #endif
                    if set.isOn {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                            ForEach(StyleRole.allCases) { role in
                                GridRow {
                                    Text(role.styleName).font(.callout.weight(.semibold))
                                    picker(for: role)
                                }
                            }
                        }
                        if let note = set.outlinesNote(draft: editor.draft) {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                        if let problem = set.problem {
                            Label(problem, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.callout)
                        }
                    }
                }
                .padding(12)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func picker(for role: StyleRole) -> some View {
        let binding = Binding<String>(
            get: { set.chosen[role]?.id ?? "" },
            set: { id in set.chosen[role] = set.sources.first { $0.id == id } })
        return Picker(role.styleName, selection: binding) {
            if role != .regular { Text("不匯出").tag("") }
            ForEach(set.candidates(for: role)) { source in
                Text(source.label).tag(source.id)
            }
        }
        .labelsHidden()
        .accessibilityLabel("\(role.styleName) 用的字型")
        // iOS shows the menu as a button labelled with the choice, so the
        // flow tests find it by this instead.
        .accessibilityIdentifier("styleSource.\(role.styleName)")
    }
}

/// A set build's progress, one member after another, with its cancel button.
struct StyleSetStatus: View {
    let set: StyleSetModel

    var body: some View {
        switch set.build {
        case .running(let member, let count, let completed, let total):
            HStack {
                let role = set.buildRoles.indices.contains(member) ? set.buildRoles[member].styleName : ""
                if total > 0 && completed < total {
                    ProgressView(value: Double(completed), total: Double(total)) {
                        Text("第 \(member + 1)／\(count) 份（\(role)）：加粗 \(completed.formatted()) / \(total.formatted()) 字形")
                    }
                } else {
                    ProgressView { Text("第 \(member + 1)／\(count) 份（\(role)）…") }
                }
                Button("取消", role: .cancel) { set.cancelBuild() }
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

/// After a set left the app: where it went, each font as CoreText read it
/// back, and whether the license went with them.
struct StyleSetDone: View {
    let set: StyleSetModel
    let editor: EditorModel

    var body: some View {
        if let destination = set.exportDestination, !set.exported.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("已存好 \(set.exported.count) 個字型與配方", systemImage: "checkmark.circle.fill")
                    .font(.title3.weight(.semibold)).foregroundStyle(.green)
                Text(place(destination)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if set.isStale(draft: editor.draft) {
                    Text("設定在匯出後改過了；再按一次「做出字型並存檔」，存出的才是現在的設定。")
                        .font(.callout).foregroundStyle(.orange)
                }
                if let summary = set.installSummary {
                    Text(summary).font(.callout)
                }
                ForEach(Array(set.exported.enumerated()), id: \.offset) { _, check in
                    let same = check.matchingGlyphs == check.checkedGlyphs
                    Label(
                        "\(check.fontURL.lastPathComponent)：CoreText 載入「\(check.fullName)」，\(check.matchingGlyphs)/\(check.checkedGlyphs) 個字與預覽相同",
                        systemImage: same ? "checkmark.circle" : "exclamationmark.triangle"
                    )
                    .font(.callout).foregroundStyle(same ? Color.primary : .orange).textSelection(.enabled)
                }
                if set.exported.contains(where: { $0.licenseURL != nil }) {
                    Label("已附上來源字型的授權全文；轉給別人時，請連同它一起給。", systemImage: "doc.text")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Label(
                        "沒有附上授權全文：這些字型是從檔案匯入的，FontsMaker 沒有它們的授權檔。要轉給別人時，請附上原作者的授權。",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout).foregroundStyle(.orange)
                }
            }
        }
    }

    private func place(_ destination: ExportDestination) -> String {
        let names = StyleSetModel.files(of: set.exported).map(\.lastPathComponent).joined(separator: "、")
        switch destination {
        case .savedFile:
            return "在 \(set.exported[0].fontURL.deletingLastPathComponent().path)：\(names)。"
        case .files(let folder, _, _, _):
            // Files may have renamed one it found taken ("… 2"); it does not say which.
            return "存到「\(ExportDestination.path(folder))」：\(names)（同名的檔「檔案」會另存成「… 2」）。"
        case .shared(let activity):
            return "分享給「\(ExportDestination.activityName(activity))」；存到哪裡由接收的 App 決定，FontsMaker 無從得知。"
        }
    }
}
