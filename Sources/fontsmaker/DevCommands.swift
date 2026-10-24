import ArgumentParser
import FontsMakerKit
import Foundation

/// Development aid for verifying the sfnt reader/writer against fontTools.
struct Roundtrip: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read a font and write it back without changes (development).",
        shouldDisplay: false
    )

    @Argument(help: "Source font: TrueType, CFF (.otf), variable or a collection (.ttc).")
    var input: String

    @Argument(help: "Destination path.")
    var output: String

    @Flag(help: "Apply the outline-modified write policy: drop all hinting.")
    var stripHinting = false

    @Flag(help: "Flatten composite glyphs into simple glyphs before writing.")
    var decompose = false

    @Option(help: "Font of a collection (.ttc) to read.")
    var face: Int = 0

    @Option(help: "Variable font instance, e.g. wght=700,opsz=12; other axes take their default.")
    var variation: String?

    func run() throws {
        let axes = try variation.map(parseVariation) ?? [:]
        let clock = ContinuousClock()
        var start = clock.now
        var font = try Font(
            data: try Data(contentsOf: URL(fileURLWithPath: input)), faceIndex: face, variation: axes)
        let readTime = clock.now - start

        start = clock.now
        if decompose { try font.decomposeComposites() }
        let decomposeTime = clock.now - start

        start = clock.now
        let data = try font.write(options: WriteOptions(stripHinting: stripHinting))
        try data.write(to: URL(fileURLWithPath: output))
        let writeTime = clock.now - start

        func ms(_ duration: Duration) -> String {
            String(format: "%.1f", duration / .milliseconds(1))
        }
        print(
            "glyphs=\(font.glyphs.count) bytes=\(data.count) read_ms=\(ms(readTime)) "
                + "decompose_ms=\(ms(decomposeTime)) write_ms=\(ms(writeTime))")
    }
}

/// Development aid for the glyph editor (Phase 4f): how many nodes each
/// character's outline becomes when made editable, how far simplification
/// strays, and how far the glyph lands from the source after a build
/// converts it back (cu2qu and rounding included).
struct EditableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "editable",
        abstract: "Report the editable cubic outlines of characters (development).",
        shouldDisplay: false
    )

    @Argument(help: "Source font.")
    var input: String

    @Option(help: "Characters to report.")
    var characters: String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

    @Option(help: "Simplification tolerance in font units (default: 1 per 1000 units of em).")
    var tolerance: Double?

    @Option(help: "Variable font instance, e.g. wght=700.")
    var variation: String?

    @Option(
        name: .customLong("dump-dir"),
        help: "Also write each editable glyph as the recipe's JSON, to <dir>/<code point in hex>.json.")
    var dumpDirectory: String?

    func run() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let font = try Font(
            data: try Data(contentsOf: URL(fileURLWithPath: input)),
            variation: try variation.map(parseVariation) ?? [:])
        let tolerance = tolerance ?? EditedGlyph.defaultTolerance(unitsPerEm: Int(font.unitsPerEm))
        print("upm=\(font.unitsPerEm) tolerance=\(tolerance)")
        print("char  points  nodes(exact)  nodes  simplify_err  roundtrip_err")
        var totals = (points: 0, exact: 0, nodes: 0, simplify: 0.0, roundtrip: 0.0)
        for character in characters.unicodeScalars {
            guard let glyphID = font.characterMap.mappings[character.value].map(Int.init),
                let exact = try font.editableGlyph(for: character.value, tolerance: 0),
                let (edited, error) = try font.editableGlyph(for: character.value, tolerance: tolerance)
            else {
                print("\(character)     not in font")
                continue
            }
            let source = try font.flattenedSimpleOutline(ofGlyph: glyphID)
            var built = font
            _ = try built.applyOutlines(OutlinesStep(glyphs: [String(character): edited]))
            guard case .simple(let result) = built.glyphs[glyphID].outline else { continue }
            let roundtrip = source.maxDistance(to: result)
            print(
                String(
                    format: "%@  %6d  %12d  %5d  %12.3f  %13.3f", String(character), source.points.count,
                    exact.glyph.nodeCount, edited.nodeCount, error, roundtrip))
            if let dumpDirectory {
                let url = URL(fileURLWithPath: dumpDirectory)
                    .appendingPathComponent(String(format: "%04X.json", character.value))
                try encoder.encode(edited).write(to: url)
            }
            totals.points += source.points.count
            totals.exact += exact.glyph.nodeCount
            totals.nodes += edited.nodeCount
            totals.simplify = max(totals.simplify, error)
            totals.roundtrip = max(totals.roundtrip, roundtrip)
        }
        print(
            String(
                format: "total points=%d exact_nodes=%d nodes=%d max_simplify_err=%.3f max_roundtrip_err=%.3f",
                totals.points, totals.exact, totals.nodes, totals.simplify, totals.roundtrip))
    }
}

