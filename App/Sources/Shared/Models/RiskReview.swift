import FontsMakerKit
import Foundation

/// A glyph under review (product spec §4.5).
struct ReviewItem: Identifiable, Equatable, Sendable {
    /// Glyph ID in the font the embolden step ran on.
    var id: Int
    /// Characters mapped to the glyph, as the report lists them; the recipe
    /// addresses the glyph through the first. Empty for unencoded glyphs
    /// (vertical alternates), which a recipe cannot single out.
    var characters: [String]
    var label: String
    /// Grade when it entered the review; the grid is filtered and ordered by it,
    /// so items do not jump around as decisions are rebuilt. Nil for a glyph
    /// that entered through a decision restored with the draft after a
    /// relaunch: it was skipped or given its own weight, so it was never
    /// graded at the step's weight, and a grade made up for it would file it
    /// among glyphs that were.
    var firstGrade: EmboldenGrade?
    var firstRatio: Double?
    /// Grade in the latest build; nil when it was not emboldened (skipped).
    var grade: EmboldenGrade?
    var weight: Double?
}

enum ReviewDecision: Equatable, Sendable {
    case accept
    case skip
    case weight(Double)
    /// 從另一套字型取代: the glyph of this library font instead.
    case borrow(RecipeDraft.BorrowedFont)
}

/// The review list across rebuilds: A and B glyphs of each build, plus every
/// glyph that has a decision, so a skipped glyph (absent from the next
/// report) stays visible and can be changed back.
struct RiskReview: Equatable, Sendable {
    static let reviewedGrades: Set<EmboldenGrade> = [.a, .b]
    private(set) var items: [ReviewItem] = []

    /// `characterMap` is the font's embolden ran on: the source's, or after a
    /// replace step, one whose Latin letters are new glyphs.
    mutating func update(with report: EmboldenReport, draft: RecipeDraft, characterMap: CharacterMap) {
        let latest = Dictionary(uniqueKeysWithValues: report.glyphs.map { ($0.glyphID, $0) })
        var kept: [ReviewItem] = []
        for var item in items {
            item.grade = latest[item.id]?.grade
            item.weight = latest[item.id]?.weight
            let stillRisky = item.grade.map(RiskReview.reviewedGrades.contains) ?? false
            if stillRisky || decision(for: item, in: draft) != .accept { kept.append(item) }
        }
        let present = Set(kept.map(\.id))
        for glyph in report.glyphs
        where RiskReview.reviewedGrades.contains(glyph.grade) && !present.contains(glyph.glyphID) {
            // The code point too: the system UI font lacks many rare ideographs.
            let label =
                glyph.codePoints.first.map { "\(glyph.text) U+\(String(format: "%04X", $0))" }
                ?? "#\(glyph.glyphID)（無字碼）"
            kept.append(
                ReviewItem(
                    id: glyph.glyphID,
                    characters: glyph.codePoints.compactMap(Unicode.Scalar.init).map { String($0) },
                    label: label, firstGrade: glyph.grade, firstRatio: glyph.minHoleRatio, grade: glyph.grade,
                    weight: glyph.weight))
        }
        // Decisions the list does not show yet: those restored with the draft
        // after a relaunch, when the list starts empty. A skipped glyph is not
        // in the report and a lighter one may now grade C or D, so neither
        // came in above, and the decision could not be changed back.
        let listed = Set(kept.map(\.id))
        let decided = Set(
            draft.skip.union(draft.perCharacter.keys).union(draft.borrowed.keys).compactMap { character in
                character.unicodeScalars.first.flatMap { characterMap.mappings[$0.value] }.map(Int.init)
            }
        ).subtracting(listed)
        // Every character of the glyph, ascending, as the report lists them.
        var codePoints: [Int: [UInt32]] = [:]
        for (codePoint, glyphID) in characterMap.mappings where decided.contains(Int(glyphID)) {
            codePoints[Int(glyphID), default: []].append(codePoint)
        }
        for (glyphID, points) in codePoints {
            let points = points.sorted()
            let characters = points.compactMap(Unicode.Scalar.init).map { String($0) }
            kept.append(
                ReviewItem(
                    id: glyphID, characters: characters,
                    label: "\(characters.joined()) U+\(String(format: "%04X", points[0]))", firstGrade: nil,
                    firstRatio: nil, grade: latest[glyphID]?.grade, weight: latest[glyphID]?.weight))
        }
        // Worst first, as on the CLI's risk sheets; restored decisions last.
        func order(_ item: ReviewItem) -> (Int, EmboldenGrade, Double, Int) {
            (item.firstGrade == nil ? 1 : 0, item.firstGrade ?? .a, item.firstRatio ?? .infinity, item.id)
        }
        items = kept.sorted { order($0) < order($1) }
    }

    func decision(for item: ReviewItem, in draft: RecipeDraft) -> ReviewDecision {
        for character in item.characters {
            if draft.skip.contains(character) { return .skip }
            if let weight = draft.perCharacter[character] { return .weight(weight) }
            if let font = draft.borrowed[character] { return .borrow(font) }
        }
        return .accept
    }

    /// Writes the decision for the item's glyph into the draft's `skip` /
    /// `perCharacter` / `borrowed`. Embolden settings name only the first
    /// character: the others share the glyph and follow it (design §6), and
    /// naming one keeps the recipe free of conflicting entries. A borrowed
    /// glyph names every character: replace works by character, and one left
    /// out would keep showing the crowded glyph.
    func apply(_ decision: ReviewDecision, to item: ReviewItem, in draft: inout RecipeDraft) {
        guard let first = item.characters.first else { return }
        for character in item.characters {
            draft.skip.remove(character)
            draft.perCharacter[character] = nil
            draft.borrowed[character] = nil
        }
        switch decision {
        case .accept: break
        case .skip: draft.skip.insert(first)
        case .weight(let weight): draft.perCharacter[first] = weight
        case .borrow(let font): for character in item.characters { draft.borrowed[character] = font }
        }
    }

    /// Only CJK glyphs can be borrowed: the second font's glyph comes in at
    /// its own size, which fits a full-width ideograph, not a letter with
    /// its own side bearings (those have the glyph editor). This also keeps
    /// them clear of 英文字母換成另一套字型's characters.
    static func canBorrow(_ item: ReviewItem) -> Bool {
        !item.characters.isEmpty
            && item.characters.allSatisfy { $0.unicodeScalars.first.map { EditorModel.isCJK($0.value) } ?? false }
    }

    /// Smaller weights offered for a glyph: three quarters, half and a quarter
    /// of the step's weight, whole units.
    static func smallerWeights(than weight: Double) -> [Double] {
        var result: [Double] = []
        for fraction in [0.75, 0.5, 0.25] {
            let value = (weight * fraction).rounded()
            if value >= 1, value < weight, !result.contains(value) { result.append(value) }
        }
        return result
    }
}
