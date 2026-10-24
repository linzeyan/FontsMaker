import Foundation

/// 「要放到哪裡讀？」: where the exported font goes, and so which steps the
/// finished export shows (product spec §4.7).
enum InstallTarget: String, CaseIterable, Identifiable, Sendable {
    case mac
    case kobo
    case kindle
    case koreader
    case fileOnly

    var id: String { rawValue }

    /// This Mac is installed into by the app itself, so only macOS offers it.
    static var available: [InstallTarget] {
        #if os(macOS)
            allCases
        #else
            allCases.filter { $0 != .mac }
        #endif
    }

    var title: String {
        switch self {
        case .mac: "這台 Mac"
        case .kobo: "Kobo"
        case .kindle: "Kindle"
        case .koreader: "KOReader"
        case .fileOnly: "只存檔案"
        }
    }

    var symbol: String {
        switch self {
        case .mac: "desktopcomputer"
        case .kobo, .kindle: "book.closed"
        case .koreader: "book"
        case .fileOnly: "folder"
        }
    }

    /// The reader steps are drafts until tried on the devices (plan, Phase 4).
    var needsDeviceCheck: Bool {
        switch self {
        case .kobo, .kindle, .koreader: true
        case .mac, .fileOnly: false
        }
    }

    /// What to do with the saved file. A reader is filled from a computer
    /// over USB, so on iOS the file has to get to one first.
    var steps: [String] {
        var steps: [String]
        switch self {
        case .mac:
            steps = ["字型已經裝好，所有 App 的字型選單都看得到", "要移除時，回到「挑字型」的「已安裝到這台 Mac」按「移除」"]
        case .kobo:
            steps = [
                "用 USB 接上 Kobo，選「連接」", "在 KOBOeReader 磁碟最上層建立 fonts 資料夾", "把 .ttf 拖進 fonts", "退出磁碟，閱讀時點 Aa → 字型，選新字型",
            ]
        case .kindle:
            steps = ["用 USB 接上 Kindle", "把 .ttf 拖進 Kindle 磁碟的 fonts 資料夾", "退出磁碟，閱讀時點 Aa → 字型 → 選新字型"]
        case .koreader:
            steps = ["把 .ttf 放進裝置上的 koreader/fonts", "重新開啟 KOReader，閱讀時底部選單 → 字型"]
        case .fileOnly:
            steps = ["字型檔 .ttf 和配方 .json 存在同一個資料夾；配方可以用 fontsmaker build 重建出一樣的字型"]
        }
        #if os(iOS)
            if self == .kobo || self == .kindle || self == .koreader {
                steps.insert("把存好的 .ttf 傳到電腦（AirDrop 或 iCloud 雲碟）", at: 0)
            }
        #endif
        return steps
    }
}
