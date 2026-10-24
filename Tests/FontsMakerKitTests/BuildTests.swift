import Foundation
import Testing

@testable import FontsMakerKit

/// The recipe pipeline (technical design §6–§8): license gate, source pinning,
/// step order, rename, write policy and determinism.
struct BuildTests {
    private let output = #"{"familyName": "Example Kai", "localizedFamilyName": {"zh-TW": "範例楷"}}"#
    private let s2tAndVertical = #"[{"op": "s2t", "taiwanVariants": true}, {"op": "pseudoVertical"}]"#
    private let emboldenWithOverrides =
        #"[{"op": "embolden", "weight": 12, "skip": ["漢"], "perCharacter": {"一": {"weight": 6}}}]"#

    private func build(
        _ fixture: String, output: String? = nil, steps: String = "[]", sha256: String? = nil,
        options: BuildOptions = BuildOptions(), progress: RecipeBuilder.Progress? = nil
    ) throws -> BuildResult {
        let bytes = try Fixtures.bytes(fixture)
        let json = recipeJSON(
            sourceFile: fixture, sha256: sha256 ?? sha256Hex(bytes), output: output ?? self.output, steps: steps)
        return try RecipeBuilder.build(
            try Recipe(json: json), sourceData: Data(bytes), options: options, progress: progress)
    }

    private func bounds(_ glyph: Glyph) throws -> [Int32] {
        let box = try #require(BoundingBox(points(glyph)))
        return [box.xMin, box.yMin, box.xMax, box.yMax]
    }

