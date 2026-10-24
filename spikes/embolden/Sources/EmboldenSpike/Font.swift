import CoreGraphics
import CoreText
import Foundation

/// A font opened through CoreText at size = unitsPerEm, so every path
/// coordinate is already in font units and no sfnt parsing is needed.
final class LoadedFont {
    let path: String
    let cgFont: CGFont
    let ctFont: CTFont
    let upm: Int
    let glyphCount: Int
    let glyphByChar: [UInt32: CGGlyph]
    let charsByGlyph: [Int: [UInt32]]

    init(path: String) {
        self.path = path
        let url = URL(fileURLWithPath: path) as CFURL
        guard let provider = CGDataProvider(url: url), let cg = CGFont(provider) else {
            fail("cannot open font \(path)")
        }
        cgFont = cg
        upm = Int(cg.unitsPerEm)
        ctFont = CTFontCreateWithGraphicsFont(cg, CGFloat(upm), nil, nil)
        glyphCount = CTFontGetGlyphCount(ctFont)

        // Reverse cmap built by probing the font's character set; CoreText has
        // no direct "glyph -> characters" API.
        let cs = CTFontCopyCharacterSet(ctFont)
        var byChar: [UInt32: CGGlyph] = [:]
        var byGlyph: [Int: [UInt32]] = [:]
        for cp in UInt32(0)...0x10FFFF {
            if (0xD800...0xDFFF).contains(cp) { continue }
            guard CFCharacterSetIsLongCharacterMember(cs, cp) else { continue }
            var units = Array(String(Character(Unicode.Scalar(cp)!)).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            guard CTFontGetGlyphsForCharacters(ctFont, &units, &glyphs, units.count), glyphs[0] != 0
            else { continue }
            byChar[cp] = glyphs[0]
            byGlyph[Int(glyphs[0]), default: []].append(cp)
        }
        glyphByChar = byChar
        charsByGlyph = byGlyph
    }

    func outline(_ g: CGGlyph) -> CGPath? { CTFontCreatePathForGlyph(ctFont, g, nil) }

    func name(_ g: CGGlyph) -> String { (cgFont.name(for: g) as String?) ?? "gid\(g)" }

    func advance(_ g: CGGlyph) -> Double {
        var glyph = g
        var adv = CGSize.zero
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &adv, 1)
        return Double(adv.width)
    }

    func glyph(for scalar: Unicode.Scalar) -> CGGlyph? { glyphByChar[scalar.value] }
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("error: " + msg + "\n").data(using: .utf8)!)
    exit(2)
}
