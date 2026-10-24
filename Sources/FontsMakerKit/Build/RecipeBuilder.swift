import Foundation

/// The engine version written into every output (name ID 5). Bump it whenever
/// the same recipe and source could produce different bytes.
public enum FontsMakerEngine {
    public static let version = "0.1.0"
}

public struct BuildOptions: Equatable, Sendable {
    /// The user confirmed they may modify and redistribute a font whose license
    /// FontsMaker does not recognize (design §7; CLI `--i-have-rights`).
    public var iHaveRights: Bool

    public init(iHaveRights: Bool = false) {
        self.iHaveRights = iHaveRights
    }
}

public struct BuildResult: Sendable {
    public var fontData: Data
    /// `output.fileName`, or `<PostScriptName>.ttf`.
    public var fileName: String
    /// sha256 of the canonical recipe; its first 8 digits are in name ID 5.
    public var recipeHash: String
    public var license: LicenseStatus
    /// One entry per pipeline stage that did something, in order.
    public var reports: [StepReport]
    /// The font right before and right after the embolden step, for risk
    /// review (`EmboldenReport.riskSheet`). Later steps may turn or remap
    /// glyphs, so the output font cannot stand in for "after". nil without
    /// an embolden step.
    public var emboldenSnapshots: (before: Font, after: Font)?
}

public enum StepReport: Equatable, Sendable {
    case outlines(OutlinesStep, OutlinesReport)
    case decompose(composites: Int)
    case embolden(EmboldenStep, EmboldenReport)
    case tracking(TrackingOptions, TrackingReport)
    case lineHeight(LineHeightOptions, LineHeightReport)
    case s2t(S2TOptions, S2TReport)
    case pseudoVertical(PseudoVerticalOptions, PseudoVerticalReport)
    case replace(ReplaceStep, ReplaceReport)
    case rename(RenameReport)

