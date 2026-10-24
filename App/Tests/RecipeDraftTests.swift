import FontsMakerKit
import Foundation
import Testing

struct RecipeDraftTests {
    private let source = Recipe.Source(file: "ops.ttf", sha256: String(repeating: "a", count: 64))

    /// The suggested family is the source's English initials and a word per
    /// effect, never the source name, which the naming rules refuse and
    /// which is often reserved (product spec §4.3). The fallback, without
    /// initials, is there for a font whose own name they would collide with;
    /// a family with no Latin letters has only the fallback.
    @Test func suggestedNamesFromTheFamilyAndTheEffects() {
        let all = RecipeDraft.Effects(embolden: true, pseudoVertical: true, s2t: true)
        #expect(
            RecipeDraft.suggestedFamilyNames(sourceFamily: "GuanKiapTsingKhai", effects: all)
                == ["GKTK Ebook V TC", "FM Ebook V TC"])
        #expect(
            RecipeDraft.suggestedFamilyNames(sourceFamily: "GuanKiap Tsing Khai", effects: all).first
                == "GKTK Ebook V TC", "camel case and spaces split words alike")
        let bold = RecipeDraft.Effects(embolden: true)
        #expect(RecipeDraft.suggestedFamilyNames(sourceFamily: "LXGW WenKai TC", effects: bold).first == "LWKT Ebook")
        #expect(
            RecipeDraft.suggestedFamilyNames(
                sourceFamily: "Noto-Sans_TC", effects: RecipeDraft.Effects(pseudoVertical: true)
            ).first == "NST V")
        #expect(RecipeDraft.suggestedFamilyNames(sourceFamily: "Iansui", effects: .init()).first == "I Custom")
        #expect(RecipeDraft.suggestedFamilyNames(sourceFamily: "源樣黑體", effects: bold) == ["FM Ebook"])
        #expect(RecipeDraft.suggestedStyle(effects: bold, sourceWeight: 400, italic: false) == "Medium")
        #expect(
            RecipeDraft.suggestedStyle(effects: RecipeDraft.Effects(s2t: true), sourceWeight: 400, italic: false)
                == "Regular")

        var draft = RecipeDraft()
        draft.emboldenWeight = 3
        draft.pseudoVertical = PseudoVerticalOptions()
        #expect(draft.effects == RecipeDraft.Effects(embolden: true, pseudoVertical: true))
        draft.emboldenWeight = 20
        #expect(draft.effects.words == ["Ebook", "V"], "a weight change is not another effect")
    }

    /// The suggested style is the source's own weight (a variable font's
    /// instance included), one class heavier when emboldened, and keeps
    /// Italic: a Bold instance emboldened is not Medium, and an italic is
    /// never suggested an upright name. Every suggestion is a name the
    /// engine maps back to that weight class (`StyleName.weights`), and one
    /// the 樣式 menu offers.
    @Test func suggestedStyleFollowsTheSourceWeight() throws {
        let bold = RecipeDraft.Effects(embolden: true)
        let none = RecipeDraft.Effects()
        let cases: [(RecipeDraft.Effects, Int, Bool, String, UInt16)] = [
            (none, 700, false, "Bold", 700), (bold, 700, false, "ExtraBold", 800),
            (none, 400, true, "Italic", 400), (bold, 400, true, "Medium Italic", 500),
            (bold, 700, true, "ExtraBold Italic", 800), (bold, 900, false, "Black", 900),
            (bold, 100, false, "ExtraLight", 200), (none, 450, false, "Medium", 500), (none, 1000, false, "Black", 900),
        ]
        let font = try Font(contentsOf: TestFonts.fixture("ops.ttf"))
        for (effects, weight, italic, style, weightClass) in cases {
            let suggested = RecipeDraft.suggestedStyle(effects: effects, sourceWeight: weight, italic: italic)
            #expect(suggested == style, "\(weight) \(italic ? "italic " : "")\(effects.embolden ? "emboldened" : "")")
            #expect(RecipeDraft.styles(italic: italic).contains(suggested))
            var renamed = font
            let report = try renamed.rename(RenameOptions(familyName: "Style Test", styleName: suggested, provenance: ""))
            #expect(report.weightClass == weightClass, "\(suggested)")
            #expect(RecipeDraft.isItalic(renamed) == italic, "\(suggested)")
        }
    }

    /// Phrase rules reproduce OpenCC, which `skipAmbiguous` deliberately does
    /// not follow; the engine refuses the pair (`S2TError.phrasesNeedSingleMode`),
    /// so the draft must never hold it, or the build would fail on a control
    /// the form shows as valid.
    @Test func skipAmbiguousTurnsPhrasesOff() throws {
        var draft = RecipeDraft()
        draft.s2t = S2TOptions(mode: .single, taiwanVariants: true, phrases: true)
        draft.s2t?.mode = .skipAmbiguous
        #expect(draft.s2t == S2TOptions(mode: .skipAmbiguous, taiwanVariants: true, phrases: false))
        draft.s2t?.phrases = true
        #expect(draft.s2t?.phrases == false, "phrases cannot be turned on while one-to-many characters are skipped")
        draft.familyName = "Trad Kai"
        #expect(throws: Never.self) { try draft.recipe(source: source) }

        draft.s2t?.mode = .single
        #expect(draft.s2t?.phrases == false, "back to single, phrases stay off until turned on")
        draft.s2t?.phrases = true
        #expect(try draft.recipe(source: source).steps == [.s2t(S2TOptions(taiwanVariants: true, phrases: true))])
    }

    /// The recipe the app builds is the one the CLI reads back from the
    /// exported file: same canonical bytes, same identity hash (name ID 5),
    /// whatever order the review added characters in.
    @Test func recipeRoundTripsThroughTheCLIFormat() throws {
        var draft = RecipeDraft()
        draft.familyName = "Ebook Kai"
        draft.localizedFamilyName = "電子書楷"
        draft.styleName = "Medium"
        draft.emboldenWeight = 12
        draft.skip = ["漢", "一", "A"]
        draft.perCharacter = ["口": 6]
        draft.pseudoVertical = PseudoVerticalOptions()
        let recipe = try draft.recipe(source: source)

        let reread = try Recipe(json: recipe.canonicalJSON())
        #expect(reread == recipe)
        #expect(try reread.identityHash() == recipe.identityHash())
        guard case .embolden(let step) = recipe.steps.first else {
            Issue.record("embolden must come first")
            return
        }
        #expect(step.skip == ["A", "一", "漢"] && step.perCharacter == ["口": .init(weight: 6)])
        #expect(recipe.output.localizedFamilyName == ["zh-TW": "電子書楷"] && recipe.output.fileName == nil)
    }

    /// The saved draft (`Drafts/<sha256>.json`) brings back every control as
    /// it was, including what a recipe would drop: review decisions while the
    /// weight is 0, and names still empty.
    @Test func draftRoundTripsThroughItsFile() throws {
        var draft = RecipeDraft()
        draft.emboldenWeight = 12
        draft.skip = ["漢", "一", "A"]
        draft.perCharacter = ["口": 6, "鬢": 9]
        draft.s2t = S2TOptions(mode: .single, taiwanVariants: true, phrases: true)
        draft.pseudoVertical = PseudoVerticalOptions(punctuation: .verticalForms)
        draft.familyName = "Ebook Kai"
        draft.localizedFamilyName = "電子書楷"
        draft.styleName = "SemiBold"
        var weightless = draft
        weightless.emboldenWeight = 0
        weightless.s2t = S2TOptions(mode: .skipAmbiguous)
        weightless.familyName = ""
        for saved in [draft, weightless, RecipeDraft()] {
            #expect(try JSONDecoder().decode(RecipeDraft.self, from: JSONEncoder().encode(saved)) == saved)
        }

        // A file with phrases on skipAmbiguous holds what the form never
        // can; the engine's rule refuses it rather than restoring it.
        let refused = Data(
            #"{"emboldenWeight":0,"skip":[],"perCharacter":{},"familyName":"","localizedFamilyName":"","styleName":"Regular","s2t":{"op":"s2t","mode":"skipAmbiguous","taiwanVariants":false,"phrases":true}}"#
                .utf8)
        #expect(throws: RecipeError.self) { try JSONDecoder().decode(RecipeDraft.self, from: refused) }
    }

    /// Inline validation runs the engine's naming rules (product spec §4.3)
    /// against the source font: required, no source family name in any
    /// language, no in-file Reserved Font Name, PostScript-safe English.
    @Test func namesAreValidatedAgainstTheSource() throws {
        let font = try Font(data: Data(contentsOf: TestFonts.fixture("ops.ttf")))
        var draft = RecipeDraft()
        #expect(draft.nameProblem(source: source, font: font)?.contains("必須填寫") == true)
        draft.familyName = "FM Ops Bold"
        #expect(draft.nameProblem(source: source, font: font)?.contains("FM Ops") == true)
        draft.familyName = "Moonlit Kai"
        #expect(draft.nameProblem(source: source, font: font)?.contains("Moonlit") == true)
        draft.familyName = "電子書楷"
        #expect(draft.nameProblem(source: source, font: font)?.contains("PostScript") == true)
        draft.familyName = "Ebook Kai"
        draft.localizedFamilyName = "運算測試粗"
        #expect(draft.nameProblem(source: source, font: font)?.contains("運算測試") == true)
        draft.localizedFamilyName = "電子書楷"
        #expect(draft.nameProblem(source: source, font: font) == nil)
        // The recipe format's own rule, checked by decoding: no surrounding spaces.
        draft.familyName = "Ebook Kai "
        #expect(draft.nameProblem(source: source, font: font) != nil)
    }
}
