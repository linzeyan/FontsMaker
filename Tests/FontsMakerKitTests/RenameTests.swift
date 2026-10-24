import Foundation
import Testing

@testable import FontsMakerKit

/// Naming rules (technical design §5.5, product spec §4.3) on ops.ttf, whose
/// names span Windows en/zh-TW/zh-CN/zh-HK and Mac Roman, with IDs 16/17 and
/// the in-file Reserved Font Name "Moonlit".
struct RenameTests {
    private let provenance = "FontsMaker 0.1.0; recipe 1a2b3c4d"

    private func renamed(
        _ family: String = "Example Kai", zhTW: String? = "範例楷", style: String = "Regular", weight: UInt16? = nil
    ) throws -> (Font, RenameReport) {
        var font = try OpsFixture().font
        let report = try font.rename(
            RenameOptions(
                familyName: family, localizedFamilyNames: zhTW.map { ["zh-TW": $0] } ?? [:], styleName: style,
                weightClass: weight, provenance: provenance))
        return (font, report)
    }

    private func table(_ font: Font, _ nameID: UInt16) -> [String: String] {
        var result: [String: String] = [:]
        for record in font.names where record.nameID == nameID {
            result["\(record.platformID)/\(String(record.languageID, radix: 16))"] = record.string
        }
        return result
    }

    @Test func replacesEveryIdentityRecordInEveryLanguage() throws {
        let source = try OpsFixture().font
        let (font, report) = try renamed()
        let identity: Set<UInt16> = [1, 2, 3, 4, 5, 6, 16, 17]

        // Old zh-CN, zh-HK and Mac records would keep the old name in some menus.
        let leftovers = font.names.filter {
            identity.contains($0.nameID) && !($0.platformID == 3 && [0x409, 0x404].contains($0.languageID))
        }
        #expect(leftovers.isEmpty, "\(leftovers)")
        #expect(table(font, 1) == ["3/409": "Example Kai", "3/404": "範例楷"])
        #expect(table(font, 2) == ["3/409": "Regular", "3/404": "Regular"])
        #expect(table(font, 3) == ["3/409": "1.500;FontsMaker;ExampleKai-Regular"])
        #expect(table(font, 4) == ["3/409": "Example Kai Regular", "3/404": "範例楷 Regular"])
        #expect(table(font, 5) == ["3/409": "Version 1.500; FontsMaker 0.1.0; recipe 1a2b3c4d"])
        #expect(table(font, 6) == ["3/409": "ExampleKai-Regular"])
        #expect(table(font, 16).isEmpty && table(font, 17).isEmpty, "Regular is a RIBBI style: no typographic names")

        let copyright = #"Copyright 2026 FontsMaker Tests, with Reserved Font Name "Moonlit"."#
        #expect(
            table(font, 0) == [
                "3/409": copyright + "; Modified with FontsMaker", "1/0": copyright + "; Modified with FontsMaker",
            ])
        for nameID: UInt16 in [13, 14] {
            #expect(font.names.filter { $0.nameID == nameID } == source.names.filter { $0.nameID == nameID })
        }
        for record in font.names where ![0, 13, 14].contains(record.nameID) {
            let text = record.string ?? ""
            for old in ["FM Ops", "FMOps", "運算測試", "运算测试"] {
                #expect(!text.contains(old), "name ID \(record.nameID) still says \(old)")
            }
        }
        #expect(report.removedRecords == 15)
        #expect(report.writtenRecords == 9)
        #expect(report.reservedNameNotice.contains("\"Moonlit\""))
        #expect(report.reservedNameNotice.contains("https://openfontlicense.org"))