    /// One line for the CLI summary; two for s2t with phrases.
    public var summary: String {
        switch self {
        case .outlines(_, let report):
            let characters = report.characters.joined(separator: " ")
            return "outlines        \(report.characters.count) glyphs redrawn (\(characters)), "
                + "\(report.composites) composite glyphs use them, \(report.advances) advances changed"
        case .decompose(let composites):
            return "decompose       \(composites) composite glyphs flattened (outline operations follow)"
        case .embolden(let step, let report):
            let grades = EmboldenGrade.allCases.map { "\($0.rawValue) \(report.count(of: $0))" }
            return "embolden        weight \(formatNumber(step.weight)), \(step.skip.count) characters skipped, "
                + "\(step.perCharacter.count) with their own weight: \(report.glyphs.count) glyphs emboldened"
                + (step.widen ? widenSummary(report) : "") + "; grades " + grades.joined(separator: ", ")
        case .tracking(let options, let report):
            return "tracking        \(options.units > 0 ? "+" : "")\(options.units) units after each glyph: "
                + "\(report.glyphs) advances changed"
        case .lineHeight(let options, let report):
            func describe(_ metrics: LineMetrics?) -> String {
                metrics.map { "\($0.ascender)/\($0.descender)/\($0.lineGap)" } ?? "none"
            }
            return "lineHeight      \(options.units) units: ascender/descender/line gap \(describe(report.result)) "
                + "in hhea and typo, win \(describe(report.winResult)) (covers every glyph)\(typoSummary(report)) "
                + "(were hhea \(describe(report.hhea)), typo \(describe(report.typo)), win \(describe(report.win)))"
        case .s2t(let options, let report):
            var line =
                "s2t             \(options.mode.rawValue)\(options.taiwanVariants ? " + Taiwan variants" : ""): "
                + "\(report.remapped) code points remapped, \(report.alreadyTraditional) already shared a glyph"
            if report.added > 0 { line += ", \(report.added) added that the font lacked" }
            if options.mode == .skipAmbiguous { line += ", \(report.skippedAmbiguous) ambiguous left simplified" }
            if !report.fallbacks.isEmpty {
                let sample = report.fallbacks.prefix(12).map {
                    "\(character($0.simplified))→\(character($0.used)) not \(character($0.preferred))"
                }
                let more = report.fallbacks.count > 12 ? ", …" : ""
                line += ", \(report.fallbacks.count) via a later OpenCC candidate (font lacks the first: "
                line += sample.joined(separator: ", ") + more + ")"
            }
            line += ", \(report.missingTraditional.count) without a traditional glyph"
            if !report.missingTraditional.isEmpty {
                let sample = report.missingTraditional.prefix(12).map { conversion in
                    "\(character(conversion.simplified))→\(character(conversion.traditional))"
                }
                line += " (" + sample.joined(separator: " ") + (report.missingTraditional.count > 12 ? " …" : "") + ")"
            }
            if let phrases = report.phrases { line += "\n" + phrasesSummary(phrases) }
            return line
        case .pseudoVertical(let options, let report):
            let classes = VerticalOrientation.allCases.map { "\($0.rawValue) \(report.codePoints[$0] ?? 0)" }
            let lines = [("hhea descender", report.hheaDescender), ("usWinDescent", report.winDescent)].map {
                name, change in change.map { "\(name) \($0.before) → \($0.after)" } ?? "\(name) unchanged"
            }
            return "pseudoVertical  punctuation \(options.punctuation.rawValue): \(report.turned) code points turned "
                + "(\(report.viaVerticalForms) via vertical forms, \(report.centered) centred), "
                + "\(report.leftSideways) left sideways; \(report.transformedGlyphs) glyphs turned in place, "
                + "\(report.clonedGlyphs) cloned; by class " + classes.joined(separator: ", ")
                + "; line height ≥ \(formatNumber(Font.pseudoVerticalLineHeight)) em: " + lines.joined(separator: ", ")
        case .replace(let step, let report):
            var line =
                "replace         \(report.replaced) characters from \(report.familyName), scale "
                + String(format: "%.4f", report.scale) + " (\(step.match.rawValue)"
                + (step.size != 1 ? " × \(formatNumber(step.size))" : "")
                + (step.baselineShift != 0 ? ", baseline \(step.baselineShift > 0 ? "+" : "")\(step.baselineShift)" : "")
                + "): \(report.glyphs) glyphs added"
            if let xHeight = report.xHeight { line += ", x-height \(xHeight.before) → \(xHeight.after)" }
            if report.added > 0 { line += ", \(report.added) characters the font lacked" }
            if !report.notInReplacement.isEmpty {
                line += "; \(report.notInReplacement.count) not in the replacement font, kept"
            }
            if let source = report.kerning.source {
                line += "; \(report.kerning.pairs) kerning pairs from its \(source.rawValue)"
                if report.kerning.targetKernTablePairs > 0 {
                    line += " (+\(report.kerning.targetKernTablePairs) of the font's kern table moved to GPOS with them)"
                }
            } else {
                line += "; it has no kerning"
            }
            return line
        case .rename(let report):
            return "rename          \"\(report.fullName)\" (PostScript \(report.postScriptName), weight "
                + "\(report.weightClass)\(report.typographicNames ? ", typographic family" : "")); "
                + "\(report.removedRecords) old name records removed, \(report.writtenRecords) written"
        }
    }
}

private func widenSummary(_ report: EmboldenReport) -> String {
    var line = ", advances widened to keep the side bearings"
    if let mono = report.monospace {
        line = ", monospaced: every advance \(mono.advanceBefore) → \(mono.advanceAfter), glyphs centred in the wider cell"
        if mono.overflowing > 0 {
            line += " (\(mono.overflowing) grew by more than \(mono.advanceAfter - mono.advanceBefore), up to \(mono.maxOverflow) more,"
                + " reaching evenly into their neighbours)"
        }
        if mono.fixedPitchFlag == false { line += ", although post.isFixedPitch is 0" }
    }
    if report.anchorsMoved > 0 { line += ", GPOS anchors of \(report.anchorsMoved) glyphs moved with them" }
    return line
}

