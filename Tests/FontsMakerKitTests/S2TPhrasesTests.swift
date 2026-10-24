import CoreText
import Foundation
import Testing

@testable import FontsMakerKit

private func codePoints(_ text: String) -> [UInt32] { text.unicodeScalars.map(\.value) }

/// The source font's glyphs for `text`: what a font built with s2t must show
/// for OpenCC's output (s2t keeps every glyph ID, it only re-points the cmap).
private func sourceGlyphs(_ font: Font, _ text: String) -> [CGGlyph] {
    text.unicodeScalars.map { font.characterMap.mappings[$0.value] ?? 0 }
}

/// ops.ttf after the cmap half of s2t `phrases`, with the rules derived from
/// the bundled OpenCC dictionaries. Its characters make real phrase rules:
/// 一里, 回里 and 后里 stay 里 where the cmap shows 裏 (or 裡), and 后里 also
/// needs 后's own glyph, which no code point reaches once 后 shows 後.
private struct OpsPhrases {
    let ops: OpsFixture
    var font: Font
    let rules: PhraseRules

    init(taiwanVariants: Bool) throws {
        ops = try OpsFixture()
        var font = ops.font
        _ = try font.convertSimplifiedToTraditional(
            S2TOptions(mode: .single, taiwanVariants: taiwanVariants, phrases: true))
        let plan = try #require(font.phrasePlan)
        rules = try PhraseRules(
            try OpenCCPhrases.bundled(taiwanVariants: taiwanVariants).conversions,
            cmap: font.characterMap.mappings, targetGlyphs: plan.targetGlyphs)
        self.font = font
    }

    func glyphs(_ text: String) -> [UInt16] { text.unicodeScalars.map { font.characterMap.mappings[$0.value]! } }

    /// The font with `rules` in its GSUB, as CoreText lays it out.
    func coreText(_ rules: PhraseRules) throws -> CTFont {
        var font = font
        font.tables["GSUB"] = try rules.gsub(addingTo: font.tables["GSUB"]).table
        font.phrasePlan = nil
        return try coreTextFont(try font.write())
    }
}

/// Phrase-level simplified → traditional (technical design §5.4): GSUB rules
/// that make a shaper show what OpenCC converts a phrase to.
struct S2TPhrasesTests {
    @Test func bundledPhraseDictionariesGiveOpenCCsResults() throws {
        let s2t = try OpenCCPhrases.bundled(taiwanVariants: false)
        let s2tw = try OpenCCPhrases.bundled(taiwanVariants: true)
        // STPhrases plus the 556 generated regional phrases (the spike's count).
        #expect(s2t.conversions.count == 49_792)
        func converted(_ phrases: OpenCCPhrases, _ phrase: String) -> String? {
            phrases.conversions.first { $0.phrase == codePoints(phrase) }.map {
                String(String.UnicodeScalarView($0.converted.compactMap(Unicode.Scalar.init)))
            }
        }
        #expect(converted(s2t, "里程碑") == "里程碑")
        #expect(converted(s2t, "心里") == "心裏")
        #expect(converted(s2tw, "心里") == "心裡", "s2tw runs TWVariants over the phrase's value")
        #expect(converted(s2t, "头发") == "頭髮")
        // A key in both dictionaries takes STPhrases' value (s2t.json lists it first).
        #expect(converted(s2t, "幺么小丑") == "幺麼小醜")
    }

    // MARK: Derivation

