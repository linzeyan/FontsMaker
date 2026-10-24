import SwiftUI

struct LicensesView: View {
    private let notices = Result { try ThirdPartyNotice.all() }

    var body: some View {
        switch notices {
        case .success(let notices):
            List {
                Section {
                    Text("FontsMaker 內含以下第三方資料與程式碼，依各自的授權條款散布。")
                        .foregroundStyle(.secondary)
                }
                ForEach(notices) { notice in
                    Section(notice.name) {
                        LabeledContent("用途", value: notice.usage)
                        LabeledContent("授權", value: notice.license)
                        LabeledContent("來源", value: notice.origin)
                        DisclosureGroup("授權全文") {
                            Text(notice.text)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .navigationTitle("第三方授權")
        case .failure(let error):
            ContentUnavailableView(
                "授權文件無法載入", systemImage: "exclamationmark.triangle",
                description: Text(error.localizedDescription))
        }
    }
}
