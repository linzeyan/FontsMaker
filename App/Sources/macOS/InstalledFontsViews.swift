import SwiftUI

/// ①'s list of the fonts FontsMaker installed on this Mac, each drawn in
/// itself, with 移除.
struct InstalledFontsSection: View {
    @Bindable var installed: InstalledFonts

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("已安裝到這台 Mac").font(.title2.weight(.bold))
            if installed.items.isEmpty {
                Text("還沒有。在「匯出並安裝」選「這台 Mac」，做好的字型會裝在這裡，所有 App 的字型選單都看得到。")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(installed.items) { item in
                        InstalledFontRow(installed: installed, item: item)
                        if item != installed.items.last { Divider() }
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.top, 12)
    }
}

private struct InstalledFontRow: View {
    let installed: InstalledFonts
    let item: InstalledFonts.Item

    var body: some View {
        let font = Specimen.font(item.url, size: 24)
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName).font(.headline)
                Text(font.map(Specimen.text(for:)) ?? Specimen.chinese)
                    .font(font.map { SwiftUI.Font($0) } ?? .title2)
                    .lineLimit(1)
            }
            Spacer()
            RemoveInstalledButton(installed: installed, item: item)
        }
        .padding(12)
    }
}

/// 移除, after a confirmation; a refusal says why (product spec: failures
/// are never swallowed).
struct RemoveInstalledButton: View {
    let installed: InstalledFonts
    let item: InstalledFonts.Item
    @State private var confirming = false
    @State private var problem: String?

    var body: some View {
        Button("移除", role: .destructive) { confirming = true }
            .confirmationDialog("移除「\(item.displayName)」？", isPresented: $confirming) {
                Button("移除", role: .destructive) {
                    Task {
                        do {
                            try await installed.remove(item)
                        } catch {
                            problem = error.localizedDescription
                        }
                    }
                }
            } message: {
                Text("字型會從這台 Mac 移除。正在使用它的 App 可能要重新開啟，字型選單才會更新。")
            }
            .alert(
                "無法移除「\(item.displayName)」",
                isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
            ) {
                Button("好") { problem = nil }
            } message: {
                Text(problem ?? "")
            }
    }
}

/// ③'s line about the install that followed the save to 這台 Mac.
struct InstallStatus: View {
    let installed: InstalledFonts
    let exportedFile: URL

    var body: some View {
        if let install = installed.lastInstall, install.exportedFile == exportedFile {
            switch install.state {
            case .installing:
                ProgressView { Text("安裝到這台 Mac…") }
            case .installed(let item):
                HStack {
                    Label("已安裝「\(item.displayName)」到這台 Mac", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    RemoveInstalledButton(installed: installed, item: item)
                }
            case .failed(let reason):
                Label("沒有裝好：\(reason)", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).textSelection(.enabled)
            }
        } else {
            // Removed since, or the export predates this launch.
            Text("目前沒有安裝這份匯出。").foregroundStyle(.secondary)
        }
    }
}
