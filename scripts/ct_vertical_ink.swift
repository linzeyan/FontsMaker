// Sets each line of a text file as vertical text with CoreText (vertical
// forms, right-to-left line progression, as a reader app sets 直排) at
// 1000 pt, renders it and writes the ink's bounding box in pixels, one JSON
// array per line: [minX, minY, maxX, maxY], or null when nothing is drawn.
// At 1000 pt on a 1000-unit em one pixel is one font unit, so comparing two
// fonts' boxes says how far their ink sits apart in vertical text. Used by
// scripts/verify-phase4a.sh; run once per font, since a converted font keeps
// its source's PostScript name and one process would see only one of them.
//
// Usage: ct_vertical_ink <font> <in.txt> <out.jsonl>
import CoreGraphics
import CoreText
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: ct_vertical_ink font in out\n".utf8))
    exit(2)
}
let data = try Data(contentsOf: URL(fileURLWithPath: arguments[0])) as CFData
guard let descriptor = CTFontManagerCreateFontDescriptorFromData(data) else {
    FileHandle.standardError.write(Data("not a font: \(arguments[0])\n".utf8))
    exit(1)
}
let font = CTFontCreateWithFontDescriptor(descriptor, 1000, nil)
var lines = try String(contentsOfFile: arguments[1], encoding: .utf8).components(separatedBy: "\n")
if lines.last == "" { lines.removeLast() }

let side = 3000
let attributes: [NSAttributedString.Key: Any] = [
    NSAttributedString.Key(kCTFontAttributeName as String): font,
    NSAttributedString.Key(kCTVerticalFormsAttributeName as String): true,
    NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
]
let frameAttributes = [kCTFrameProgressionAttributeName: CTFrameProgression.rightToLeft.rawValue] as CFDictionary

func inkBox(_ text: String) -> [Int]? {
    guard
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return nil }
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    context.setFillColor(gray: 1, alpha: 1)
    let setter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let frame = CTFramesetterCreateFrame(
        setter, CFRange(location: 0, length: 0),
        CGPath(rect: CGRect(x: 0, y: 0, width: side, height: side), transform: nil),
        frameAttributes)
    CTFrameDraw(frame, context)
    guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    var box: [Int]?
    // Half coverage marks the edge: antialiasing of the same edge then
    // agrees to the pixel between two renderings.
    for row in 0..<side {
        for column in 0..<side where pixels[row * side + column] >= 128 {
            let y = side - 1 - row
            if let current = box {
                box = [min(current[0], column), min(current[1], y), max(current[2], column), max(current[3], y)]
            } else {
                box = [column, y, column, y]
            }
        }
    }
    return box
}

var output = ""
for line in lines {
    if let box = inkBox(line) {
        output += "[\(box.map(String.init).joined(separator: ","))]\n"
    } else {
        output += "null\n"
    }
}
try output.write(toFile: arguments[2], atomically: true, encoding: .utf8)
