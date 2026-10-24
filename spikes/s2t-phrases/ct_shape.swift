// Shapes text lines with CoreText (default features) and writes one JSON
// array per input line: [[glyph, scalar index, advance x, advance y], ...].
// Glyphs from a fallback font are written as -1, so a missing glyph can never
// pass for a match. Used to compare CoreText with HarfBuzz and the oracle.
//
// Usage: ct_shape <font.ttf> <in.txt> <out.jsonl> [--lang TAG] [--vertical]
//                 [--frame] [--time N]
//   --vertical  kCTVerticalFormsAttributeName (vert/vrt2 on)
//   --frame     lay out in a vertical CTFrame (right-to-left progression)
//   --time N    shape every line N times, print the fastest pass in seconds
import CoreText
import Foundation

var arguments = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool {
    guard let i = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: i)
    return true
}
func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    let value = arguments[i + 1]
    arguments.removeSubrange(i...(i + 1))
    return value
}
let vertical = flag("--vertical")
let frame = flag("--frame")
let language = option("--lang")
let repeats = option("--time").flatMap(Int.init)
guard arguments.count == 3 else {
    FileHandle.standardError.write("usage: ct_shape font in out [--lang tag] [--vertical] [--frame] [--time n]\n".data(using: .utf8)!)
    exit(2)
}

let fontData = try Data(contentsOf: URL(fileURLWithPath: arguments[0])) as CFData
guard let descriptor = CTFontManagerCreateFontDescriptorFromData(fontData) else {
    FileHandle.standardError.write("not a font: \(arguments[0])\n".data(using: .utf8)!)
    exit(1)
}
// Size = unitsPerEm (1000 for every font here), so advances are font units.
let font = CTFontCreateWithFontDescriptor(descriptor, 1000, nil)
let postScriptName = CTFontCopyPostScriptName(font) as String
var lines = try String(contentsOfFile: arguments[1], encoding: .utf8).components(separatedBy: "\n")
if lines.last == "" { lines.removeLast() }

var attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
if let language { attributes[NSAttributedString.Key(kCTLanguageAttributeName as String)] = language }
if vertical { attributes[NSAttributedString.Key(kCTVerticalFormsAttributeName as String)] = true }

func runs(of line: String) -> [CTRun] {
    let string = NSAttributedString(string: line, attributes: attributes)
    if frame {
        let setter = CTFramesetterCreateWithAttributedString(string)
        // Columns 1000 em tall at 1000 pt: a probe line never wraps. (A
        // 1e8-unit path makes CoreText return no lines at all.)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: 1_000_000, height: 1_000_000), transform: nil)
        let frameAttributes = [kCTFrameProgressionAttributeName: CTFrameProgression.rightToLeft.rawValue] as CFDictionary
        let laidOut = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, frameAttributes)
        return (CTFrameGetLines(laidOut) as! [CTLine]).flatMap { CTLineGetGlyphRuns($0) as! [CTRun] }
    }
    return CTLineGetGlyphRuns(CTLineCreateWithAttributedString(string)) as! [CTRun]
}

func shape(_ line: String) -> [[Int]] {
    var scalarAt: [Int] = []
    for (index, scalar) in line.unicodeScalars.enumerated() {
        for _ in 0..<scalar.utf16.count { scalarAt.append(index) }
    }
    var out: [[Int]] = []
    for run in runs(of: line) {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var indices = [CFIndex](repeating: 0, count: count)
        var advances = [CGSize](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
        CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
        CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
        let runAttributes = CTRunGetAttributes(run) as NSDictionary
        let runFont = runAttributes[kCTFontAttributeName as String] as! CTFont
        // Not CFEqual: with vertical forms CoreText substitutes a derived
        // vertical instance of the same font. The PostScript name still tells
        // our font from a fallback (spike fonts have unique names).
        let ours = (CTFontCopyPostScriptName(runFont) as String) == postScriptName
        for i in 0..<count {
            out.append([
                ours ? Int(glyphs[i]) : -1, scalarAt[indices[i]],
                Int(advances[i].width.rounded()), Int(advances[i].height.rounded()),
            ])
        }
    }
    return out
}

if let repeats {
    var best = Double.infinity
    for _ in 0..<repeats {
        let start = DispatchTime.now().uptimeNanoseconds
        var glyphCount = 0
        for line in lines { glyphCount += shape(line).count }
        best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        precondition(glyphCount > 0)
    }
    print(String(format: "%.4f", best))
    exit(0)
}

var output = ""
for line in lines {
    let data = try JSONSerialization.data(withJSONObject: shape(line))
    output += String(data: data, encoding: .utf8)! + "\n"
}
try output.write(toFile: arguments[2], atomically: true, encoding: .utf8)