    @Test func licenseGate() throws {
        #expect(try build("ops.ttf").license == .openFontLicense)
        // Restricted embedding wins over OFL wording and over the user's confirmation.
        #expect(throws: BuildError.licenseRestricted) {
            try build("restricted.ttf", options: BuildOptions(iHaveRights: true))
        }
        // minimal.ttf names no license at all.
        #expect(throws: BuildError.licenseNotConfirmed) { try build("minimal.ttf") }
        #expect(try build("minimal.ttf", options: BuildOptions(iHaveRights: true)).license == .unknown)
    }

    @Test func sourceHashMismatchIsRefused() throws {
        let wrong = String(repeating: "0", count: 64)
        let error = #expect(throws: BuildError.self) { try build("ops.ttf", sha256: wrong) }
        guard case .sourceHashMismatch(let file, let expected, let actual) = error else {
            Issue.record("expected a hash mismatch, got \(String(describing: error))")
            return
        }
        let fixtureHash = try OpsFixture.sha256
        #expect(file == "ops.ttf" && expected == wrong && actual == fixtureHash)
    }

    @Test func recipeFileWithRelativeSourceBuildsEndToEnd() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("fonts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("recipes"), withIntermediateDirectories: true)
        try Data(try OpsFixture.bytes).write(to: root.appendingPathComponent("fonts/source.ttf"))
        let recipeURL = root.appendingPathComponent("recipes/kai.json")
        try recipeJSON(
            sourceFile: "../fonts/source.ttf", sha256: try OpsFixture.sha256, output: output, steps: s2tAndVertical
        )
        .write(to: recipeURL)

        let result = try RecipeBuilder.build(recipeAt: recipeURL, options: BuildOptions())
        #expect(result.fileName == "ExampleKai-Regular.ttf")
        #expect(result.reports.map(\.kind) == ["decompose", "s2t", "pseudoVertical", "rename"])

        let font = try Font(data: result.fontData)
        let version = font.names.first { $0.nameID == 5 }?.string
        #expect(
            version == "Version 1.500; FontsMaker \(FontsMakerEngine.version); recipe \(result.recipeHash.prefix(8))")
        let fileHash = try Recipe(contentsOf: recipeURL).identityHash()
        #expect(result.recipeHash == fileHash)
        #expect(!font.glyphs.contains { $0.isComposite }, "outline step: composites flattened")

        let missing = root.appendingPathComponent("recipes/missing.json")
        try recipeJSON(sourceFile: "nowhere.ttf", sha256: try OpsFixture.sha256, output: output).write(to: missing)
        #expect(throws: BuildError.self) { try RecipeBuilder.build(recipeAt: missing, options: BuildOptions()) }
    }

    /// Technical design §8: same source + same recipe + same engine → same bytes,
    /// however the recipe file is formatted. Embolden runs in parallel, so this
    /// also covers independence from thread scheduling.
    @Test func sameRecipeGivesIdenticalBytes() throws {
        let allSteps =
            #"[{"op": "embolden", "weight": 12}, {"op": "s2t", "taiwanVariants": true}, {"op": "pseudoVertical"}]"#
        let first = try build("ops.ttf", steps: allSteps)
        let second = try build("ops.ttf", steps: allSteps)
        #expect(first.fontData == second.fontData)
        let reformatted = try build(
            "ops.ttf",
            output:
                #"{ "localizedFamilyName" : { "zh-TW" : "範例楷" }, "familyName" : "Example Kai", "styleName": "Regular" }"#,
            steps:
                #"[ { "weight": 12.0, "op": "embolden", "skip": [] }, { "op" : "s2t", "mode": "single", "taiwanVariants" : true }, { "punctuation": "centered", "op" : "pseudoVertical" } ]"#
        )
        #expect(reformatted.fontData == first.fontData)
        #expect(reformatted.recipeHash == first.recipeHash)
    }

    /// The recipe's characters become glyph IDs before the engine runs: a
    /// skipped character keeps its outline, a per-character weight applies to
    /// its glyph, shared or not, exactly once, and everything else gets the
    /// step's weight (design §4.2, §5.1, §6).
    @Test func emboldenRunsWithTheResolvedSelection() throws {
        let ops = try OpsFixture()
        let result = try build("ops.ttf", steps: emboldenWithOverrides)
        #expect(result.reports.map(\.kind) == ["decompose", "embolden", "rename"])
        guard case .embolden(let step, let report) = result.reports[1] else {
            Issue.record("expected the embolden report second, got \(result.reports)")
            return
        }
        #expect(step.weight == 12)

        let font = try Font(data: result.fontData)
        let han = Int(ops.glyph("uni6F22"))
        let one = Int(ops.glyph("uni4E00"))
        let mouth = Int(ops.glyph("uni53E3"))
        #expect(font.glyphs[han] == ops.font.glyphs[han], "skip keeps the outline")
        // 一 is shared with ⼀: rect(60, 330, 940, 430) grows by 3 per side, once.
        #expect(try bounds(font.glyphs[one]) == [57, 327, 943, 433])
        // 口 at the step's weight: rect(150, 50, 850, 750) grows by 6 per side.
        #expect(try bounds(font.glyphs[mouth]) == [144, 44, 856, 756])
        #expect(font.horizontalMetrics.map(\.advanceWidth) == ops.font.horizontalMetrics.map(\.advanceWidth))

        #expect(!report.glyphs.contains { $0.glyphID == han })
        #expect(report.glyphs.first { $0.glyphID == one }?.weight == 6)
        #expect(report.glyphs.first { $0.glyphID == mouth }?.weight == 12)
        #expect(result.reports[1].summary.contains("\(report.glyphs.count) glyphs emboldened"))

        // The risk review compares the glyphs just before and after embolden.
        let snapshots = try #require(result.emboldenSnapshots)
        #expect(snapshots.before.glyphs[one] == ops.font.glyphs[one])
        #expect(snapshots.after.glyphs == font.glyphs)
    }

    /// Later steps must not leak into the risk review's "after": pseudoVertical
    /// turns 一 in place, the snapshot keeps it upright.
    @Test func emboldenSnapshotsPrecedeLaterSteps() throws {
        let ops = try OpsFixture()
        let one = Int(ops.glyph("uni4E00"))
        let result = try build("ops.ttf", steps: #"[{"op": "embolden", "weight": 12}, {"op": "pseudoVertical"}]"#)
        let snapshots = try #require(result.emboldenSnapshots)
        #expect(try bounds(snapshots.after.glyphs[one]) == [54, 324, 946, 436])
        #expect(try bounds(Font(data: result.fontData).glyphs[one]) != [54, 324, 946, 436])
        #expect(try build("ops.ttf", steps: s2tAndVertical).emboldenSnapshots == nil)
    }

    /// The app shows build progress and can cancel (product spec §4.7); the
    /// build forwards the embolden step's progress.
    @Test func buildReportsEmboldenProgressAndCanBeCancelled() throws {
        let log = ProgressLog()
        let result = try build("ops.ttf", steps: emboldenWithOverrides) { completed, total in
            log.record(completed, total)
            return true
        }
        guard case .embolden(_, let report) = result.reports[1] else {
            Issue.record("expected an embolden report")
            return
        }
        #expect(log.calls.last.map { [$0.0, $0.1] } == [report.glyphs.count, report.glyphs.count])

        #expect(throws: CancellationError.self) {
            try build("ops.ttf", steps: emboldenWithOverrides) { _, _ in false }
        }
    }

    /// Characters resolve before the engine runs: a conflict or an unknown
    /// character is reported without emboldening anything.
    @Test func emboldenSettingsThatCannotResolveAreRefused() throws {
        let conflict = #expect(throws: BuildError.self) {
            try build(
                "ops.ttf",
                steps: #"[{"op": "embolden", "weight": 12, "skip": ["一"], "perCharacter": {"⼀": {"weight": 6}}}]"#)
        }
        if case .conflictingCharacterSettings = conflict {
        } else {
            Issue.record("expected a conflict, got \(String(describing: conflict))")
        }
        #expect(throws: BuildError.charactersNotInFont(["skip '們' (U+5011)"])) {
            try build("ops.ttf", steps: #"[{"op": "embolden", "weight": 12, "skip": ["們"]}]"#)
        }
    }

    /// Naming rules depend only on the source, so they fail before any step runs.
    @Test func badNameFailsBeforeTheSteps() throws {
        #expect(
            throws: RenameError.containsSourceFamilyName(
                field: "familyName", value: "FM Ops Bold", sourceName: "FM Ops")
        ) {
            try build(
                "ops.ttf", output: #"{"familyName": "FM Ops Bold"}"#, steps: #"[{"op": "embolden", "weight": 12}]"#)
        }
    }

    /// Hinting survives a cmap-only recipe and is stripped once outlines change (design D5).
    @Test func writePolicyFollowsOutlineOperations() throws {
        let cmapOnly = try Font(data: try build("synthetic.ttf", steps: #"[{"op": "s2t"}]"#).fontData)
        #expect(cmapOnly.tables["fpgm"] != nil && cmapOnly.tables["prep"] != nil)
        #expect(cmapOnly.glyphs.contains { $0.isComposite })

        let turned = try Font(data: try build("synthetic.ttf", steps: #"[{"op": "pseudoVertical"}]"#).fontData)
        #expect(turned.tables["fpgm"] == nil && turned.tables["prep"] == nil && turned.tables["cvt "] == nil)
        #expect(turned.glyphs.allSatisfy { $0.instructions.isEmpty && !$0.isComposite })
    }
}

extension StepReport {
    var kind: String {
        switch self {
        case .outlines: return "outlines"
        case .decompose: return "decompose"
        case .embolden: return "embolden"
        case .tracking: return "tracking"
        case .lineHeight: return "lineHeight"
        case .s2t: return "s2t"
        case .pseudoVertical: return "pseudoVertical"
        case .replace: return "replace"
        case .rename: return "rename"
        }
    }
}
