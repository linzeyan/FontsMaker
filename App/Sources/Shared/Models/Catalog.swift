import Foundation

/// A font the app offers to download (plan, Phase 4b): pinned to one file
/// by URL and sha256, with its license text beside it. Every entry's
/// license was read in its repository before it was listed; fonts whose
/// license could not be confirmed are left out rather than marked unknown.
struct CatalogFont: Identifiable, Hashable, Sendable {
    /// The two tabs of ①. Chinese fonts carry Latin letters too, but are
    /// listed for their Chinese.
    enum Script: String, CaseIterable, Sendable {
        case chinese
        case latin

        var title: String {
            switch self {
            case .chinese: "中文"
            case .latin: "English"
            }
        }
    }

    /// The English tab's groups, in this order. Monospaced fonts are apart
    /// (the user asked for them to be): every letter the same width reads
    /// unlike either kind of proportional font.
    enum LatinGroup: String, CaseIterable, Sendable {
        case serif = "Serif"
        case sans = "Sans"
        case mono = "Mono"

        var title: String {
            switch self {
            case .serif: "襯線體 Serif"
            case .sans: "無襯線體 Sans"
            case .mono: "等寬字型 Mono"
            }
        }
    }

    /// A font inside a zip: GitHub releases often publish nothing else.
    struct ArchiveMember: Hashable, Sendable {
        var path: String
        /// sha256 of the extracted file; the library and recipes know the font by it.
        var sha256: String
    }

    let id: String
    let name: String
    let latinName: String
    let script: Script
    let style: String
    let blurb: String
    /// Shown on the card: where the file comes from.
    let publisher: String
    let license: String
    let url: URL
    /// sha256 and size of what `url` returns, the zip for an archived font.
    let sha256: String
    let byteCount: Int
    let member: ArchiveMember?
    /// The library's file name, so exported recipes name the upstream file.
    let fileName: String
    let licenseURL: URL
    /// Axes to choose a weight from in ② (not a promise of any one axis).
    let variable: Bool
    /// Several fonts in one file, chosen in ②.
    let collection: Bool

    /// sha256 of the font file itself: the library entry's ID once downloaded.
    var fontSHA256: String { member?.sha256 ?? sha256 }

    /// An English font's group, named by its `style`; nil for a Chinese
    /// font, whose style is free text (楷書, 圓體…).
    var latinGroup: LatinGroup? { script == .latin ? LatinGroup(rawValue: style) : nil }

    /// Downloads past this are labelled as large on the card: on a slow
    /// connection (tens of KB/s on the test VMs) they take many minutes.
    static let largeDownload = 30_000_000
    var isLarge: Bool { byteCount > CatalogFont.largeDownload }
}

extension CatalogFont {
    private static func url(_ string: String) -> URL { URL(string: string)! }

    /// google/fonts pinned to commits, so the sha256 never moves; each folder
    /// holds the font's own OFL.txt.
    private static let googleFonts = "https://raw.githubusercontent.com/google/fonts/"
    private static let googleFontsCommit = "e7db6ca603fd4862010383ff17ffd6cc4ffac1c0"

    private static func google(_ folder: String, _ file: String, commit: String = googleFontsCommit) -> URL {
        let escaped = file.replacingOccurrences(of: "[", with: "%5B").replacingOccurrences(of: "]", with: "%5D")
        return url(googleFonts + commit + "/ofl/\(folder)/\(escaped)")
    }

    private static func googleLicense(_ folder: String, commit: String = googleFontsCommit) -> URL {
        url(googleFonts + commit + "/ofl/\(folder)/OFL.txt")
    }