/// `wght=700,opsz=12` → ["wght": 700, "opsz": 12].
func parseVariation(_ text: String) throws -> [String: Double] {
    var axes: [String: Double] = [:]
    for item in text.split(separator: ",") {
        let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, let value = Double(parts[1]) else {
            throw ValidationError("--variation expects tag=value pairs such as wght=700,opsz=12, got '\(item)'")
        }
        axes[parts[0]] = value
    }
    return axes
}

/// Development aid for the embolden engine: the whole font at one weight,
/// written the way a build would write it (decomposed, hinting stripped).
struct EmboldenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "embolden",
        abstract: "Embolden every glyph of a font (development).",
        shouldDisplay: false
    )

    @Argument(help: "Source TrueType font.")
    var input: String

    @Argument(help: "Destination path.")
    var output: String

    @Option(help: "Total stem increase in font units.")
    var weight: Double

    @Option(help: "Miter limit for stroke joins.")
    var miterLimit: Double = 4

    @Option(help: "Write the per-glyph risk report as CSV.")
    var report: String?

    @Option(help: "Write the grade A/B review sheet as PNG (-pN suffix when it spans pages).")
    var sheet: String?

    @Option(help: "Worker threads (default: all cores).")
    var threads: Int?

    func run() throws {
        let clock = ContinuousClock()
        var start = clock.now
        let sourceData = try Data(contentsOf: URL(fileURLWithPath: input))
        var font = try Font(data: sourceData)
        let readTime = clock.now - start

        start = clock.now
        try font.decomposeComposites()
        let decomposeTime = clock.now - start
        let decomposed = font

        start = clock.now
        let result = try font.embolden(
            EmboldenOptions(weight: weight, miterLimit: miterLimit), maxConcurrency: threads)
        let emboldenTime = clock.now - start

        start = clock.now
        let data = try font.write(options: WriteOptions(stripHinting: true))
        try data.write(to: URL(fileURLWithPath: output))
        let writeTime = clock.now - start

        func ms(_ duration: Duration) -> String { String(format: "%.1f", duration / .milliseconds(1)) }
        print(
            "glyphs=\(font.glyphs.count) emboldened=\(result.glyphs.count) threads=\(threads.map(String.init) ?? "all") "
                + "source_bytes=\(sourceData.count) bytes=\(data.count) read_ms=\(ms(readTime)) "
                + "decompose_ms=\(ms(decomposeTime)) embolden_ms=\(ms(emboldenTime)) write_ms=\(ms(writeTime))")
        let total = max(1, result.glyphs.count)
        print(
            "grades "
                + EmboldenGrade.allCases.map {
                    let count = result.count(of: $0)
                    return "\($0.rawValue)=\(count) (\(String(format: "%.2f", 100 * Double(count) / Double(total)))%)"
                }.joined(separator: " "))

        if let report {
            try Data(result.csv().utf8).write(to: URL(fileURLWithPath: report))
            print("wrote \(report)")
        }
        if let sheet {
            let pages = try result.riskSheet(
                source: decomposed, emboldened: font,
                title: "\(URL(fileURLWithPath: input).lastPathComponent), weight \(String(format: "%g", weight)): "
                    + "grades A and B, worst first")
            let base = URL(fileURLWithPath: sheet)
            for (index, page) in pages.enumerated() {
                let url =
                    pages.count == 1
                    ? base
                    : base.deletingPathExtension().appendingPathExtension("p\(index + 1)").appendingPathExtension("png")
                try page.write(to: url)
                print("wrote \(url.path)")
            }
        }
    }
}

/// Prints the GSUB vert/vrt2 single-substitution map as JSON (glyph ID → glyph ID)
/// so scripts/verify_roundtrip.py can compare it with fontTools.
struct VertMap: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vert-map",
        abstract: "Print the vert/vrt2 substitution map as JSON (development).",
        shouldDisplay: false
    )

    @Argument(help: "TrueType font.")
    var font: String

    func run() throws {
        let model = try Font(contentsOf: URL(fileURLWithPath: font))
        let entries = model.verticalSubstitutions.sorted { $0.key < $1.key }.map { "\"\($0.key)\": \($0.value)" }
        print("{" + entries.joined(separator: ", ") + "}")
    }
}