    /// OpenCC splits text into the longest phrases left to right and converts
    /// each whole. A shaper given only the rules that change something would
    /// apply 回里 → 回里 inside 一回里, where OpenCC took 一回 first and shows
    /// 一回裏. So 一回 becomes an identity rule that consumes its span, and so
    /// must 一发, which pre-empts only that blocker (一发回里 is 一发|回里).
    @Test func blockingRulesReproduceOpenCCsSegmentation() throws {
        let fixture = try OpsPhrases(taiwanVariants: false)
        let g = fixture.glyphs
        #expect(Set(fixture.rules.active.map(\.input)) == [g("一里"), g("回里"), g("后里")])
        let blocking = Set(fixture.rules.blocking.map(\.input))
        #expect(blocking.isSuperset(of: [g("一回"), g("发回"), g("后后"), g("一发"), g("发发")]))
        #expect(!blocking.contains(g("后汉")), "后汉 cannot pre-empt any rule")
        #expect(!blocking.contains(g("口里")), "no rule starts with 裏")

        let ops = fixture.ops
        func shows(_ font: CTFont, _ input: String, _ expected: String) -> Bool {
            laidOutGlyphs(font, input) == sourceGlyphs(ops.font, expected)
        }
        let complete = try fixture.coreText(fixture.rules)
        // Expected strings are `opencc -c s2t.json` (1.4.2).
        #expect(shows(complete, "一回里", "一回裏"))
        #expect(shows(complete, "一发回里", "一發回里"))
        #expect(shows(complete, "发回里", "發回裏"))
        #expect(shows(complete, "后后里", "後後裏"))
        #expect(shows(complete, "里里", "裏裏"))
        #expect(shows(complete, "后里", "后里"))
        #expect(shows(complete, "回里发", "回里發"))
        #expect(shows(complete, "里", "裏"), "outside phrases the character-level conversion stays")

        var activeOnly = fixture.rules
        activeOnly.blocking = []
        #expect(shows(try fixture.coreText(activeOnly), "一回里", "一回里"), "without blockers 回里 fires inside 一回")
        var firstRound = fixture.rules
        firstRound.blocking.removeAll { $0.input == g("一发") }
        #expect(shows(try fixture.coreText(firstRound), "一发回里", "一發回裏"), "一发 only blocks the blocker 发回")
    }

    @Test func taiwanVariantsRulesFollowS2TW() throws {
        let fixture = try OpsPhrases(taiwanVariants: true)
        let font = try fixture.coreText(fixture.rules)
        // `opencc -c s2tw.json`: 里 is 裡 outside phrases, 里 inside 一里.
        for (input, expected) in [("一回里", "一回裡"), ("一里", "一里"), ("后里", "后里"), ("发回里", "發回裡"), ("里里", "裡裡")] {
            #expect(laidOutGlyphs(font, input) == sourceGlyphs(fixture.ops.font, expected), "\(input)")
        }
    }

    private func conversion(_ phrase: String, _ converted: String) -> PhraseConversion {
        PhraseConversion(phrase: codePoints(phrase), converted: codePoints(converted))
    }

    /// Glyphs after a character-level s2t where 发 and 發 share glyph 20, 头
    /// and 頭 share 21; 髮 is 22, 伐 23.
    private let sharedCmap: [UInt32: UInt16] = [0x53D1: 20, 0x767C: 20, 0x5934: 21, 0x982D: 21, 0x9AEE: 22, 0x4F10: 23]
    private let sharedTargets: [UInt32: UInt16] = [0x767C: 20, 0x982D: 21, 0x9AEE: 22, 0x4F10: 23]

    /// Two phrases the font cannot tell apart need different glyphs: whichever
    /// rule wins, the other phrase shows wrongly, so the build stops (§5.4).
    @Test func phrasesWithOneGlyphSequenceButDifferentResultsAreAnError() throws {
        let conversions = [conversion("头发", "頭髮"), conversion("頭發", "頭伐")]
        let error = #expect(throws: S2TError.self) {
            try PhraseRules(conversions, cmap: sharedCmap, targetGlyphs: sharedTargets)
        }
        #expect(error == .conflictingPhrases(["头发 → 頭髮 and 頭發 → 頭伐"]))
        #expect(error?.description.contains("头发 → 頭髮 and 頭發 → 頭伐") == true)