    /// Checked 2026-10-24. Left out: 昭源宋體 HK (50 MB), the ButTaiwan
    /// families other than 源泉圓體 (every release zip is 40–100 MB; 源雲明體
    /// 88–102 MB), I.Ming and 霞鶩新晰黑 (IPA license, not OFL), the
    /// max32002 fonts (no license file), 台北黑體 (no source to pin: the
    /// foundry's own site only, mirrors on GitHub are unofficial) and
    /// 霞鶩晰黑 TC (LXGW Bright, a 34 MB .7z the app cannot open).
    static let all: [CatalogFont] = [
        // MARK: 中文
        CatalogFont(
            id: "guankiap", name: "原俠正楷", latinName: "GuanKiap Tsing Khai", script: .chinese, style: "楷書",
            blurb: "霞鶩文楷的正體楷書衍生版，電子書常用", publisher: "GitHub", license: "OFL-1.1",
            url: url("https://github.com/tonyhuan/GuanKiapTsingKhai/releases/download/V1.20/GuanKiapTsingKhai.ttf"),
            sha256: "758632243c499e431fd0c847f5e8c431acf59a9b41a26237a819466139994d38", byteCount: 14_675_776,
            member: nil, fileName: "GuanKiapTsingKhai.ttf",
            // The project has no OFL.txt; its README declares OFL 1.1 and the reserved names.
            licenseURL: url(
                "https://raw.githubusercontent.com/tonyhuan/GuanKiapTsingKhai/6b502644f8c6008440221291b18e1d2f79e7a3bb/README.md"
            ),
            variable: false, collection: false),
        CatalogFont(
            id: "lxgw-wenkai-tc", name: "霞鶩文楷 TC", latinName: "LXGW WenKai TC", script: .chinese, style: "楷書",
            blurb: "溫潤的楷書，從 Klee One 衍生", publisher: "GitHub", license: "OFL-1.1",
            url: url("https://github.com/lxgw/LxgwWenkaiTC/releases/download/v1.522/LXGWWenKaiTC-Regular.ttf"),
            sha256: "b1a0795862c1415bf3f393ea50b2a4ea6275012cf5bad3f94feeb1222f555731", byteCount: 15_267_616,
            member: nil, fileName: "LXGWWenKaiTC-Regular.ttf",
            licenseURL: url(
                "https://raw.githubusercontent.com/lxgw/LxgwWenkaiTC/85f0ac2bd1d61a80dcb15acf7a33ea0b16a57542/OFL.txt"),
            variable: false, collection: false),
        CatalogFont(
            id: "iansui", name: "芫荽", latinName: "Iansui", script: .chinese, style: "手寫楷",
            blurb: "照台灣教育部標準字形調整的手寫風楷書", publisher: "GitHub", license: "OFL-1.1",
            url: url("https://github.com/ButTaiwan/iansui/releases/download/v1.020/iansui.zip"),
            sha256: "28d58aef9b7a21c137945a4fd14138d6284a8573c0c1b123f6e5b708423348a6", byteCount: 4_803_795,
            member: ArchiveMember(
                path: "Iansui-Regular.ttf", sha256: "7f1aa62e9dcbf40d0ce41a5d3f1e5ea602e66c295778ac6fefb6b84d8ed08bd5"),
            fileName: "Iansui-Regular.ttf",
            licenseURL: url(
                "https://raw.githubusercontent.com/ButTaiwan/iansui/9d9a8e68bf1e138dd91e562eeff28d95bca33196/OFL.txt"),
            variable: false, collection: false),
        CatalogFont(
            id: "huninn", name: "粉圓", latinName: "Huninn", script: .chinese, style: "圓體",
            blurb: "圓潤可愛的圓體", publisher: "Google Fonts", license: "OFL-1.1",
            url: google("huninn", "Huninn-Regular.ttf"),
            sha256: "1bd770a5ffc0c06723b567686f8b5db5abf9ab54227f3bbc4e6fd648f4698805", byteCount: 4_683_972,
            member: nil, fileName: "Huninn-Regular.ttf", licenseURL: googleLicense("huninn"),
            variable: false, collection: false),
        CatalogFont(
            id: "noto-sans-tc", name: "Noto Sans TC", latinName: "Noto Sans TC", script: .chinese, style: "黑體",
            blurb: "思源黑體的 Google 版本，可選粗細", publisher: "Google Fonts", license: "OFL-1.1",
            url: google("notosanstc", "NotoSansTC[wght].ttf"),
            sha256: "864727d210d54f2537bbe23b3a839436c3992af72de9322af5270897246bd44f", byteCount: 11_941_968,
            member: nil, fileName: "NotoSansTC[wght].ttf", licenseURL: googleLicense("notosanstc"),
            variable: true, collection: false),
        CatalogFont(
            id: "chiron-hei-hk", name: "昭源黑體 HK", latinName: "Chiron Hei HK", script: .chinese, style: "黑體",
            blurb: "現代黑體，可選粗細", publisher: "Google Fonts", license: "OFL-1.1",
            url: google("chironheihk", "ChironHeiHK[wght].ttf"),
            sha256: "0d788ded72dc88f478818182179af4c7cd143df0bf86557d29729ab132333930", byteCount: 31_144_580,
            member: nil, fileName: "ChironHeiHK[wght].ttf", licenseURL: googleLicense("chironheihk"),
            variable: true, collection: false),
        CatalogFont(
            id: "gensen-rounded", name: "源泉圓體", latinName: "GenSen Rounded 2", script: .chinese, style: "圓體",
            blurb: "源起黑體的圓角版，一個檔含台、繁、日三種字形", publisher: "GitHub", license: "OFL-1.1",
            url: url("https://github.com/ButTaiwan/gensen-font/releases/download/v2.100/GenSenRounded2-ttc.zip"),
            sha256: "01f57ff5eac25143c654cfd37ab06d191703fb67aea94811ec48f101a2f6e203", byteCount: 57_807_254,
            member: ArchiveMember(
                path: "GenSenRounded2-R.ttc", sha256: "34ec5dbacd7f2b8dd14569cf4a41d0eeaf2bdaede45087bf51919857a26528a2"
            ),
            fileName: "GenSenRounded2-R.ttc",
            licenseURL: url(
                "https://raw.githubusercontent.com/ButTaiwan/gensen-font/6107da89595059ea2d9a4ff15db240b0a086a98a/SIL_Open_Font_License_1.1.txt"
            ),
            variable: false, collection: true),
        CatalogFont(
            id: "chenyuluoyan", name: "辰宇落雁體", latinName: "ChenYuluoyan", script: .chinese, style: "手寫",
            blurb: "高中生手寫的細體", publisher: "GitHub", license: "OFL-1.1",
            url: url(
                "https://raw.githubusercontent.com/Chenyu-otf/chenyuluoyan_thin/6e36815b0bec9f4f948298698d00b27a5f0b65c1/ChenYuluoyan-2.0-Thin.ttf"
            ),
            sha256: "1289e42a6d1ec995d0cb23aee89efc69fc95749fbd54a610057a3e992dc453db", byteCount: 9_522_140,
            member: nil, fileName: "ChenYuluoyan-2.0-Thin.ttf",
            licenseURL: url(
                "https://raw.githubusercontent.com/Chenyu-otf/chenyuluoyan_thin/6e36815b0bec9f4f948298698d00b27a5f0b65c1/license.txt"
            ),
            variable: false, collection: false),
        CatalogFont(
            id: "noto-serif-tc", name: "Noto Serif TC", latinName: "Noto Serif TC", script: .chinese, style: "明體",
            blurb: "思源宋體的 Google 版本，可選粗細", publisher: "Google Fonts", license: "OFL-1.1",
            url: google("notoseriftc", "NotoSerifTC[wght].ttf"),
            sha256: "0077e18f57c6908f4a000969880940bdb0dad057c0e8d98b49dc364c3d1b09c6", byteCount: 16_851_596,
            member: nil, fileName: "NotoSerifTC[wght].ttf", licenseURL: googleLicense("notoseriftc"),
            variable: true, collection: false),
        CatalogFont(
            id: "cactus-classical-serif", name: "仙人掌明體", latinName: "Cactus Classical Serif", script: .chinese,
            style: "明體", blurb: "傳承字形的明體，大致依 I.Font 的傳承字形標準，收字多", publisher: "Google Fonts",
            license: "OFL-1.1", url: google("cactusclassicalserif", "CactusClassicalSerif-Regular.ttf"),
            sha256: "ecbd58961db922392d7fecfafa3681fefaeec0c399b860ab6940ba700f7da055", byteCount: 28_502_932,
            member: nil, fileName: "CactusClassicalSerif-Regular.ttf",
            licenseURL: googleLicense("cactusclassicalserif"), variable: false, collection: false),
        CatalogFont(
            id: "chocolate-classical-sans", name: "朱古力黑體", latinName: "Chocolate Classical Sans",
            script: .chinese, style: "黑體", blurb: "從思源黑體改成傳承字形的黑體", publisher: "Google Fonts",
            license: "OFL-1.1", url: google("chocolateclassicalsans", "ChocolateClassicalSans-Regular.ttf"),
            sha256: "e6345f3d92c7a9b7044c31a87d9b61f50220b08c0f1dcc2736e94c2aa587ce03", byteCount: 12_183_000,
            member: nil, fileName: "ChocolateClassicalSans-Regular.ttf",
            licenseURL: googleLicense("chocolateclassicalsans"), variable: false, collection: false),
        CatalogFont(
            id: "lxgw-marker-gothic", name: "霞鶩漫黑", latinName: "LXGW Marker Gothic", script: .chinese,
            style: "手寫黑體", blurb: "麥克筆手感的黑體，從日文字型 Tanugo 改編，繁簡共一萬五千字",
            publisher: "Google Fonts", license: "OFL-1.1",
            url: google("lxgwmarkergothic", "LXGWMarkerGothic-Regular.ttf"),
            sha256: "e6a55cfd5f18dc393f92670a164397a69242cb4eabe1d3feb5dc22fc4947a8ba", byteCount: 3_187_360,
            member: nil, fileName: "LXGWMarkerGothic-Regular.ttf", licenseURL: googleLicense("lxgwmarkergothic"),
            variable: false, collection: false),

        // MARK: English
        CatalogFont(
            id: "literata", name: "Literata", latinName: "Literata", script: .latin, style: "Serif",
            blurb: "為電子書設計的內文字型（Google Play 圖書）", publisher: "Google Fonts", license: "OFL-1.1",
            url: google("literata", "Literata[opsz,wght].ttf", commit: "4e5f06dbb274a27ebe71ed54ea706b3ee40eabd9"),
            sha256: "b41138c9373112f32abb589cc22e8674b06ed4048b0c513be922bdd26f274440", byteCount: 955_132,
            member: nil, fileName: "Literata[opsz,wght].ttf",
            licenseURL: googleLicense("literata", commit: "4e5f06dbb274a27ebe71ed54ea706b3ee40eabd9"),
            variable: true, collection: false),
        CatalogFont(
            id: "source-serif-4", name: "Source Serif 4", latinName: "Source Serif 4", script: .latin, style: "Serif",
            blurb: "Adobe 的內文襯線體，有光學尺寸", publisher: "Google Fonts", license: "OFL-1.1",
            url: google("sourceserif4", "SourceSerif4[opsz,wght].ttf"),
            sha256: "97b2d4da6e3cb494b5a1e66ae176914d852ccabef49e0c02c0df25f3e39aca0b", byteCount: 1_209_508,
            member: nil, fileName: "SourceSerif4[opsz,wght].ttf", licenseURL: googleLicense("sourceserif4"),
            variable: true, collection: false),
        CatalogFont(
            id: "eb-garamond", name: "EB Garamond", latinName: "EB Garamond", script: .latin, style: "Serif",
            blurb: "經典 Garamond 的復刻", publisher: "Google Fonts", license: "OFL-1.1",
            url: google("ebgaramond", "EBGaramond[wght].ttf"),
            sha256: "ef9512f92f6d579e5dc75af59a5a4b1b8b47d2eda89e00b954d44520e5369027", byteCount: 851_176,
            member: nil, fileName: "EBGaramond[wght].ttf", licenseURL: googleLicense("ebgaramond"),
            variable: true, collection: false),
        CatalogFont(
            id: "inter", name: "Inter", latinName: "Inter", script: .latin, style: "Sans",
            blurb: "為螢幕設計的無襯線體，x 字高較高", publisher: "Google Fonts", license: "OFL-1.1",
            url: google("inter", "Inter[opsz,wght].ttf", commit: "0b58fb370093f9a9f4ff785d94405710b79de67c"),
            sha256: "29160a80ff49ddcab2c97711247e08b1fab27a484a329ce8b813d820dc559031", byteCount: 876_576,
            member: nil, fileName: "Inter[opsz,wght].ttf",
            licenseURL: googleLicense("inter", commit: "0b58fb370093f9a9f4ff785d94405710b79de67c"),
            variable: true, collection: false),
        CatalogFont(
            id: "merriweather", name: "Merriweather", latinName: "Merriweather", script: .latin, style: "Serif",
            blurb: "螢幕閱讀用的襯線體，可調粗細與字寬", publisher: "Google Fonts", license: "OFL-1.1",
            url: google("merriweather", "Merriweather[opsz,wdth,wght].ttf"),
            sha256: "d0ed0e359e396af7ad05e73dffd11a3a4c326ea0d0283c56bd9361cb2cc86a96", byteCount: 4_628_080,
            member: nil, fileName: "Merriweather[opsz,wdth,wght].ttf", licenseURL: googleLicense("merriweather"),
            variable: true, collection: false),
        CatalogFont(
            id: "ibm-plex-serif", name: "IBM Plex Serif", latinName: "IBM Plex Serif", script: .latin, style: "Serif",
            blurb: "IBM 的企業字型，結構方正的襯線體", publisher: "Google Fonts", license: "OFL-1.1",
            url: google("ibmplexserif", "IBMPlexSerif-Regular.ttf"),
            sha256: "e882efa9c41949a528ac2369079ec5ef050c1c996bbd0bacce3c3326d44cf80d", byteCount: 163_068,
            member: nil, fileName: "IBMPlexSerif-Regular.ttf", licenseURL: googleLicense("ibmplexserif"),
            variable: false, collection: false),
        CatalogFont(
            id: "lora", name: "Lora", latinName: "Lora", script: .latin, style: "Serif",
            blurb: "筆畫帶書法味的內文襯線體，可選粗細", publisher: "Google Fonts", license: "OFL-1.1",
            url: google("lora", "Lora[wght].ttf"),
            sha256: "822a6621ccbe8d97d20ac88c1c41f5615c9c2c202eaa75f272cd452aac6475a7", byteCount: 212_196,
            member: nil, fileName: "Lora[wght].ttf", licenseURL: googleLicense("lora"),
            variable: true, collection: false),
        CatalogFont(
            id: "source-sans-3", name: "Source Sans 3", latinName: "Source Sans 3", script: .latin, style: "Sans",
            blurb: "Adobe 的內文無襯線體，可選粗細", publisher: "Google Fonts", license: "OFL-1.1",
            url: google("sourcesans3", "SourceSans3[wght].ttf"),
            sha256: "042fe2cc0b933e328410d7acbd0aa6a1873dca5aef81875f4bc214b08825c7b9", byteCount: 646_340,
            member: nil, fileName: "SourceSans3[wght].ttf", licenseURL: googleLicense("sourcesans3"),
            variable: true, collection: false),
        CatalogFont(
            id: "atkinson-hyperlegible-next", name: "Atkinson Hyperlegible Next",
            latinName: "Atkinson Hyperlegible Next", script: .latin, style: "Sans",
            blurb: "為低視力讀者設計，容易混淆的字母刻意做出差異，可選粗細", publisher: "Google Fonts",
            license: "OFL-1.1", url: google("atkinsonhyperlegiblenext", "AtkinsonHyperlegibleNext[wght].ttf"),
            sha256: "5a455d1cfa099b601ab70751bb9673e8fe1854dc4500c80e1a220d0d75e31745", byteCount: 114_552,
            member: nil, fileName: "AtkinsonHyperlegibleNext[wght].ttf",
            licenseURL: googleLicense("atkinsonhyperlegiblenext"), variable: true, collection: false),
        CatalogFont(
            id: "ibm-plex-sans", name: "IBM Plex Sans", latinName: "IBM Plex Sans", script: .latin, style: "Sans",
            blurb: "IBM 的無襯線體，可調粗細與字寬", publisher: "Google Fonts", license: "OFL-1.1",
            url: google("ibmplexsans", "IBMPlexSans[wdth,wght].ttf"),
            sha256: "3b031aa4216174205bd8471f88a49b91f093169e9e87bd5262242bc5967fe2e3", byteCount: 537_244,
            member: nil, fileName: "IBMPlexSans[wdth,wght].ttf", licenseURL: googleLicense("ibmplexsans"),
            variable: true, collection: false),
        CatalogFont(
            id: "jetbrains-mono", name: "JetBrains Mono", latinName: "JetBrains Mono", script: .latin, style: "Mono",
            blurb: "為寫程式設計，x 字高較高、相似的字母容易分辨，可選粗細", publisher: "Google Fonts",
            license: "OFL-1.1", url: google("jetbrainsmono", "JetBrainsMono[wght].ttf"),
            sha256: "48715a42ec242c21e9f02692891e147d022299a52e48d5e413e1a942193ffeda", byteCount: 187_208,
            member: nil, fileName: "JetBrainsMono[wght].ttf", licenseURL: googleLicense("jetbrainsmono"),
            variable: true, collection: false),
        CatalogFont(
            id: "source-code-pro", name: "Source Code Pro", latinName: "Source Code Pro", script: .latin,
            style: "Mono", blurb: "Adobe 的等寬字型，與 Source Sans 同一系列，可選粗細", publisher: "Google Fonts",
            license: "OFL-1.1", url: google("sourcecodepro", "SourceCodePro[wght].ttf"),
            sha256: "b400fc584e10aff25d0e775ce181b4fc1c5ea1b5dc37b81aeb2084375b945790", byteCount: 212_340,
            member: nil, fileName: "SourceCodePro[wght].ttf", licenseURL: googleLicense("sourcecodepro"),
            variable: true, collection: false),
        CatalogFont(
            id: "ibm-plex-mono", name: "IBM Plex Mono", latinName: "IBM Plex Mono", script: .latin, style: "Mono",
            blurb: "IBM Plex 的等寬版", publisher: "Google Fonts", license: "OFL-1.1",
            url: google("ibmplexmono", "IBMPlexMono-Regular.ttf"),
            sha256: "6a3412f058c7d8dfd9170c41e85ade48e5156ecb89356110ca57a0a27734af46", byteCount: 135_580,
            member: nil, fileName: "IBMPlexMono-Regular.ttf", licenseURL: googleLicense("ibmplexmono"),
            variable: false, collection: false),
        CatalogFont(
            id: "fira-mono", name: "Fira Mono", latinName: "Fira Mono", script: .latin, style: "Mono",
            blurb: "Mozilla 的 Fira Sans 的等寬版", publisher: "Google Fonts", license: "OFL-1.1",
            url: google("firamono", "FiraMono-Regular.ttf"),
            sha256: "2e00b0cf3106a3d792f35711b7722740b76c02ee7300ea8c60f940584b7a8ac9", byteCount: 174_596,
            member: nil, fileName: "FiraMono-Regular.ttf", licenseURL: googleLicense("firamono"),
            variable: false, collection: false),
        CatalogFont(
            id: "atkinson-hyperlegible-mono", name: "Atkinson Hyperlegible Mono",
            latinName: "Atkinson Hyperlegible Mono", script: .latin, style: "Mono",
            blurb: "Atkinson Hyperlegible 的等寬版，低視力也好認，可選粗細", publisher: "Google Fonts",
            license: "OFL-1.1", url: google("atkinsonhyperlegiblemono", "AtkinsonHyperlegibleMono[wght].ttf"),
            sha256: "5ce8b1698d1ded7dff2178c1a3ad159470085a58ea239e8b2cb88f4fb4a6f646", byteCount: 53_960,
            member: nil, fileName: "AtkinsonHyperlegibleMono[wght].ttf",
            licenseURL: googleLicense("atkinsonhyperlegiblemono"), variable: true, collection: false),
    ]
}
