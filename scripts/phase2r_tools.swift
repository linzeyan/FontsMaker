// CoreText side of the Phase 2 verification (scripts/verify-phase2.sh).
// Compiled with swiftc into the artifacts directory; never part of the package.
//
//   phase2r_tools load FONT...
//       Loads each file through CoreText and prints its names and glyph count.
//   phase2r_tools layout-compare FONT_A TEXT_A FONT_B TEXT_B
//       Lays out both lines (shaping included) and exits 1 unless the glyph
//       IDs agree.
//   phase2r_tools iou OURS REFERENCE OUT.tsv
//       For every code point both fonts map, rasterizes both glyphs in one
//       fixed em-relative window and writes "codepoint<TAB>IoU".
//   phase2r_tools sheet OUT.png TEXT_FILE LABEL=FONT...
//       Contact sheet in rotated view: each font sets TEXT horizontally, the
//       panel is turned 90° clockwise, panels sit side by side, labelled.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func loadFont(_ path: String, size: CGFloat? = nil) -> CTFont {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
        let descriptor = descriptors.first
    else { fail("CoreText cannot load \(path)") }
    let probe = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
    return CTFontCreateWithFontDescriptor(descriptor, size ?? CGFloat(CTFontGetUnitsPerEm(probe)), nil)
}

func glyphIDs(_ font: CTFont, _ text: String) -> [CGGlyph] {
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

func glyph(_ font: CTFont, _ codePoint: UInt32) -> CGGlyph? {
    guard let scalar = Unicode.Scalar(codePoint) else { return nil }
    let units = Array(String(scalar).utf16)
    var glyphs = [CGGlyph](repeating: 0, count: units.count)
    guard CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count), glyphs[0] != 0 else { return nil }
    return glyphs[0]
}

func codePoints(_ font: CTFont) -> Set<UInt32> {
    let set = CTFontCopyCharacterSet(font)
    var result = Set<UInt32>()
    for codePoint in UInt32(0)...0x10FFFF where CFCharacterSetIsLongCharacterMember(set, codePoint) {
        result.insert(codePoint)
    }
    return result
}

// A 128 px square covering [-0.5, 1.5] em on both axes: generous enough for
// turned glyphs whose ink leaves the em box, ~16 units per pixel at 1000 UPM.
let rasterSize = 128

func raster(_ font: CTFont, _ glyph: CGGlyph) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: rasterSize * rasterSize)
    let em = CGFloat(CTFontGetUnitsPerEm(font))
    pixels.withUnsafeMutableBytes { buffer in
        guard
            let context = CGContext(
                data: buffer.baseAddress, width: rasterSize, height: rasterSize, bitsPerComponent: 8,
                bytesPerRow: rasterSize, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { fail("cannot create a bitmap context") }
        context.setShouldAntialias(false)
        context.scaleBy(x: CGFloat(rasterSize) / (2 * em), y: CGFloat(rasterSize) / (2 * em))
        context.translateBy(x: em / 2, y: em / 2)
        if let path = CTFontCreatePathForGlyph(font, glyph, nil) {
            context.addPath(path)
            context.setFillColor(gray: 1, alpha: 1)
            context.fillPath(using: .winding)
        }
    }
    return pixels
}

func intersectionOverUnion(_ a: [UInt8], _ b: [UInt8]) -> Double {
    var both = 0
    var either = 0
    for index in a.indices {
        let inA = a[index] > 127
        let inB = b[index] > 127
        if inA && inB { both += 1 }
        if inA || inB { either += 1 }
    }
    return either == 0 ? 1 : Double(both) / Double(either)
}

func image(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
    guard
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("cannot create a bitmap context") }
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    draw(context)
    guard let result = context.makeImage() else { fail("cannot render") }
    return result
}

