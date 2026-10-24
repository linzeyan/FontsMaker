// Lays out text lines with CoreText, default features only (what a reader
// app does), and writes one JSON array per line: [[glyph, scalar index], ...].
// Glyphs from a fallback font are written as -1, so a missing glyph can never
// pass for a match. Used by scripts/verify-s2t-phrases.sh next to hb-shape.
//
// Usage: ct_shape <font.ttf> <in.txt> <out.jsonl> [--lang TAG]
import CoreText
import Foundation

var arguments = Array(CommandLine.arguments.dropFirst())
var language: String?
if let index = arguments.firstIndex(of: "--lang"), index + 1 < arguments.count {
    language = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
}
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: ct_shape font in out [--lang tag]\n".utf8))
    exit(2)
}

let fontData = try Data(contentsOf: URL(fileURLWithPath: arguments[0])) as CFData
guard let descriptor = CTFontManagerCreateFontDescriptorFromData(fontData) else {
    FileHandle.standardError.write(Data("not a font: \(arguments[0])\n".utf8))
    exit(1)
}
let font = CTFontCreateWithFontDescriptor(descriptor, 1000, nil)
let postScriptName = CTFontCopyPostScriptName(font) as String
var lines = try String(contentsOfFile: arguments[1], encoding: .utf8).components(separatedBy: "\n")
if lines.last == "" { lines.removeLast() }

var attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
if let language { attributes[NSAttributedString.Key(kCTLanguageAttributeName as String)] = language }

func shape(_ line: String) -> [[Int]] {
    var scalarAt: [Int] = []
    for (index, scalar) in line.unicodeScalars.enumerated() {
        for _ in 0..<scalar.utf16.count { scalarAt.append(index) }
    }
    let laidOut = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes))
    var out: [[Int]] = []
    for run in CTLineGetGlyphRuns(laidOut) as! [CTRun] {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var indices = [CFIndex](repeating: 0, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
        CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
        let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] as! CTFont
        let ours = (CTFontCopyPostScriptName(runFont) as String) == postScriptName
        for index in 0..<count {
            out.append([ours ? Int(glyphs[index]) : -1, scalarAt[indices[index]]])
        }
    }
    return out
}

var output = ""
for line in lines {
    output += String(decoding: try JSONSerialization.data(withJSONObject: shape(line)), as: UTF8.self) + "\n"
}
try output.write(toFile: arguments[2], atomically: true, encoding: .utf8)
