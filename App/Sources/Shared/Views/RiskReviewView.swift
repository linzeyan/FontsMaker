import FontsMakerKit
import SwiftUI

/// Risk review (product spec §4.5), opened from a finished export: A and B
/// glyphs before | after, and a per-glyph decision that is written into the
/// recipe; `apply` rebuilds with the decisions and exports again.
struct RiskReviewView: View {
    enum Filter: String, CaseIterable, Identifiable {
        /// Not "A＋B": decisions restored with the draft have no first grade.
        case all = "全部"
        case a = "A"
        case b = "B"

        var id: String { rawValue }
    }

    @Bindable var editor: EditorModel
    let apply: () -> Void
    /// To ①'s 中文 catalog, for a font to borrow a glyph from; nil offers no way there.
    var browseChinese: (() -> Void)? = nil
    @State private var filter = Filter.all

    var body: some View {
        if let outcome = editor.outcome, let report = outcome.emboldenReport,
            let snapshots = outcome.result.emboldenSnapshots
        {
            VStack(alignment: .leading, spacing: 8) {
                let counts = Text(
                    "本次建置：A \(report.count(of: .a))、B \(report.count(of: .b))、C \(report.count(of: .c))、D \(report.count(of: .d))"
                )
                .font(.callout).foregroundStyle(.secondary)
                // One row where it fits; on an iPhone the counts go below.
                ViewThatFits(in: .horizontal) {
                    HStack {
                        gradePicker
                        counts
                        Spacer()
                        rebuildButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            gradePicker
                            Spacer()
                            rebuildButton
                        }
                        counts
                    }
                }
                Text("每格左為加粗前、右為加粗後；從另一套字型取代的字，右邊是換進來的字形。處置寫進配方，按「套用並重新匯出」後生效。")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 176), spacing: 12)], spacing: 12) {
                        ForEach(items) { item in
                            let decision = editor.decision(for: item)
                            ReviewCell(
                                item: item, before: snapshots.before, after: snapshots.after,
                                borrowed: borrowedGlyph(item, decision), decision: decision,
                                decisionText: text(for: decision), stepWeight: editor.draft.emboldenWeight,
                                borrowing: borrowing(item), browseChinese: browseChinese
                            ) { editor.setDecision($0, for: item) }
                        }
                    }
                    .padding(.bottom)
                }
                .accessibilityIdentifier("reviewGrid")
            }
            .padding()
            // Again when the library changes: a font downloaded from the
            // catalog is read for the menus.
            .task(id: editor.library?.entries.map(\.id) ?? []) { await editor.findBorrowCandidates() }
        } else if editor.outcome != nil {
            ContentUnavailableView("這次建置沒有加粗", systemImage: "checkmark.seal", description: Text("只有加粗會產生風險字。"))
        } else {
            ContentUnavailableView(
                "尚未建置", systemImage: "hammer", description: Text("建置含加粗的配方後，這裡會列出 A、B 級風險字。"))
        }
    }

    private var gradePicker: some View {
        Picker("等級", selection: $filter) {
            ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }

    private var rebuildButton: some View {
        Button("套用並重新匯出", action: apply)
            .buttonStyle(.borderedProminent)
            .disabled(!editor.outcomeIsStale || !editor.canBuild)
    }

    private var items: [ReviewItem] {
        editor.review.items.filter { item in
            switch filter {
            case .all: return true
            case .a: return item.firstGrade == .a
            case .b: return item.firstGrade == .b
            }
        }
    }

    private func text(for decision: ReviewDecision) -> String {
        switch decision {
        case .accept: return "接受"
        case .skip: return "不加粗"
        case .weight(let weight): return "較小粗細 \(Int(weight))"
        case .borrow(let font): return "取自 \(editor.secondFontName(sha256: font.sha256, fileName: font.fileName))"
        }
    }

    /// What 從另一套字型取代 offers for the item: nil when its glyph cannot be borrowed.
    private func borrowing(_ item: ReviewItem) -> ReviewCell.Borrowing? {
        guard RiskReview.canBorrow(item) else { return nil }
        let fonts = editor.borrowCandidates(for: item).map { entry in
            ReviewCell.Borrowing.Choice(
                font: RecipeDraft.BorrowedFont(sha256: entry.id, fileName: entry.fileName), name: entry.displayName)
        }
        return ReviewCell.Borrowing(fonts: fonts, searching: editor.isFindingBorrowCandidates)
    }

    /// The glyph a borrowed item now shows, once its font is read.
    private func borrowedGlyph(_ item: ReviewItem, _ decision: ReviewDecision) -> (font: FontsMakerKit.Font, glyphID: Int)? {
        guard case .borrow(let chosen) = decision, let font = editor.secondFonts[chosen.sha256]?.font,
            let codePoint = item.characters.first?.unicodeScalars.first?.value,
            let glyph = font.characterMap.mappings[codePoint]
        else { return nil }
        return (font, Int(glyph))
    }
}