private func typoSummary(_ report: LineHeightReport) -> String {
    switch report.typoMetrics {
    case nil: return ""
    case .alreadySet: return ", USE_TYPO_METRICS already set"
    case .set: return ", USE_TYPO_METRICS set"
    case .setRaisingVersion(let version): return ", USE_TYPO_METRICS set (OS/2 version \(version) → 4)"
    case .unavailable(let version): return ", USE_TYPO_METRICS not set: OS/2 version \(version) has no such bit"
    }
}

private func phrasesSummary(_ report: PhraseReport) -> String {
    var line = "  phrases       \(report.phrases) OpenCC phrases: \(report.activeRules) substitution rules"
    if report.mergedPhrases > 0 { line += " (+\(report.mergedPhrases) phrases sharing one)" }
    line += ", \(report.blockingRules) blocking rules, \(report.unchanged) unchanged"
    if !report.shadowed.isEmpty {
        let sample = report.shadowed.prefix(6).map { "\($0.phrase) reads as \($0.rulePhrase)" }
        line +=
            ", \(report.shadowed.count) shadowed by a rule (" + sample.joined(separator: ", ")
            + (report.shadowed.count > 6 ? ", …" : "") + ")"
    }
    line += ", \(report.dropped.count) dropped"
    if !report.dropped.isEmpty {
        let sample = report.dropped.prefix(6).map { phrase in
            switch phrase.reason {
            case .characterNotInFont(let missing), .convertedCharacterNotInFont(let missing):
                return "\(phrase.phrase)→\(phrase.converted) lacks \(character(missing))"
            case .lengthChanged:
                return "\(phrase.phrase)→\(phrase.converted) changes length"
            }
        }
        line += " (" + sample.joined(separator: ", ") + (report.dropped.count > 6 ? ", …" : "") + ")"
    }
    line += "; GSUB \(report.gsubBytesBefore) → \(report.gsubBytesAfter) bytes"
    if report.contextSubtables > 0 {
        line += " (\(report.contextSubtables) context subtables, \(report.singleSubstitutionLookups) single lookups)"
    }
    return line
}

private func character(_ codePoint: UInt32) -> String {
    Unicode.Scalar(codePoint).map { String($0) } ?? "U+\(hex(codePoint))"
}

/// Failures that need the source font to detect.
public enum BuildError: Error, Equatable, Sendable {
    case sourceUnreadable(path: String, reason: String)
    case sourceHashMismatch(file: String, expected: String, actual: String)
    case licenseRestricted
    case licenseNotConfirmed
    case charactersNotInFont([String])
    case conflictingCharacterSettings([String])
    /// The replace step's second font (design §5.7), checked like the source.
    case replacementUnreadable(path: String, reason: String)
    case replacementHashMismatch(file: String, expected: String, actual: String)
    case replacementLicenseRestricted(file: String)
    case replacementLicenseNotConfirmed(file: String)
}

extension BuildError: LocalizedError, CustomStringConvertible {
    public var description: String {
        switch self {
        case .sourceUnreadable(let path, let reason):
            return "Cannot read the source font \(path): \(reason)"
        case .sourceHashMismatch(let file, let expected, let actual):
            return "The source font \(file) has sha256 \(actual), but the recipe expects \(expected). "
                + "The recipe was written for a different file or version of this font."
        case .licenseRestricted:
            return "The source font's OS/2 fsType has the Restricted License bit set: its license forbids "
                + "modification, so FontsMaker refuses to build from it."
        case .licenseNotConfirmed:
            return "The source font does not declare the SIL Open Font License (name IDs 13/14). Building requires "
                + "confirming you may modify and redistribute it (CLI: --i-have-rights)."
        case .charactersNotInFont(let entries):
            return "Characters in the embolden step that the source font does not contain: "
                + entries.joined(separator: ", ")
        case .conflictingCharacterSettings(let conflicts):
            return "Characters that share one glyph have different embolden settings; a shared glyph is "
                + "processed once, so give them the same setting: " + conflicts.joined(separator: "; ")
        case .replacementUnreadable(let path, let reason):
            return "Cannot read the replace step's font \(path): \(reason)"
        case .replacementHashMismatch(let file, let expected, let actual):
            return "The replace step's font \(file) has sha256 \(actual), but the recipe expects \(expected)."
        case .replacementLicenseRestricted(let file):
            return "The replace step's font \(file) has the Restricted License bit set in OS/2 fsType: its "
                + "license forbids modification, so FontsMaker refuses to copy its glyphs."
        case .replacementLicenseNotConfirmed(let file):
            return "The replace step's font \(file) does not declare the SIL Open Font License. Building requires "
                + "confirming you may modify and redistribute it too (CLI: --i-have-rights)."
        }
    }

