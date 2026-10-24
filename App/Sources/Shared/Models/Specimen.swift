import CoreText
import Foundation

/// Fonts read straight from their files, never installed: the library's
/// copies for the specimen cards, the source for text that names its
/// characters.
@MainActor
enum Specimen {
    nonisolated static let chinese = "天地玄黃 宇宙洪荒"
    nonisolated static let latin = "Hamburgefonstiv 0123"
    /// For monospaced fonts: i, l and 1 as wide as m and w is what tells
    /// them apart, and 0／O, l／1 are the pairs a code font must not confuse.
    nonisolated static let mono = "il1 mw 0O {}"

    private static var descriptors: [URL: CTFontDescriptor] = [:]

    static func font(_ url: URL, size: CGFloat) -> CTFont? {
        if descriptors[url] == nil,
            let found = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
            let first = found.first
        {
            descriptors[url] = first
        }
        return descriptors[url].map { CTFontCreateWithFontDescriptor($0, size, nil) }
    }

    /// The Chinese specimen when the font has every character of it, else
    /// the Latin one: a font without CJK would show a row of empty boxes.
    nonisolated static func text(for font: CTFont) -> String {
        covers(font, chinese.filter { $0 != " " }) ? chinese : latin
    }

    nonisolated static func covers(_ font: CTFont, _ text: String) -> Bool {
        var units = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        return CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
    }

    /// The system's monospaced font, falling back to the source font for
    /// what it lacks: step reports quote the source's characters (rare
    /// ideographs among them), which the system fonts show as empty boxes.
    static func reportFont(source url: URL, size: CGFloat) -> CTFont {
        let system =
            CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)
            ?? CTFontCreateWithName("Menlo" as CFString, size, nil)
        guard let source = font(url, size: size) else { return system }
        let cascade = CTFontDescriptorCreateWithAttributes(
            [kCTFontCascadeListAttribute: [CTFontCopyFontDescriptor(source)]] as CFDictionary)
        return CTFontCreateCopyWithAttributes(system, size, nil, cascade)
    }
}
