import Testing

@testable import FontsMakerKit

/// Technical design §7 and product spec §4.2–4.3.
struct LicenseTests {
    private let oflDescription = NameRecord(
        windowsLanguage: 0x409, nameID: 13,
        string: "This Font Software is licensed under the SIL Open Font License, Version 1.1.")

    @Test func restrictedEmbeddingWinsOverOFLText() {
        #expect(License.status(fsType: 0x0002, names: [oflDescription]) == .restricted)
        #expect(License.status(fsType: 0x0002 | 0x0100, names: []) == .restricted)
    }

    @Test func otherEmbeddingBitsDoNotBlock() {
        #expect(License.status(fsType: 0x0004, names: [oflDescription]) == .openFontLicense)
        #expect(License.status(fsType: 0x0008, names: [oflDescription]) == .openFontLicense)
    }

    @Test(arguments: [
        (13, "This Font Software is licensed under the SIL Open Font License, Version 1.1."),
        (14, "https://scripts.sil.org/OFL"),
        (14, "http://scripts.sil.org/OFL_web"),
        (14, "https://openfontlicense.org"),
    ])
    func recognizesOFLMarkers(nameID: Int, text: String) {
        let record = NameRecord(windowsLanguage: 0x409, nameID: UInt16(nameID), string: text)
        #expect(License.status(fsType: 0, names: [record]) == .openFontLicense)
    }

    @Test func otherLicensesAreUnknown() {
        let names = [
            NameRecord(windowsLanguage: 0x409, nameID: 13, string: "All rights reserved."),
            // OFL wording outside the license records does not count.
            NameRecord(windowsLanguage: 0x409, nameID: 0, string: "Released under the Open Font License"),
        ]
        #expect(License.status(fsType: 0, names: names) == .unknown)
        #expect(License.status(fsType: 0, names: []) == .unknown)
    }

    @Test func syntheticFontIsOFLWithItsReservedName() throws {
        let font = try Fixtures.font("synthetic.ttf")
        #expect(font.licenseStatus == .openFontLicense)
        #expect(font.reservedFontNames == ["FM Synth"])
    }

    @Test(arguments: [
        ("Copyright 2010 Adobe (http://www.adobe.com/), with Reserved Font Name 'Source'.", ["Source"]),
        ("Copyright 2014 Google Inc. with Reserved Font Names \"Noto\" and \"Noto Sans\".", ["Noto", "Noto Sans"]),
        ("Copyright (c) 2020, Foo, with Reserved Font Names: \"A\", \"B\", and \"C\"", ["A", "B", "C"]),
        ("Copyright 2021 X, with Reserved Font Name \u{201C}Curly\u{201D}. Copyright 2022 Y", ["Curly"]),
        ("WITH RESERVED FONT NAME \"Upper\"", ["Upper"]),
        ("Copyright 2022 Someone. All rights reserved.", []),
        ("with Reserved Font Name Unquoted.", []),
    ])
    func extractsQuotedReservedFontNames(text: String, expected: [String]) {
        #expect(License.reservedFontNames(in: text) == expected)
    }

    /// Fonts that embed the full OFL text in name ID 13 mention the term itself;
    /// that is a definition, not a declaration.
    @Test func fullOFLTextDeclaresNothing() {
        let text = """
            "Reserved Font Name" refers to any names specified as such after the copyright statement(s).
            3) No Modified Version of the Font Software may use the Reserved Font Name(s) unless explicit \
            written permission is granted by the corresponding Copyright Holder.
            """
        #expect(License.reservedFontNames(in: text).isEmpty)
    }

    @Test func namesAreCollectedFromCopyrightAndLicenseRecordsOnly() {
        let names = [
            NameRecord(windowsLanguage: 0x409, nameID: 0, string: "with Reserved Font Name \"Alpha\""),
            NameRecord(windowsLanguage: 0x404, nameID: 0, string: "with Reserved Font Name \"Alpha\""),
            NameRecord(windowsLanguage: 0x409, nameID: 13, string: "Reserved Font Names \"Beta\""),
            NameRecord(windowsLanguage: 0x409, nameID: 10, string: "Reserved Font Name \"Ignored\""),
        ]
        #expect(License.reservedFontNames(names: names) == ["Alpha", "Beta"])
    }
}