private struct ReviewCell: View {
    /// 從另一套字型取代's fonts for this glyph, by name.
    struct Borrowing {
        struct Choice: Identifiable {
            var font: RecipeDraft.BorrowedFont
            var name: String
            var id: String { font.sha256 }
        }

        var fonts: [Choice]
        /// The library is still being read: more fonts may follow.
        var searching: Bool
    }

    let item: ReviewItem
    let before: FontsMakerKit.Font
    let after: FontsMakerKit.Font
    let borrowed: (font: FontsMakerKit.Font, glyphID: Int)?
    let decision: ReviewDecision
    let decisionText: String
    let stepWeight: Double
    let borrowing: Borrowing?
    let browseChinese: (() -> Void)?
    let decide: (ReviewDecision) -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                GlyphCanvas(font: before, glyphID: item.id)
                if let borrowed {
                    GlyphCanvas(font: borrowed.font, glyphID: borrowed.glyphID)
                } else {
                    GlyphCanvas(font: after, glyphID: item.id)
                }
            }
            HStack {
                Text(item.label).font(.body)
                Text(gradeText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
            }
            Menu(decisionText) {
                Button("接受") { decide(.accept) }
                Button("不加粗") { decide(.skip) }
                ForEach(RiskReview.smallerWeights(than: stepWeight), id: \.self) { weight in
                    Button("較小粗細 \(Int(weight))") { decide(.weight(weight)) }
                }
                if let borrowing {
                    Section("從另一套字型取代") {
                        ForEach(borrowing.fonts) { choice in
                            Button("取自 \(choice.name)") { decide(.borrow(choice.font)) }
                        }
                        if borrowing.searching {
                            Text("正在找有這個字的字型…")
                        } else if borrowing.fonts.isEmpty {
                            Text("字型庫裡沒有含這個字的中文字型（OFL 授權）")
                        }
                        if let browseChinese {
                            Button("到目錄挑中文字型…", systemImage: "square.grid.2x2", action: browseChinese)
                        }
                    }
                }
            }
            .disabled(item.characters.isEmpty)
            // Every menu reads 接受 at first: the flow tests find a glyph's by its character.
            .accessibilityIdentifier("decision.\(item.characters.first ?? "#\(item.id)")")
            .help(item.characters.isEmpty ? "沒有字碼的字形（直排替代字形）無法在配方中逐字指定" : "")
        }
        .padding(6)
        .background(decision == .accept ? Color.clear : Color.accentColor.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
    }

    private var gradeText: String {
        // No first grade: a decision restored with the draft, never graded at the step's weight.
        let first =
            item.firstGrade.map { $0.rawValue + (item.firstRatio.map { String(format: " %.2f", $0) } ?? "") }
            ?? "先前處置"
        guard let grade = item.grade else { return first + " → 未加粗" }
        return grade == item.firstGrade ? first : first + " → \(grade.rawValue)"
    }
}

/// One glyph in the frame the CLI's risk sheets use: 1.2 em square from
/// (−0.1 em, descender − 0.1 em), with the advance box outlined.
private struct GlyphCanvas: View {
    let font: FontsMakerKit.Font
    let glyphID: Int

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(PageView.paper))
            let em = CGFloat(font.unitsPerEm)
            let descender = CGFloat(font.os2?.typoDescender ?? Int16(-0.12 * em))
            let scale = size.width / (1.2 * em)
            let transform = CGAffineTransform(
                a: scale, b: 0, c: 0, d: -scale, tx: 0.1 * em * scale, ty: size.height + (descender - 0.1 * em) * scale)
            let advance = CGFloat(font.horizontalMetrics[glyphID].advanceWidth)
            context.stroke(
                Path(CGRect(x: 0, y: descender, width: advance, height: em)).applying(transform),
                with: .color(.black.opacity(0.15)), lineWidth: 1)
            if let path = try? font.path(ofGlyph: glyphID) {
                context.fill(Path(path).applying(transform), with: .color(.black))
            }
        }
        .frame(width: 80, height: 80)
    }
}