        // The same result through either spelling is one rule, not a conflict.
        let merged = try PhraseRules(
            [conversion("头发", "頭髮"), conversion("頭發", "頭髮")], cmap: sharedCmap, targetGlyphs: sharedTargets)
        #expect(merged.active.count == 1 && merged.mergedPhrases == 1)
    }

    /// An unchanged phrase that looks like an active rule's phrase gets that
    /// rule (幺么小丑 reads as 幺麼小丑 in GuanKiapTsingKhai). Reported, not an
    /// error: the spike kept it, and refusing would refuse that font.
    @Test func unchangedPhraseSharingAnActiveRulesGlyphsIsReportedAsShadowed() throws {
        let rules = try PhraseRules(
            [conversion("头发", "頭髮"), conversion("頭發", "頭發")], cmap: sharedCmap, targetGlyphs: sharedTargets)
        #expect(rules.active.map(\.input) == [[21, 20]])
        #expect(rules.shadowed == [.init(phrase: "頭發", converted: "頭發", rulePhrase: "头发")])
        #expect(rules.unchanged == 0 && rules.blocking.isEmpty)
    }

    @Test func phrasesTheFontCannotShowAreDroppedWithTheirReason() throws {
        let rules = try PhraseRules(
            [conversion("头发", "頭髮"), conversion("头发髻", "頭髮髻"), conversion("发头", "發頭𩠐")],
            cmap: sharedCmap, targetGlyphs: sharedTargets.filter { $0.key != 0x9AEE })
        #expect(
            rules.dropped == [
                .init(phrase: "头发", converted: "頭髮", reason: .convertedCharacterNotInFont(0x9AEE)),
                .init(phrase: "头发髻", converted: "頭髮髻", reason: .characterNotInFont(0x9AFB)),
                .init(phrase: "发头", converted: "發頭𩠐", reason: .lengthChanged),
            ])
        #expect(rules.active.isEmpty)
    }

    // MARK: GSUB

    /// Design §4.3: the old lookups are reached through extension lookups
    /// pointing at their original bytes, so whatever they encode (formats the
    /// engine does not parse) survives exactly; their indices stay, so
    /// contextual lookups inside them still call the right lookups.
    private func expectLookupsPreserved(_ source: [UInt8], _ rebuilt: [UInt8]) throws {
        let before = try GSUBLayout(parsing: source)
        let after = try GSUBLayout(parsing: rebuilt)
        try #require(after.lookups.count > before.lookups.count)
        for (index, (old, new)) in zip(before.lookups, after.lookups).enumerated() {
            #expect(old.type == new.type && old.flag == new.flag && old.markFilteringSet == new.markFilteringSet)
            #expect(old.subtables.count == new.subtables.count)
            for (oldStart, newStart) in zip(old.subtables, new.subtables) {
                let length = source.count - oldStart
                #expect(
                    Array(rebuilt[newStart..<newStart + length]) == Array(source[oldStart...]),
                    "lookup \(index) subtable bytes")
            }
        }
        // Every feature keeps its lookups; rlig gains the context lookup in every language system.
        let contextLookup = UInt16(before.lookups.count)
        for feature in before.features {
            #expect(after.features.contains { $0.tag == feature.tag && $0.lookups.starts(with: feature.lookups) })
        }
        for (oldScript, newScript) in zip(before.scripts, after.scripts) {
            #expect(oldScript.tag == newScript.tag)
            let langSystems = [newScript.defaultLangSys].compactMap { $0 } + newScript.languages.map(\.langSys)
            for langSys in langSystems {
                let tags = langSys.features.map { after.features[Int($0)].tag }
                let rlig = langSys.features.first { after.features[Int($0)].tag == "rlig" }
                #expect(rlig.map { after.features[Int($0)].lookups.contains(contextLookup) } == true, "\(tags)")
            }
        }
        #expect(after.features.map(\.tag) == after.features.map(\.tag).sorted(by: tagPrecedes))
    }

    @Test func rebuiltGSUBKeepsExistingLookupsAndVerticalForms() throws {
        let fixture = try OpsPhrases(taiwanVariants: false)
        let source = try #require(fixture.ops.font.tables["GSUB"])
        let rebuilt = try fixture.rules.gsub(addingTo: source).table
        try expectLookupsPreserved(source, rebuilt)

        // A rebuilt table holds only extension lookups; rebuilding it again
        // must still reach the same original bytes.
        let again = try GSUBLayout(parsing: rebuilt).encoded(adding: [])
        let reparsed = try GSUBLayout(parsing: again)
        let original = try GSUBLayout(parsing: source)
        for (old, new) in zip(original.lookups, reparsed.lookups) {
            for (oldStart, newStart) in zip(old.subtables, new.subtables) {
                #expect(Array(again[newStart..<newStart + source.count - oldStart]) == Array(source[oldStart...]))
            }
        }

        var font = fixture.font
        font.tables["GSUB"] = rebuilt
        font.phrasePlan = nil
        let reread = try Font(data: try font.write())
        #expect(reread.verticalSubstitutions == fixture.ops.font.verticalSubstitutions, "vert alternates still found")
        #expect(!reread.verticalSubstitutions.isEmpty)
    }

    /// Design §4.1: OpenType 1.8 feature variations would need their feature
    /// indices remapped; refusing is better than silently dropping them.
    @Test func featureVariationsAreRefusedNotDropped() throws {
        var writer = ByteWriter()
        writer.u32(0x0001_0001)
        for offset in [14, 16, 18] { writer.u16(UInt16(offset)) }  // ScriptList, FeatureList, LookupList
        writer.u32(20)
        for _ in 0..<3 { writer.u16(0) }  // three empty lists
        writer.u32(0)
        let error = #expect(throws: FontLoadError.self) { try GSUBLayout(parsing: writer.bytes) }
        #expect(error?.description.contains("FeatureVariations") == true)

        writer.bytes.writeU32(0, at: 10)  // GSUB 1.1 without feature variations is fine
        #expect(throws: Never.self) { try GSUBLayout(parsing: writer.bytes) }
    }

    @Test func fontWithoutGSUBGetsOneRegisteredForHanAndDefaultScripts() throws {
        var fixture = try OpsPhrases(taiwanVariants: false)
        fixture.font.tables["GSUB"] = nil
        let table = try fixture.rules.gsub(addingTo: nil).table
        let layout = try GSUBLayout(parsing: table)
        #expect(layout.scripts.map(\.tag) == ["DFLT", "hani", "latn"])
        #expect(layout.features.map(\.tag) == ["rlig"])
        let ct = try fixture.coreText(fixture.rules)
        #expect(laidOutGlyphs(ct, "一回里") == sourceGlyphs(fixture.ops.font, "一回裏"))
    }

    // MARK: Build integration

    private func build(_ steps: String) throws -> BuildResult {
        let recipe = try Recipe(
            json: recipeJSON(
                sourceFile: OpsFixture.fileName, sha256: try OpsFixture.sha256,
                output: #"{"familyName": "Phrase Test"}"#, steps: steps))
        return try RecipeBuilder.build(recipe, sourceData: Data(try OpsFixture.bytes), options: BuildOptions())
    }

    @Test func buildReportsThePhraseRulesInTheS2TStep() throws {
        let result = try build(#"[{"op": "s2t", "phrases": true}]"#)
        guard
            case .s2t(let options, let report) = result.reports.first(where: {
                if case .s2t = $0 { true } else { false }
            })
        else {
            Issue.record("no s2t report")
            return
        }
        #expect(options.phrases)
        let phrases = try #require(report.phrases)
        #expect(phrases.activeRules == 3)
        // 一回, 发回, 后后, 回回 pre-empt 一里/回里/后里; 一发, 发发 pre-empt 发回.
        #expect(phrases.blockingRules == 6)
        #expect(phrases.gsubBytesBefore == 74 && phrases.gsubBytesAfter > 74)
        #expect(phrases.contextSubtables == 1 && phrases.singleSubstitutionLookups == 1)
        #expect(
            phrases.dropped.count + phrases.unchanged + phrases.mergedPhrases + phrases.activeRules
                + phrases.shadowed.count == phrases.phrases, "every phrase is accounted for")
        let lines = result.reports.first { if case .s2t = $0 { true } else { false } }!.summary.split(separator: "\n")
        #expect(lines.count == 2 && lines[1].contains("3 substitution rules") && lines[1].contains("6 blocking rules"))

        let font = try coreTextFont(result.fontData)
        #expect(laidOutGlyphs(font, "一回里后里") == sourceGlyphs(try OpsFixture().font, "一回裏后里"))
        #expect(try build(#"[{"op": "s2t", "phrases": true}]"#).fontData == result.fontData, "same input, same bytes")
    }

    /// Without `phrases` nothing about GSUB changes: old recipes keep their bytes.
    @Test func withoutPhrasesGSUBIsCopiedUnchanged() throws {
        let result = try build(#"[{"op": "s2t", "taiwanVariants": true}]"#)
        let source = try OpsFixture.bytes
        #expect(table("GSUB", in: [UInt8](result.fontData)) == table("GSUB", in: source))
        guard case .s2t(_, let report) = result.reports.first(where: { if case .s2t = $0 { true } else { false } })
        else {
            Issue.record("no s2t report")
            return
        }
        #expect(report.phrases == nil)
    }

    @Test func phrasesNeedSingleMode() throws {
        var font = try OpsFixture().font
        #expect(throws: S2TError.phrasesNeedSingleMode) {
            try font.convertSimplifiedToTraditional(S2TOptions(mode: .skipAmbiguous, phrases: true))
        }
        #expect(font.characterMap == (try OpsFixture()).font.characterMap, "nothing changed")
        #expect(throws: S2TError.phrasesNeedSingleMode) {
            try S2TTextConverter(font: font, options: S2TOptions(mode: .skipAmbiguous, phrases: true))
        }
    }

    /// The rules are glyph IDs, written after every step; a font written with
    /// the plan still pending would silently lack its phrase rules.
    @Test func writingBeforeThePhraseRulesAreBuiltIsAnError() throws {
        var font = try OpsFixture().font
        _ = try font.convertSimplifiedToTraditional(S2TOptions(phrases: true))
        #expect(throws: FontWriteError.self) { try font.write() }
        _ = try font.buildPhraseLookups()
        #expect(throws: Never.self) { try font.write() }
    }

    /// Design §5.3/§5.4: after s2t no code point reaches 后's own glyph (后
    /// shows 後), yet the 后里 rule substitutes it; pseudoVertical must turn it
    /// like the characters it shows, or 后 would stand upright in turned text.
    @Test func pseudoVerticalTurnsGlyphsOnlyPhraseRulesReach() throws {
        let ops = try OpsFixture()
        let hou = ops.glyph("uni540E")
        let result = try build(
            #"[{"op": "s2t", "phrases": true}, {"op": "pseudoVertical", "punctuation": "centered"}]"#)
        let built = try Font(data: result.fontData)
        #expect(!built.characterMap.mappings.values.contains(hou), "no code point reaches 后's glyph")
        let (ascender, descender) = ops.font.emBoxVerticalExtent()
        let turned = try ops.font.turnedOutline(
            of: Int(hou), centered: false, ascender: ascender, descender: descender)
        #expect(points(built.glyphs[Int(hou)]) == turned.points)

        let font = try coreTextFont(result.fontData)
        let shown = laidOutGlyphs(font, "后里")
        #expect(shown.first == hou, "the rule's 后 is the turned glyph")
    }

    // MARK: GuanKiapTsingKhai

    /// GuanKiapTsingKhai after s2t with phrases, and the built font; built
    /// once for the tests below (several seconds per configuration).
    struct GuanKiap: Sendable {
        let source: Font
        let converted: Font
        let rules: PhraseRules
        let report: PhraseReport
        let output: Data

        init(taiwanVariants: Bool) throws {
            source = try Font(bytes: try ReferenceFonts.bytes("GuanKiapTsingKhai.ttf"))
            var converted = source
            _ = try converted.convertSimplifiedToTraditional(
                S2TOptions(mode: .single, taiwanVariants: taiwanVariants, phrases: true))
            let plan = try #require(converted.phrasePlan)
            rules = try PhraseRules(
                try OpenCCPhrases.bundled(taiwanVariants: taiwanVariants).conversions,
                cmap: converted.characterMap.mappings, targetGlyphs: plan.targetGlyphs)
            self.converted = converted
            var built = converted
            report = try built.buildPhraseLookups()
            output = try built.write()
        }

        static let taiwan = Result { try GuanKiap(taiwanVariants: true) }
        static let plain = Result { try GuanKiap(taiwanVariants: false) }

        static func get(taiwanVariants: Bool) throws -> GuanKiap {
            try (taiwanVariants ? taiwan : plain).get()
        }
    }

    /// The design's example: OpenCC takes 心里 first in 心里长了草, so 里长
    /// (village chief, 里長) must not apply; without the blocking rule 心里 a
    /// shaper applies it and shows 心里長了草.
    @Test func guanKiapMilestoneAndHeartExamples() throws {
        let built = try GuanKiap.get(taiwanVariants: true)
        let font = try coreTextFont(built.output)
        // `opencc -c s2tw.json`.
        for (input, expected) in [
            ("里程碑", "里程碑"), ("心里长了草", "心裡長了草"), ("头发", "頭髮"), ("皇后", "皇后"),
            ("这个国家的发展为后来里程碑", "這個國家的發展為後來里程碑"), ("公里", "公里"),
        ] {
            #expect(laidOutGlyphs(font, input) == sourceGlyphs(built.source, expected), "\(input)")
        }
        let g = { (text: String) in text.unicodeScalars.map { built.converted.characterMap.mappings[$0.value]! } }
        #expect(built.rules.blocking.contains { $0.input == g("心里") })
        #expect(built.rules.active.contains { $0.input == g("里长") })

        var activeOnly = built.rules
        activeOnly.blocking = []
        var withoutBlocking = built.converted
        withoutBlocking.tables["GSUB"] = try activeOnly.gsub(addingTo: withoutBlocking.tables["GSUB"]).table
        withoutBlocking.phrasePlan = nil
        let wrong = try coreTextFont(try withoutBlocking.write())
        #expect(laidOutGlyphs(wrong, "心里长了草") == sourceGlyphs(built.source, "心里長了草"))
        #expect(laidOutGlyphs(wrong, "里程碑") == sourceGlyphs(built.source, "里程碑"))
    }

    /// The counts the spike's independent Python derivation found for this
    /// font (s2t-phrases-findings.md): a change means the semantics changed.
    @Test func guanKiapRuleCountsMatchTheSpike() throws {
        let report = try GuanKiap.get(taiwanVariants: true).report
        #expect(report.phrases == 49_792)
        #expect(report.activeRules == 9_515)
        #expect(report.blockingRules == 39_215)
        #expect(report.shadowed.map(\.phrase) == ["幺么小丑"])
        #expect(report.gsubBytesBefore == 42_480)
        #expect(report.gsubBytesAfter < 600_000, "the spike's GSUB was 518 KB")
    }

    @Test func guanKiapGSUBKeepsItsLookupsAndVerticalForms() throws {
        let built = try GuanKiap.get(taiwanVariants: true)
        let source = try #require(built.source.tables["GSUB"])
        let output = try #require(table("GSUB", in: [UInt8](built.output)))
        try expectLookupsPreserved(source, output)
        #expect(try Font(data: built.output).verticalSubstitutions == built.source.verticalSubstitutions)
    }

    @Test func derivationIsDeterministic() throws {
        let built = try GuanKiap.get(taiwanVariants: false)
        var again = built.converted
        _ = try again.buildPhraseLookups()
        #expect(again.tables["GSUB"] == table("GSUB", in: [UInt8](built.output)))
    }

    // MARK: Preview

    struct TestCase: Decodable {
        let id: String
        let input: String
        let expected: [String: String]
    }

    static func openCCTestCases() throws -> [TestCase] {
        struct File: Decodable { let cases: [TestCase] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("OpenCCTestCases/testcases.json")
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true  // upstream uses trailing commas
        return try decoder.decode(File.self, from: Data(contentsOf: url)).cases
    }

    /// OpenCC's own test cases through the preview converter: it must give
    /// OpenCC's result wherever the font can show it, and agree with what
    /// CoreText lays out with the built font, or the preview would lie.
    @Test(arguments: [false, true]) func previewConverterMatchesOpenCCAndTheBuiltFont(taiwanVariants: Bool) throws {
        let config = taiwanVariants ? "s2tw" : "s2t"
        let built = try GuanKiap.get(taiwanVariants: taiwanVariants)
        let converter = try S2TTextConverter(
            font: built.source, options: S2TOptions(mode: .single, taiwanVariants: taiwanVariants, phrases: true))
        let font = try coreTextFont(built.output)
        let cmap = built.source.characterMap.mappings
        var failing: [String] = []
        var compared = 0
        let cases = try S2TPhrasesTests.openCCTestCases().filter { $0.expected[config] != nil }
        try #require(cases.count == (taiwanVariants ? 65 : 105))
        for testCase in cases {
            let expected = Array(testCase.expected[config]!.unicodeScalars)
            let input = Array(testCase.input.unicodeScalars)
            let converted = Array(converter.convert(testCase.input).unicodeScalars)
            try #require(converted.count == input.count && expected.count == input.count)
            // Positions the font cannot show either way are not the converter's to get right.
            let wrong = input.indices.contains { index in
                cmap[input[index].value] != nil && cmap[expected[index].value] != nil
                    && converted[index] != expected[index]
            }
            if wrong { failing.append(testCase.id) }
            if input.allSatisfy({ cmap[$0.value] != nil }) {
                compared += 1
                #expect(
                    laidOutGlyphs(font, testCase.input)
                        == sourceGlyphs(built.source, String(String.UnicodeScalarView(converted))),
                    "\(testCase.id)")
            }
        }
        // 𣗊溪 → 樠谿 included: the font has no 𣗊, but s2t adds it pointing at
        // 樠, so the phrase matches (it was the one failure while s2t only
        // converted code points the font already had).
        #expect(failing == [])
        #expect(compared > cases.count / 2)
    }

    @Test func previewConverterWithoutPhrasesIsTheCharacterConversion() throws {
        let ops = try OpsFixture()
        let converter = try S2TTextConverter(font: ops.font, options: S2TOptions(taiwanVariants: true))
        #expect(converter.convert("一回里后里们A") == "一回裡後裡们A", "们 stays: the font lacks 們")
        let phrases = try S2TTextConverter(font: ops.font, options: S2TOptions(taiwanVariants: true, phrases: true))
        #expect(phrases.convert("一回里后里们A") == "一回裡后里们A")
    }
}
