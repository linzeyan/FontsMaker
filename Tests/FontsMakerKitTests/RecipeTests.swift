import Foundation
import Testing

@testable import FontsMakerKit

/// Recipe format v1 (technical design §6).
struct RecipeTests {
    private let sha = String(repeating: "ab", count: 32)

    private func decode(_ json: String) throws -> Recipe {
        try Recipe(json: Data(json.utf8))
    }

    private func recipe(output: String = #"{"familyName": "Example Kai"}"#, steps: String = "[]") -> String {
        #"{"formatVersion": 1, "source": {"file": "a.ttf", "sha256": "\#(sha)"}, "output": \#(output), "steps": \#(steps)}"#
    }

    @Test func decodesTheDesignExample() throws {
        let decoded = try decode(
            """
            {
              "formatVersion": 1,
              "source": {
                "file": "GuanKiapTsingKhai.ttf",
                "sha256": "758632243c499e431fd0c847f5e8c431acf59a9b41a26237a819466139994d38"
              },
              "output": {
                "familyName": "Example Kai",
                "localizedFamilyName": { "zh-TW": "範例楷" },
                "styleName": "Medium",
                "weightClass": 500,
                "fileName": "ExampleKai-Medium.ttf"
              },
              "steps": [
                { "op": "embolden", "weight": 12, "skip": ["繁"], "perCharacter": { "鬢": { "weight": 6 } } },
                { "op": "s2t", "mode": "single", "taiwanVariants": false },
                { "op": "pseudoVertical", "punctuation": "centered" }
              ]
            }
            """)
        #expect(decoded.source.file == "GuanKiapTsingKhai.ttf")
        #expect(decoded.output.localizedFamilyName == ["zh-TW": "範例楷"])
        #expect(decoded.output.weightClass == 500)
        #expect(
            decoded.steps == [
                .embolden(EmboldenStep(weight: 12, skip: ["繁"], perCharacter: ["鬢": .init(weight: 6)])),
                .s2t(S2TOptions(mode: .single, taiwanVariants: false)),
                .pseudoVertical(PseudoVerticalOptions(punctuation: .centered)),
            ])
    }

    /// A misspelled parameter must never be ignored: the error names where it is.
    @Test(arguments: [
        (
            #"{"formatVersion": 1, "notes": "x", "source": {"file": "a.ttf", "sha256": "SHA"}, "output": {"familyName": "A"}}"#,
            "notes"
        ),
        (
            #"{"formatVersion": 1, "source": {"file": "a.ttf", "sha265": "SHA"}, "output": {"familyName": "A"}}"#,
            "source.sha265"
        ),
        (
            #"{"formatVersion": 1, "source": {"file": "a.ttf", "sha256": "SHA"}, "output": {"familyname": "A"}}"#,
            "output.familyname"
        ),
        (
            #"{"formatVersion": 1, "source": {"file": "a.ttf", "sha256": "SHA"}, "output": {"familyName": "A"}, "steps": [{"op": "pseudoVertical"}, {"op": "s2t", "taiwanVariant": true}]}"#,
            "steps[1].taiwanVariant"
        ),
        (
            #"{"formatVersion": 1, "source": {"file": "a.ttf", "sha256": "SHA"}, "output": {"familyName": "A"}, "steps": [{"op": "s2t", "phrase": true}]}"#,
            "steps[0].phrase"
        ),
        (
            #"{"formatVersion": 1, "source": {"file": "a.ttf", "sha256": "SHA"}, "output": {"familyName": "A"}, "steps": [{"op": "embolden", "wieght": 12}]}"#,
            "steps[0].wieght"
        ),
        (
            #"{"formatVersion": 1, "source": {"file": "a.ttf", "sha256": "SHA"}, "output": {"familyName": "A"}, "steps": [{"op": "embolden", "weight": 12, "perCharacter": {"鬢": {"wieght": 6}}}]}"#,
            "steps[0].perCharacter.鬢.wieght"
        ),
        (
            #"{"formatVersion": 1, "source": {"file": "a.ttf", "sha256": "SHA"}, "output": {"familyName": "A"}, "steps": [{"op": "pseudoVertical", "punctuations": "centered"}]}"#,
            "steps[0].punctuations"
        ),
    ])
    func unknownKeyIsAnErrorNamingItsPath(json: String, path: String) {
        let error = #expect(throws: RecipeError.self) {
            try decode(json.replacingOccurrences(of: "SHA", with: sha))
        }
        #expect(error == .unknownKey(path: path))
        #expect(error?.description.contains("'\(path)'") == true)
    }

    @Test func missingAndInvalidValuesNameTheirPath() throws {
        func error(_ json: String) -> RecipeError? {
            #expect(throws: RecipeError.self) { try decode(json) }
        }
        #expect(error(recipe(output: "{}")) == .missingKey(path: "output.familyName"))
        #expect(
            error(recipe(steps: #"[{"op": "s2t", "mode": "singel"}]"#))
                == .invalidValue(path: "steps[0].mode", reason: "'singel' is not one of 'single', 'skipAmbiguous'"))
        if case .invalidValue(let path, _) = error(recipe(steps: #"[{"op": "embolden", "weight": -1}]"#)) {
            #expect(path == "steps[0].weight")
        } else {
            Issue.record("negative weight must be rejected")
        }
        if case .invalidValue(let path, _) = error(
            recipe(steps: #"[{"op": "embolden", "weight": 12, "skip": ["繁", "ab"]}]"#))
        {
            #expect(path == "steps[0].skip[1]")
        } else {
            Issue.record("a multi-character skip entry must be rejected")
        }
        if case .invalidValue(let path, _) = error(recipe(steps: #"[{"op": "embolden", "weight": "12"}]"#)) {
            #expect(path == "steps[0].weight")
        } else {
            Issue.record("a string weight must be rejected")
        }
        if case .invalidValue(let path, _) = error(recipe(steps: #"[{"op": "rotate"}]"#)) {
            #expect(path == "steps[0].op")
        } else {
            Issue.record("an unknown op must be rejected")
        }
        if case .invalidValue(let path, _) = error(recipe(steps: #"[{"op": "s2t"}, {"op": "s2t"}]"#)) {
            #expect(path == "steps[1].op")
        } else {
            Issue.record("a repeated op must be rejected")
        }
        for (output, path) in [
            (#"{"familyName": "A", "weightClass": 1200}"#, "output.weightClass"),
            (#"{"familyName": "A", "fileName": "../escape.ttf"}"#, "output.fileName"),
            (#"{"familyName": "A", "fileName": "Font.otf"}"#, "output.fileName"),
            (#"{"familyName": " A"}"#, "output.familyName"),
            (#"{"familyName": "A", "localizedFamilyName": {"ja": "エー"}}"#, "output.localizedFamilyName.ja"),
        ] {
            if case .invalidValue(let actual, _) = error(recipe(output: output)) {
                #expect(actual == path)
            } else {
                Issue.record("\(output) must be rejected at \(path)")
            }
        }
        let shortHash =
            #"{"formatVersion": 1, "source": {"file": "a.ttf", "sha256": "abc"}, "output": {"familyName": "A"}}"#
        if case .invalidValue(let path, _) = error(shortHash) {
            #expect(path == "source.sha256")
        } else {
            Issue.record("a short sha256 must be rejected")
        }
        #expect(
            error(recipe().replacingOccurrences(of: #""formatVersion": 1"#, with: #""formatVersion": 2"#))
                == .unsupportedFormatVersion(2))
        if case .notJSON = error("{\"formatVersion\": 1,") {} else { Issue.record("truncated JSON must be reported") }
    }

    /// Name ID 5 carries the hash; formatting must not change output bytes.
    @Test func canonicalHashIgnoresFormattingDefaultsAndListOrder() throws {
        let compact = try decode(
            #"{"formatVersion":1,"source":{"file":"a.ttf","sha256":"\#(sha)"},"output":{"familyName":"Example Kai"},"steps":[{"op":"s2t"},{"op":"embolden","weight":12,"skip":["繁","傳"]}]}"#
        )
        let spelledOut = try decode(
            """
            {
                "steps": [
                    { "taiwanVariants": false, "mode": "single", "op": "s2t" },
                    { "op": "embolden", "skip": ["傳", "繁", "傳"], "weight": 12.0, "perCharacter": {} }
                ],
                "output": { "styleName": "Regular", "familyName": "Example Kai", "localizedFamilyName": {} },
                "source": { "sha256": "\(sha.uppercased())", "file": "a.ttf" },
                "formatVersion": 1
            }
            """)
        #expect(compact == spelledOut)
        #expect(try compact.canonicalJSON() == spelledOut.canonicalJSON())
        #expect(try compact.identityHash() == spelledOut.identityHash())

        var moved = compact
        moved.source.file = "../elsewhere/a.ttf"
        #expect(try moved.identityHash() == compact.identityHash(), "where the font sits does not identify it")

        var changed = compact
        changed.output.styleName = "Medium"
        #expect(try changed.identityHash() != compact.identityHash())
        var reordered = compact
        reordered.steps.reverse()
        #expect(try reordered.identityHash() != compact.identityHash(), "step order is meaningful")

        // The canonical form is itself a valid recipe that decodes to the same value.
        #expect(try Recipe(json: compact.canonicalJSON()) == compact)
        let canonical = String(decoding: try compact.canonicalJSON(), as: UTF8.self)
        #expect(!canonical.contains("\n") && !canonical.contains("\": ") && !canonical.contains(", \""))
        #expect(canonical.hasPrefix(#"{"formatVersion":1,"output":{"#), "keys sorted, no whitespace")
    }

    /// `phrases` is opt-in and written only when on, so recipes from before
    /// it existed keep their canonical bytes, their hash (name ID 5) and with
    /// it the bytes of every font built from them.
    @Test func s2tPhrasesIsOptInAndLeavesOldRecipesUnchanged() throws {
        let old = try decode(recipe(steps: #"[{"op": "s2t", "mode": "single", "taiwanVariants": true}]"#))
        let explicitOff = try decode(recipe(steps: #"[{"op": "s2t", "taiwanVariants": true, "phrases": false}]"#))
        #expect(old == explicitOff)
        #expect(try old.canonicalJSON() == explicitOff.canonicalJSON())
        let canonical = String(decoding: try old.canonicalJSON(), as: UTF8.self)
        #expect(canonical.hasSuffix(#""steps":[{"mode":"single","op":"s2t","taiwanVariants":true}]}"#))

        let on = try decode(recipe(steps: #"[{"op": "s2t", "taiwanVariants": true, "phrases": true}]"#))
        #expect(on.steps == [.s2t(S2TOptions(mode: .single, taiwanVariants: true, phrases: true))])
        #expect(
            String(decoding: try on.canonicalJSON(), as: UTF8.self).hasSuffix(
                #""steps":[{"mode":"single","op":"s2t","phrases":true,"taiwanVariants":true}]}"#))
        #expect(try on.identityHash() != old.identityHash())
        #expect(try Recipe(json: on.canonicalJSON()) == on)

        // The rules reproduce OpenCC, which skipAmbiguous deliberately does not.
        let error = #expect(throws: RecipeError.self) {
            try decode(recipe(steps: #"[{"op": "s2t", "mode": "skipAmbiguous", "phrases": true}]"#))
        }
        if case .invalidValue(let path, let reason) = error {
            #expect(path == "steps[0].phrases")
            #expect(reason.contains("mode 'single'"))
        } else {
            Issue.record("phrases with skipAmbiguous must be rejected")
        }
    }

    /// A collection member or variable instance is part of what the output
    /// is made from, so it is in the hash; leaving the keys out (the first
    /// member, the default instance) keeps old recipes' bytes and hash.
    @Test func sourceFaceAndVariationAreOptional() throws {
        func source(_ extra: String) -> String {
            #"{"formatVersion": 1, "source": {"file": "a.ttc", "sha256": "\#(sha)"\#(extra)}, "output": {"familyName": "A"}}"#
        }
        let plain = try decode(source(""))
        #expect(plain.source.faceIndex == 0 && plain.source.variation.isEmpty)
        #expect(try plain == decode(source(#", "faceIndex": 0, "variation": {}"#)))
        #expect(!String(decoding: try plain.canonicalJSON(), as: UTF8.self).contains("faceIndex"))
        #expect(!String(decoding: try plain.canonicalJSON(), as: UTF8.self).contains("variation"))

        let picked = try decode(source(#", "faceIndex": 2, "variation": {"wght": 650, "opsz": 12.5}"#))
        #expect(picked.source.faceIndex == 2 && picked.source.variation == ["wght": 650, "opsz": 12.5])
        #expect(
            String(decoding: try picked.canonicalJSON(), as: UTF8.self).contains(
                #""source":{"faceIndex":2,"file":"a.ttc","sha256":"\#(sha)","variation":{"opsz":12.5,"wght":650}}"#))
        #expect(try Recipe(json: picked.canonicalJSON()) == picked)
        #expect(try picked.identityHash() != plain.identityHash())

        func error(_ extra: String) -> RecipeError? {
            #expect(throws: RecipeError.self) { try decode(source(extra)) }
        }
        #expect(
            error(#", "faceIndex": -1"#) == .invalidValue(path: "source.faceIndex", reason: "must be 0 or more, got -1")
        )
        if case .invalidValue(let path, let reason) = error(#", "variation": {"weight": 700}"#) {
            #expect(path == "source.variation.weight" && reason.contains("4 ASCII characters"))
        } else {
            Issue.record("a variation key that is not an axis tag must be rejected")
        }
        #expect(error(#", "face": 1"#) == .unknownKey(path: "source.face"), "unknown keys stay errors")
    }

    @Test func sourcePathIsRelativeToTheRecipeFile() throws {
        let recipeURL = URL(fileURLWithPath: "/tmp/project/recipes/kai.json")
        var decoded = try decode(recipe())
        decoded.source.file = "../fonts/Source.ttf"
        #expect(decoded.sourceURL(recipeURL: recipeURL).path == "/tmp/project/fonts/Source.ttf")
        decoded.source.file = "/Library/Fonts/Source.ttf"
        #expect(decoded.sourceURL(recipeURL: recipeURL).path == "/Library/Fonts/Source.ttf")
    }

    // MARK: - Characters → glyph IDs

    @Test func emboldenCharactersResolveToGlyphIDs() throws {
        let ops = try OpsFixture()
        let step = EmboldenStep(weight: 12, skip: ["漢"], perCharacter: ["一": .init(weight: 6), "回": .init(weight: 8)])
        let selection = try step.resolve(in: ops.font)
        #expect(selection.weight == 12)
        #expect(selection.miterLimit == 4, "design §5.1; recipes have no miter limit")
        #expect(selection.skip == [Int(ops.glyph("uni6F22"))])
        #expect(selection.perGlyphWeight == [Int(ops.glyph("uni4E00")): 6, Int(ops.glyph("uni56DE")): 8])
    }

    /// 一 (U+4E00) and ⼀ (U+2F00) share one glyph, which is emboldened once.
    @Test func sharedGlyphNeedsAgreeingSettings() throws {
        let ops = try OpsFixture()
        let shared = Int(ops.glyph("uni4E00"))

        let skipVersusWeight = EmboldenStep(weight: 12, skip: ["一"], perCharacter: ["⼀": .init(weight: 6)])
        let error = #expect(throws: BuildError.self) { try skipVersusWeight.resolve(in: ops.font) }
        guard case .conflictingCharacterSettings(let conflicts) = error else {
            Issue.record("expected a conflict, got \(String(describing: error))")
            return
        }
        #expect(conflicts == ["glyph \(shared) is shared by ⼀ (U+2F00): weight 6, 一 (U+4E00): skip"])

        let twoWeights = EmboldenStep(weight: 12, perCharacter: ["一": .init(weight: 6), "⼀": .init(weight: 8)])
        #expect(throws: BuildError.self) { try twoWeights.resolve(in: ops.font) }

        let agreeing = EmboldenStep(weight: 12, perCharacter: ["一": .init(weight: 6), "⼀": .init(weight: 6)])
        #expect(try agreeing.resolve(in: ops.font).perGlyphWeight == [shared: 6])

        // Naming one of the characters is enough; the other follows its glyph.
        #expect(try EmboldenStep(weight: 12, skip: ["⼀"]).resolve(in: ops.font).skip == [shared])
    }

    @Test func characterMissingFromTheFontIsAnError() throws {
        let ops = try OpsFixture()
        let step = EmboldenStep(weight: 12, skip: ["們"], perCharacter: ["繁": .init(weight: 6)])
        let error = #expect(throws: BuildError.self) { try step.resolve(in: ops.font) }
        #expect(error == .charactersNotInFont(["skip '們' (U+5011)", "perCharacter '繁' (U+7E41)"]))
    }
}