        // The writer carries names and style bits through to the file.
        let reread = try Font(bytes: try font.serialize(options: WriteOptions()))
        #expect(Set(reread.names) == Set(font.names))
        #expect(reread.os2 == font.os2)
        #expect(reread.macStyle == font.macStyle)
    }

    struct StyleCase: Sendable, CustomTestStringConvertible {
        let style: String
        let id1: String
        let id2: String
        let typographic: (String, String)?
        let postScript: String
        let fsSelection: UInt16
        let macStyle: UInt16
        let weight: UInt16
        var testDescription: String { style }
    }

    /// OpenType naming model: RIBBI styles use IDs 1/2 only; any other weight
    /// moves into ID 1 and the real family/style into IDs 16/17.
    @Test(arguments: [
        StyleCase(
            style: "Regular", id1: "Example Kai", id2: "Regular", typographic: nil, postScript: "ExampleKai-Regular",
            fsSelection: 0x40, macStyle: 0, weight: 400),
        StyleCase(
            style: "Bold", id1: "Example Kai", id2: "Bold", typographic: nil, postScript: "ExampleKai-Bold",
            fsSelection: 0x20, macStyle: 1, weight: 700),
        StyleCase(
            style: "Italic", id1: "Example Kai", id2: "Italic", typographic: nil, postScript: "ExampleKai-Italic",
            fsSelection: 0x01, macStyle: 2, weight: 400),
        StyleCase(
            style: "Bold Italic", id1: "Example Kai", id2: "Bold Italic", typographic: nil,
            postScript: "ExampleKai-BoldItalic", fsSelection: 0x21, macStyle: 3, weight: 700),
        StyleCase(
            style: "Medium", id1: "Example Kai Medium", id2: "Regular", typographic: ("Example Kai", "Medium"),
            postScript: "ExampleKai-Medium", fsSelection: 0x40, macStyle: 0, weight: 500),
        StyleCase(
            style: "Light Italic", id1: "Example Kai Light", id2: "Italic",
            typographic: ("Example Kai", "Light Italic"), postScript: "ExampleKai-LightItalic", fsSelection: 0x01,
            macStyle: 2, weight: 300),
        StyleCase(
            style: "SemiBold", id1: "Example Kai SemiBold", id2: "Regular", typographic: ("Example Kai", "SemiBold"),
            postScript: "ExampleKai-SemiBold", fsSelection: 0x40, macStyle: 0, weight: 600),
    ])
    func styleFollowsTheNamingModel(_ expected: StyleCase) throws {
        let (font, report) = try renamed(style: expected.style)
        #expect(
            table(font, 1) == ["3/409": expected.id1, "3/404": "範例楷" + expected.id1.dropFirst("Example Kai".count)])
        #expect(table(font, 2)["3/409"] == expected.id2)
        #expect(table(font, 6) == ["3/409": expected.postScript])
        #expect(table(font, 16)["3/409"] == expected.typographic?.0)
        #expect(table(font, 17)["3/409"] == expected.typographic?.1)
        #expect(table(font, 16)["3/404"] == expected.typographic.map { _ in "範例楷" })
        #expect(table(font, 4)["3/409"] == "Example Kai " + (expected.typographic?.1 ?? expected.id2))
        #expect(font.os2?.fsSelection == expected.fsSelection)
        #expect(font.macStyle == expected.macStyle)
        #expect(font.os2?.weightClass == expected.weight)
        #expect(report.typographicNames == (expected.typographic != nil))
    }

    @Test func weightClassAndUnrelatedStyleBits() throws {
        #expect(try renamed(style: "Medium", weight: 550).0.os2?.weightClass == 550, "explicit weight wins")
        #expect(throws: RenameError.unknownWeight(styleName: "Condensed")) { try renamed(style: "Condensed") }
        #expect(try renamed(style: "Condensed", weight: 400).1.postScriptName == "ExampleKai-Condensed")

        // USE_TYPO_METRICS (bit 7) and other non-style bits are not the rename's business.
        var font = try OpsFixture().font
        font.os2?.fsSelection |= 0x80
        font.macStyle |= 0x04
        _ = try font.rename(RenameOptions(familyName: "Example Kai", styleName: "Bold", provenance: provenance))
        #expect(font.os2?.fsSelection == 0xA0)
        #expect(font.macStyle == 0x05)

        // Renaming an output again must not stack the copyright suffix.
        // The output is now the source, so its own family name is off limits.
        _ = try font.rename(RenameOptions(familyName: "Second Kai", provenance: provenance))
        #expect(
            font.names.filter { $0.nameID == 0 }.allSatisfy {
                $0.string?.hasSuffix("Tests, with Reserved Font Name \"Moonlit\".; Modified with FontsMaker") == true
            })
    }

    @Test func newNameMustNotContainASourceFamilyName() throws {
        // Case and spaces do not matter: the PostScript name drops spaces.
        #expect(
            throws: RenameError.containsSourceFamilyName(
                field: "familyName", value: "fm ops plus", sourceName: "FM Ops")
        ) {
            try renamed("fm ops plus")
        }
        #expect(
            throws: RenameError.containsSourceFamilyName(field: "familyName", value: "FMOps Kai", sourceName: "FM Ops")
        ) {
            try renamed("FMOps Kai")
        }
        // Every language counts: 运算测试 exists only as the zh-CN family name.
        #expect(
            throws: RenameError.containsSourceFamilyName(
                field: "localizedFamilyName.zh-TW", value: "运算测试粗", sourceName: "运算测试")
        ) {
            try renamed(zhTW: "运算测试粗")
        }
    }

    @Test func newNameMustNotContainAnInFileReservedFontName() throws {
        let error = #expect(throws: RenameError.self) { try renamed("Moonlit Kai") }
        #expect(error == .containsReservedFontName(field: "familyName", value: "Moonlit Kai", reservedName: "Moonlit"))
        #expect(error?.description.contains("Reserved Font Name") == true)
    }

    @Test func otherInvalidNames() throws {
        #expect(throws: RenameError.self) { try renamed("範例 Kai") }
        #expect(throws: RenameError.postScriptNameTooLong(String(repeating: "A", count: 60) + "-Regular")) {
            try renamed(String(repeating: "A", count: 60))
        }
        let font = try OpsFixture().font
        #expect(throws: RenameError.unsupportedLanguage("ja")) {
            try font.validateRename(
                RenameOptions(familyName: "Example Kai", localizedFamilyNames: ["ja": "例"], provenance: provenance))
        }
    }
}
