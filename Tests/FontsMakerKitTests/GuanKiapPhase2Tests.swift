import CoreText
import Foundation
import Testing

@testable import FontsMakerKit

/// Phase 2R acceptance on 原俠正楷 v1.20 (reference fonts from the shared
/// cache; missing files fail, they are never skipped).
struct GuanKiapPhase2Tests {
    private static let source = "GuanKiapTsingKhai.ttf"
    private let simplified = "汉字简化后，头发与发展都变了。为什么这样？"

    private func build(
        _ steps: String, output: String = #"{"familyName": "Example Kai", "localizedFamilyName": {"zh-TW": "範例楷"}}"#
    ) throws -> (Data, Data) {
        let bytes = try ReferenceFonts.bytes(GuanKiapPhase2Tests.source)
        let json = recipeJSON(
            sourceFile: GuanKiapPhase2Tests.source, sha256: sha256Hex(bytes), output: output, steps: steps)
        let result = try RecipeBuilder.build(try Recipe(json: json), sourceData: Data(bytes), options: BuildOptions())
        return (result.fontData, Data(bytes))
    }

    /// Product spec §6.3: a simplified sentence renders with traditional glyphs.
    /// The expectation is the traditional sentence laid out in the source font.
    @Test(arguments: [
        (#"{"op": "s2t", "mode": "single"}"#, "漢字簡化後，頭發與發展都變了。爲什麼這樣？"),
        (#"{"op": "s2t", "mode": "single", "taiwanVariants": true}"#, "漢字簡化後，頭發與發展都變了。為什麼這樣？"),
        (#"{"op": "s2t", "mode": "skipAmbiguous"}"#, "漢字簡化后，頭发與发展都變了。爲什麼這樣？"),
    ])
    func s2tLaysOutTheTraditionalGlyphs(step: String, traditional: String) throws {
        let (output, source) = try build("[\(step)]")
        let converted = laidOutGlyphs(try coreTextFont(output), simplified)
        let expected = laidOutGlyphs(try coreTextFont(source), traditional)
        #expect(converted.count == simplified.count)
        #expect(converted == expected)
        #expect(converted != laidOutGlyphs(try coreTextFont(source), simplified))
    }

    /// Design §5.4: OpenCC's first candidate for 裥 is 襉, which 原俠正楷 lacks;
    /// `single` shows 襇 instead, as 原俠 -T does.
    @Test func s2tSingleFallsBackLikeGuanKiapT() throws {
        let (output, source) = try build(#"[{"op": "s2t", "mode": "single"}]"#)
        let ours = try Font(data: output)
        let original = try Font(data: source)
        let reference = try Font(bytes: try ReferenceFonts.bytes("GuanKiapTsingKhai-T.ttf"))
        #expect(original.characterMap.mappings[0x8949] == nil, "襉 is missing from the source")
        let mine = try #require(ours.characterMap.mappings[0x88E5])
        #expect(mine == original.characterMap.mappings[0x8947], "裥 shows 襇")
        let theirs = try #require(reference.characterMap.mappings[0x88E5])
        #expect(
            try ours.flattenedOutline(of: Int(mine)).rounded() == reference.flattenedOutline(of: Int(theirs)).rounded())
    }

    /// Design §2: the source carries its name in six languages on two
    /// platforms; none of it may survive outside the copyright and license.
    @Test func renameLeavesNoOldNameAnywhere() throws {
        let (output, _) = try build("[]")
        let font = try Font(data: output)
        for record in font.names where ![0, 13, 14].contains(record.nameID) {
            let text = (record.string ?? "").lowercased()
            for old in ["原俠", "原侠", "guankiap", "tsingkhai"] {
                #expect(
                    !text.contains(old),
                    "name ID \(record.nameID) lang 0x\(String(record.languageID, radix: 16)): \(text)")
            }
        }
        // OFL keeps the copyright notice, which links the original project.
        let copyright = font.names.filter { $0.nameID == 0 }.compactMap(\.string)
        #expect(copyright.count == 2)
        #expect(
            copyright.allSatisfy {
                $0
                    == "Copyright 2022-2025 Tony Huang (https://github.com/tonyhuan/GuanKiapTsingKhai); Modified with FontsMaker"
            })
        #expect(Set(font.names.filter { $0.nameID == 1 }.compactMap(\.string)) == ["Example Kai", "範例楷"])
        let coreText = try coreTextFont(output)
        #expect(CTFontCopyPostScriptName(coreText) as String == "ExampleKai-Regular")
        #expect(CTFontCopyFamilyName(coreText) as String == "Example Kai")
    }

    /// 原俠 -90 turns full-width glyphs with x' = 880 − y, y' = x − 120: a
    /// quarter turn about (500, 380), and gives each the em-box height as its
    /// advance. Ours must give the same outlines and advances; 漢 has a vmtx
    /// advance of 1120 in the source, which must not leak into the column.
    /// The zero-width marks ゙ ゚ (U+3099, U+309A) and the tone marks
    /// U+302A–302D get the same turn but keep advance 0.
    @Test func turnedGlyphsEqualGuanKiap90() throws {
        let (output, source) = try build(#"[{"op": "pseudoVertical"}]"#)
        let ours = try Font(data: output)
        let original = try Font(data: source)
        let reference = try Font(bytes: try ReferenceFonts.bytes("GuanKiapTsingKhai-90.ttf"))
        let hanzi = "漢永的國鬱龘".unicodeScalars.map { ($0.value, UInt16(1000)) }
        let marks = [0x3099, 0x309A, 0x302A, 0x302B, 0x302C, 0x302D].map { (UInt32($0), UInt16(0)) }
        for (codePoint, advance) in hanzi + marks {
            let label = "U+\(hex(codePoint))"
            let mine = Int(ours.characterMap.mappings[codePoint]!)
            let theirs = Int(reference.characterMap.mappings[codePoint]!)
            let mineOutline = try ours.flattenedOutline(of: mine).rounded()
            let theirOutline = try reference.flattenedOutline(of: theirs).rounded()
            #expect(!mineOutline.points.isEmpty, "\(label)")
            #expect(
                mineOutline.points == theirOutline.points && mineOutline.endPoints == theirOutline.endPoints,
                "\(label)")
            #expect(ours.horizontalMetrics[mine].advanceWidth == advance, "\(label)")
            #expect(reference.horizontalMetrics[theirs].advanceWidth == advance, "\(label)")
        }
        for (codePoint, _) in marks {
            let glyph = Int(original.characterMap.mappings[codePoint]!)
            #expect(original.horizontalMetrics[glyph].advanceWidth == 0, "U+\(hex(codePoint)) is zero-width")
        }
        let han = Int(original.characterMap.mappings[0x6F22]!)
        #expect(original.verticalMetrics?[han].advanceHeight == 1120)
    }
}