    public var errorDescription: String? { description }
}

/// Runs a recipe end to end (technical design §6–§8). The app and the CLI
/// both call this, so the same recipe gives the same bytes in either.
public enum RecipeBuilder {
    /// Progress of the embolden step: (glyphs done, glyphs to do), from a
    /// worker thread, never concurrently. Return false to cancel; the build
    /// then throws `CancellationError`. Only embolden reports: it takes
    /// seconds on a CJK font, every other stage milliseconds.
    public typealias Progress = @Sendable (_ completed: Int, _ total: Int) -> Bool

    /// Reads the recipe and the source font it names, relative to the recipe file.
    public static func build(
        recipeAt url: URL, options: BuildOptions, progress: Progress? = nil
    ) throws -> BuildResult {
        let recipe = try Recipe(contentsOf: url)
        let sourceURL = recipe.sourceURL(recipeURL: url)
        let data: Data
        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            throw BuildError.sourceUnreadable(path: sourceURL.path, reason: error.localizedDescription)
        }
        var replacementData: [String: Data] = [:]
        for replace in recipe.replaceSteps where replacementData[replace.font.sha256] == nil {
            // Beside the recipe, like the source.
            let replacementURL = URL(fileURLWithPath: replace.font.file, relativeTo: url.deletingLastPathComponent())
                .standardizedFileURL
            do {
                replacementData[replace.font.sha256] = try Data(contentsOf: replacementURL)
            } catch {
                throw BuildError.replacementUnreadable(path: replacementURL.path, reason: error.localizedDescription)
            }
        }
        return try build(
            recipe, sourceData: data, replacementData: replacementData, options: options, progress: progress)
    }

    /// Order: load → license gate → sha256 → naming rules → outlines → decompose (if an
    /// outline operation follows) → steps in recipe order → rename → write
    /// (hinting stripped iff an outline operation ran).
    ///
    /// - Parameter replacementData: the files the replace steps name, keyed
    ///   by the sha256 the recipe pins each with (the bytes are still
    ///   checked against it); one entry serves every step naming that file.
    public static func build(
        _ recipe: Recipe, sourceData: Data, replacementData: [String: Data] = [:], options: BuildOptions,
        progress: Progress? = nil
    ) throws -> BuildResult {
        var font = try Font(
            data: sourceData, faceIndex: recipe.source.faceIndex, variation: recipe.source.variation)

        let license = font.licenseStatus
        switch license {
        case .restricted: throw BuildError.licenseRestricted
        case .unknown where !options.iHaveRights: throw BuildError.licenseNotConfirmed
        case .unknown, .openFontLicense: break
        }

        let actual = sha256Hex(sourceData)
        guard actual == recipe.source.sha256 else {
            throw BuildError.sourceHashMismatch(
                file: recipe.source.file, expected: recipe.source.sha256, actual: actual)
        }

        let recipeHash = try recipe.identityHash()
        let rename = RenameOptions(
            familyName: recipe.output.familyName, localizedFamilyNames: recipe.output.localizedFamilyName,
            styleName: recipe.output.styleName, weightClass: recipe.output.weightClass.map { UInt16($0) },
            provenance: "FontsMaker \(FontsMakerEngine.version); recipe \(recipeHash.prefix(8))")
        // Steps never change names, so the source decides; failing here saves
        // running an expensive step only to be refused at the end.
        try font.validateRename(rename)
        try recipe.steps.checkReplacedOnce()
        // By step index: two steps may name one file in different instances.
        var replacements: [Int: Font] = [:]
        for (index, step) in recipe.steps.enumerated() {
            guard case .replace(let replace) = step else { continue }
            replacements[index] = try loadReplacement(
                replace, data: replacementData[replace.font.sha256], options: options, rename: rename)
        }

        var reports: [StepReport] = []
        var emboldenSnapshots: (before: Font, after: Font)?
        let outlineOperations = recipe.steps.contains(where: \.modifiesOutlines)
        // Before composites are flattened, so é shows a redrawn e (design §5.8).
        if let outlines = try recipe.steps.leadingOutlines() {
            reports.append(.outlines(outlines, try font.applyOutlines(outlines)))
        }
        if outlineOperations {
            let composites = font.glyphs.filter(\.isComposite).count
            try font.decomposeComposites()
            reports.append(.decompose(composites: composites))
        }

        for (index, step) in recipe.steps.enumerated() {
            switch step {
            case .outlines:
                break  // applied above
            case .embolden(let embolden):
                let options = try embolden.resolve(in: font)
                // Fonts are values sharing their glyph storage, so the
                // snapshots cost only the glyphs that later steps replace.
                let before = font
                let report = try font.embolden(options, progress: progress)
                emboldenSnapshots = (before, font)
                reports.append(.embolden(embolden, report))
            case .tracking(let tracking):
                reports.append(.tracking(tracking, try font.applyTracking(tracking)))
            case .lineHeight(let lineHeight):
                reports.append(.lineHeight(lineHeight, try font.applyLineHeight(lineHeight)))
            case .s2t(let s2t):
                reports.append(.s2t(s2t, try font.convertSimplifiedToTraditional(s2t)))
            case .pseudoVertical(let pseudoVertical):
                reports.append(.pseudoVertical(pseudoVertical, try font.applyPseudoVertical(pseudoVertical)))
            case .replace(let replace):
                reports.append(.replace(replace, try font.replaceGlyphs(replace, from: replacements[index]!)))
                font.appendNotices(of: replacements[index]!)
            }
        }
        // s2t phrases (design §5.4): the rules are glyph IDs, so they are
        // derived once every step has put its glyphs where they will ship.
        if font.phrasePlan != nil {
            let phrases = try font.buildPhraseLookups()
            if let index = reports.lastIndex(where: { if case .s2t = $0 { true } else { false } }),
                case .s2t(let options, var report) = reports[index]
            {
                report.phrases = phrases
                reports[index] = .s2t(options, report)
            }
        }

        let renameReport = try font.rename(rename)
        reports.append(.rename(renameReport))
        let data = try font.write(options: WriteOptions(stripHinting: outlineOperations))
        return BuildResult(
            fontData: data, fileName: recipe.output.fileName ?? "\(renameReport.postScriptName).ttf",
            recipeHash: recipeHash, license: license, reports: reports, emboldenSnapshots: emboldenSnapshots)
    }

    /// The replace step's font, through the same gates as the source: its
    /// license (the output carries its glyphs), its sha256, and the naming
    /// rules, since its family names and Reserved Font Names bind the output too.
    private static func loadReplacement(
        _ step: ReplaceStep, data: Data?, options: BuildOptions, rename: RenameOptions
    ) throws -> Font {
        guard let data else {
            throw BuildError.replacementUnreadable(path: step.font.file, reason: "no file was given for it")
        }
        let font = try Font(data: data, faceIndex: step.font.faceIndex, variation: step.font.variation)
        switch font.licenseStatus {
        case .restricted: throw BuildError.replacementLicenseRestricted(file: step.font.file)
        case .unknown where !options.iHaveRights: throw BuildError.replacementLicenseNotConfirmed(file: step.font.file)
        case .unknown, .openFontLicense: break
        }
        let actual = sha256Hex(data)
        guard actual == step.font.sha256 else {
            throw BuildError.replacementHashMismatch(file: step.font.file, expected: step.font.sha256, actual: actual)
        }
        try font.validateRename(rename)
        return font
    }
}