/// The paragraph set horizontally in `font`, like a reader app would.
func horizontalPanel(_ font: CTFont, _ text: String, lineWidth: CGFloat) -> CGImage {
    let attributed = NSAttributedString(
        string: text,
        attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    let size = CTFramesetterSuggestFrameSizeWithConstraints(
        framesetter, CFRange(location: 0, length: 0), nil, CGSize(width: lineWidth, height: .greatestFiniteMagnitude),
        nil)
    let margin: CGFloat = 24
    let width = Int(lineWidth + 2 * margin)
    let height = Int(ceil(size.height) + 2 * margin)
    return image(width: width, height: height) { context in
        let path = CGPath(
            rect: CGRect(x: margin, y: margin, width: lineWidth, height: ceil(size.height)), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
    }
}

/// Turned 90° clockwise: the first horizontal line becomes the rightmost column.
func rotatedClockwise(_ source: CGImage) -> CGImage {
    image(width: source.height, height: source.width) { context in
        context.translateBy(x: 0, y: CGFloat(source.width))
        context.rotate(by: -.pi / 2)
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
    }
}

func contactSheet(output: String, textFile: String, panels: [(label: String, path: String)]) {
    guard let text = try? String(contentsOfFile: textFile, encoding: .utf8) else { fail("cannot read \(textFile)") }
    let pointSize: CGFloat = 40
    let rotated = panels.map {
        rotatedClockwise(
            horizontalPanel(loadFont($0.path, size: pointSize), text.trimmingCharacters(in: .newlines), lineWidth: 16 * pointSize))
    }
    let labelHeight = 56
    let gap = 16
    let width = rotated.reduce(gap) { $0 + $1.width + gap }
    let height = labelHeight + (rotated.map(\.height).max() ?? 0) + gap
    let labelFont = CTFontCreateUIFontForLanguage(.system, 18, nil)!
    let sheet = image(width: width, height: height) { context in
        var x = gap
        for (index, panel) in rotated.enumerated() {
            let top = height - labelHeight
            context.draw(panel, in: CGRect(x: x, y: top - panel.height, width: panel.width, height: panel.height))
            context.setStrokeColor(gray: 0.7, alpha: 1)
            context.stroke(CGRect(x: x, y: top - panel.height, width: panel.width, height: panel.height))
            let label = NSAttributedString(
                string: panels[index].label,
                attributes: [
                    .init(kCTFontAttributeName as String): labelFont,
                    .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
                ])
            context.textPosition = CGPoint(x: CGFloat(x), y: CGFloat(top + 20))
            CTLineDraw(CTLineCreateWithAttributedString(label), context)
            x += panel.width + gap
        }
    }
    guard
        let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("cannot write \(output)") }
    CGImageDestinationAddImage(destination, sheet, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot write \(output)") }
    print("wrote \(output) (\(width)×\(height))")
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "load":
    for path in arguments.dropFirst() {
        let font = loadFont(path)
        let family = CTFontCopyFamilyName(font) as String
        let postScript = CTFontCopyPostScriptName(font) as String
        print("ok  \(URL(fileURLWithPath: path).lastPathComponent): family \"\(family)\", PostScript \(postScript), "
            + "\(CTFontGetGlyphCount(font)) glyphs")
    }
case "layout-compare" where arguments.count == 5:
    let ours = glyphIDs(loadFont(arguments[1]), arguments[2])
    let reference = glyphIDs(loadFont(arguments[3]), arguments[4])
    print("\(arguments[2])  \(ours)")
    print("\(arguments[4])  \(reference)")
    if ours != reference || ours.count != arguments[2].count { fail("glyph IDs differ") }
    print("RESULT layout: \(ours.count) glyphs equal")
case "iou" where arguments.count == 4:
    let ours = loadFont(arguments[1])
    let reference = loadFont(arguments[2])
    var lines: [String] = []
    for codePoint in codePoints(reference).intersection(codePoints(ours)).sorted() {
        guard let a = glyph(ours, codePoint), let b = glyph(reference, codePoint) else { continue }
        lines.append("\(codePoint)\t\(String(format: "%.4f", intersectionOverUnion(raster(ours, a), raster(reference, b))))")
    }
    guard FileManager.default.createFile(atPath: arguments[3], contents: Data((lines.joined(separator: "\n") + "\n").utf8))
    else { fail("cannot write \(arguments[3])") }
    print("wrote \(lines.count) code points to \(arguments[3])")
case "sheet" where arguments.count >= 4:
    let panels = arguments.dropFirst(3).map { entry -> (label: String, path: String) in
        guard let separator = entry.firstIndex(of: "=") else { fail("panel '\(entry)' is not LABEL=FONT") }
        return (String(entry[..<separator]), String(entry[entry.index(after: separator)...]))
    }
    contactSheet(output: arguments[1], textFile: arguments[2], panels: panels)
default:
    fail("usage: phase2r_tools load|layout-compare|iou|sheet ... (see the header of phase2r_tools.swift)")
}
