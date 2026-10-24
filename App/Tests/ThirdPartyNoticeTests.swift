import Testing

struct ThirdPartyNoticeTests {
    /// The licenses screen lists the three items design §11 requires the app
    /// to credit, each with its full license text from the engine's bundle,
    /// and ZIPFoundation, which the app links for downloads (MIT asks for
    /// its notice in every copy).
    @Test func everyNoticeCarriesItsLicenseText() throws {
        let notices = try ThirdPartyNotice.all()
        #expect(
            notices.map(\.license) == ["Apache License 2.0", "Unicode License v3", "Apache License 2.0", "MIT License"])
        #expect(notices[3].name.hasPrefix("ZIPFoundation") && notices[3].text.contains("Thomas Zoechling"))
        #expect(notices[0].name.hasPrefix("OpenCC") && notices[1].name.hasPrefix("Unicode"))
        #expect(notices[2].name.contains("cu2qu") && notices[2].origin.contains("Google"))
        #expect(notices[0].text.hasPrefix("Apache License") && notices[2].text == notices[0].text)
        #expect(notices[1].text.hasPrefix("UNICODE LICENSE V3"))
    }

    /// Every OpenCC file the engine bundles is credited, the phrase
    /// dictionaries of s2t `phrases` included; the generated one is not in
    /// OpenCC's repository, so its notice says where it comes from.
    @Test func openCCNoticeNamesEveryBundledDictionary() throws {
        let openCC = try #require(try ThirdPartyNotice.all().first)
        for file in [
            "STCharacters.txt", "TWVariants.txt", "STPhrases.txt", "TWVariantsPhrases.txt",
            "STPhrases_GeneratedFromRegionalPhrases.txt",
        ] {
            #expect(openCC.name.contains(file), "\(file)")
        }
        #expect(openCC.origin.contains("025f371") && openCC.origin.contains("HKPhrases.txt"))
        #expect(openCC.origin.contains("TWPhrases.txt") && openCC.origin.contains("data/CMakeLists.txt"))
    }
}
