import Foundation

/// Third-party data and code shipped in the app (technical design §11).
struct ThirdPartyNotice: Identifiable, Sendable {
    var id: String { name }
    var name: String
    var usage: String
    var license: String
    var origin: String
    var text: String

    /// License texts come from FontsMakerKit's resource bundle, where each
    /// sits next to the data it covers, so the app cannot ship a different copy.
    static func all() throws -> [ThirdPartyNotice] {
        let apache = try kitResource("OpenCC/LICENSE")
        return [
            ThirdPartyNotice(
                name:
                    "OpenCC 1.4.2（STCharacters.txt、TWVariants.txt、STPhrases.txt、TWVariantsPhrases.txt、"
                    + "STPhrases_GeneratedFromRegionalPhrases.txt）",
                usage: "簡轉繁字表與詞彙表", license: "Apache License 2.0",
                origin:
                    "Open Chinese Convert, commit 025f371, https://github.com/BYVoid/OpenCC。"
                    + "STPhrases_GeneratedFromRegionalPhrases.txt 是 OpenCC 建置時產生的檔案："
                    + "依同一 commit 的 data/CMakeLists.txt，從 HKPhrases.txt、TWPhrases.txt 產生",
                text: apache),
            ThirdPartyNotice(
                name: "Unicode Character Database 18.0.0（VerticalOrientation.txt）", usage: "偽直排的直排方向資料（UAX #50）",
                license: "Unicode License v3", origin: "Copyright © 1991-2026 Unicode, Inc., https://www.unicode.org",
                text: try kitResource("Unicode/LICENSE.txt")),
            ThirdPartyNotice(
                name: "fontTools cu2qu（移植為 Swift）", usage: "加粗後把三次曲線轉回 TrueType 二次曲線",
                license: "Apache License 2.0",
                origin:
                    "Copyright 2015 Google Inc.; cu2qu.py from fontTools 4.63, https://github.com/fonttools/fonttools",
                text: apache),
            ThirdPartyNotice(
                name: "ZIPFoundation 0.9.20", usage: "解開字型目錄與自訂來源下載的 zip", license: "MIT License",
                origin: "https://github.com/weichsel/ZIPFoundation", text: zipFoundationLicense),
        ]
    }

    /// ZIPFoundation's LICENSE at 0.9.20, verbatim: the package ships no
    /// resource bundle to read it from, as the engine's data does.
    private static let zipFoundationLicense = """
        MIT License

        Copyright (c) 2017-2025 Thomas Zoechling (https://www.peakstep.com)

        Permission is hereby granted, free of charge, to any person obtaining a copy
        of this software and associated documentation files (the "Software"), to deal
        in the Software without restriction, including without limitation the rights
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the Software is
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
        SOFTWARE.
        """

    /// SwiftPM names a target's resource bundle `<package>_<target>.bundle`
    /// and copies it into whatever links the target: the app or the test bundle.
    private static func kitResource(_ path: String) throws -> String {
        let candidates = [Bundle.main, Bundle(for: BundleToken.self)]
        for bundle in candidates {
            if let kit = bundle.url(forResource: "FontsMaker_FontsMakerKit", withExtension: "bundle") {
                let url = kit.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: url.path) {
                    return try String(contentsOf: url, encoding: .utf8)
                }
                #if os(macOS)
                    let nested = kit.appendingPathComponent("Contents/Resources").appendingPathComponent(path)
                    if FileManager.default.fileExists(atPath: nested.path) {
                        return try String(contentsOf: nested, encoding: .utf8)
                    }
                #endif
            }
        }
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "FontsMaker_FontsMakerKit.bundle/\(path)"])
    }
}

/// Finds the bundle these sources are compiled into: the app, or the test bundle.
final class BundleToken {}
