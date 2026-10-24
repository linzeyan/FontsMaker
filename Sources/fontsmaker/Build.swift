import ArgumentParser
import CryptoKit
import FontsMakerKit
import Foundation

struct Build: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build fonts from recipes: one recipe, one output font.",
        discussion: """
            Each recipe names its source font relative to the recipe file and pins it by sha256. \
            The output goes to output.fileName (default <PostScriptName>.ttf) in --out-dir. \
            A recipe with an embolden step also writes, next to the font, the per-glyph risk report \
            <font stem>.embolden.csv and review sheets of grades A and B, <font stem>.risk-pN.png; \
            pages of that name left by an earlier build are removed first. \
            Every recipe is attempted; the exit status is nonzero if any failed.
            """
    )

    @Argument(help: "Recipe files (.json).")
    var recipes: [String]

    @Option(name: .customLong("out-dir"), help: "Directory for the built fonts (created if missing).")
    var outDir: String = "."

    @Flag(
        name: .customLong("i-have-rights"),
        help: "Confirm you may modify and redistribute source fonts whose license is not recognized as OFL.")
    var iHaveRights = false

    func run() throws {
        let directory = URL(fileURLWithPath: outDir, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: Set<String> = []
        var failures = 0
        for path in recipes {
            let recipeURL = URL(fileURLWithPath: path)
            print("== \(path)")
            do {
                let result = try RecipeBuilder.build(
                    recipeAt: recipeURL, options: BuildOptions(iHaveRights: iHaveRights))
                let destination = directory.appendingPathComponent(result.fileName)
                // Two recipes of one run writing the same file would silently lose one font.
                guard written.insert(destination.standardizedFileURL.path).inserted else {
                    throw ValidationError("another recipe in this run already wrote \(destination.path)")
                }
                try result.fontData.write(to: destination, options: .atomic)
                print("  license         \(describe(result.license))")
                for report in result.reports {
                    for line in report.summary.split(separator: "\n") { print("  " + line) }
                }
                if case .rename(let rename) = result.reports.last {
                    print("  note            \(rename.reservedNameNotice)")
                }
                let sha = SHA256.hash(data: result.fontData).map { String(format: "%02x", $0) }.joined()
                print("  output          \(destination.path) (\(result.fontData.count) bytes, sha256 \(sha))")
                try writeRiskReview(result, next: destination)
                print("  recipe hash     \(result.recipeHash)")
            } catch {
                failures += 1
                FileHandle.standardError.write(Data("error: \(path): \(error.localizedDescription)\n".utf8))
            }
        }
        if failures > 0 {
            FileHandle.standardError.write(Data("\(failures) of \(recipes.count) recipes failed\n".utf8))
            throw ExitCode.failure
        }
    }

    /// The CLI side of risk review (product spec §4.5): the CSV for every
    /// emboldened glyph and PNG pages of grades A and B, named after the font.
    private func writeRiskReview(_ result: BuildResult, next font: URL) throws {
        for case .embolden(let step, let report) in result.reports {
            guard let snapshots = result.emboldenSnapshots else {
                preconditionFailure("RecipeBuilder keeps snapshots whenever embolden runs")
            }
            let stem = font.deletingPathExtension().lastPathComponent
            let directory = font.deletingLastPathComponent()
            try removeRiskPages(of: stem, in: directory)
            let csv = directory.appendingPathComponent("\(stem).embolden.csv")
            try Data(report.csv().utf8).write(to: csv, options: .atomic)
            print("  embolden report \(csv.path) (\(report.glyphs.count) glyphs)")
            let pages = try report.riskSheet(
                source: snapshots.before, emboldened: snapshots.after,
                title: "\(result.fileName), weight \(String(format: "%g", step.weight)): grades A and B, worst first")
            for (index, page) in pages.enumerated() {
                let url = directory.appendingPathComponent("\(stem).risk-p\(index + 1).png")
                try page.write(to: url, options: .atomic)
                print("  risk sheet      \(url.path)")
            }
            if pages.isEmpty { print("  risk sheet      none: no glyph graded A or B") }
        }
    }

    /// A rebuild with fewer A/B glyphs writes fewer pages; pages left from an
    /// earlier build would pass for part of this review. Only names this
    /// command writes for this stem (`<stem>.risk-p<digits>.png`) are removed:
    /// the rest of the directory may be the user's.
    private func removeRiskPages(of stem: String, in directory: URL) throws {
        let prefix = "\(stem).risk-p"
        let suffix = ".png"
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { continue }
            let number = name.dropFirst(prefix.count).dropLast(suffix.count)
            guard !number.isEmpty, number.allSatisfy({ ("0"..."9").contains($0) }) else { continue }
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func describe(_ status: LicenseStatus) -> String {
        switch status {
        case .openFontLicense: return "OFL"
        case .unknown: return "not recognized; built because --i-have-rights was given"
        case .restricted: return "restricted"
        }
    }
}
