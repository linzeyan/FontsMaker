import CoreText
import Foundation
import Testing

@testable import FontsMakerKit

/// ops.ttf (scripts/make-test-fonts.py `build_ops`) with fontTools' glyph
/// order, so tests name glyphs instead of hard-coding IDs.
struct OpsFixture {
    struct Expectation: Decodable {
        let glyphOrder: [String]
        let cmap: [String: Int]
    }

    static let fileName = "ops.ttf"
    let font: Font
    let expectation: Expectation

    init() throws {
        font = try Fixtures.font(OpsFixture.fileName)
        let data = try Data(contentsOf: Fixtures.directory.appendingPathComponent("ops-expected.json"))
        expectation = try JSONDecoder().decode(Expectation.self, from: data)
    }

    func glyph(_ name: String) -> UInt16 {
        UInt16(expectation.glyphOrder.firstIndex(of: name)!)
    }

    static var bytes: [UInt8] {
        get throws { try Fixtures.bytes(fileName) }
    }

    static var sha256: String {
        get throws { sha256Hex(try bytes) }
    }
}

/// A recipe JSON document for the given source, as a user would write it.
func recipeJSON(sourceFile: String, sha256: String, output: String, steps: String = "[]") -> Data {
    Data(
        """
        {"formatVersion": 1, "source": {"file": "\(sourceFile)", "sha256": "\(sha256)"},
         "output": \(output), "steps": \(steps)}
        """.utf8)
}

/// A fresh directory under the system temporary directory, removed by the caller.
func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("fontsmaker-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func points(_ glyph: Glyph) -> [GlyphPoint] {
    guard case .simple(let outline) = glyph.outline else { return [] }
    return outline.points
}

/// CoreText view of font bytes; proves the system rasterizer accepts them.
func coreTextFont(_ data: Data, size: CGFloat = 1000) throws -> CTFont {
    let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor]
    let descriptor = try #require(descriptors?.first, "CoreText could not load the font data")
    return CTFontCreateWithFontDescriptor(descriptor, size, nil)
}

/// Glyph IDs CoreText lays out for `text`: shaping included, so this is what
/// a reader app shows, not just a cmap lookup.
func laidOutGlyphs(_ font: CTFont, _ text: String) -> [CGGlyph] {
    let attributed = NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font])
    let line = CTLineCreateWithAttributedString(attributed)
    var result: [CGGlyph] = []
    for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
        var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
        result += glyphs
    }
    return result
}
