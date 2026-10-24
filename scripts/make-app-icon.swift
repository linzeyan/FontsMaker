// Writes App/Resources/AppIcon.icon, the Icon Composer document the app
// targets use: 永 in 原俠正楷, its left half as the source draws it and its
// right half emboldened, split by a rule — the 原字／成品 comparison the app
// is built around. Layers are PNGs drawn here, so the glyph comes from the
// font itself rather than a hand-traced copy.
//
// Usage:   swift scripts/make-app-icon.swift   (from the repo root)
// Needs:   GuanKiapTsingKhai.ttf in ~/Library/Caches/FontsMaker/fixtures
//          (scripts/fetch-fixtures.sh puts it there).
// Preview: ictool (inside Icon Composer.app in Xcode) renders it, e.g.
//          ictool App/Resources/AppIcon.icon --export-image --output-file x.png
//            --platform iOS --rendition Default --width 512 --height 512 --scale 1

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas = 1024
let font = NSHomeDirectory() + "/Library/Caches/FontsMaker/fixtures/GuanKiapTsingKhai.ttf"
let document = URL(fileURLWithPath: "App/Resources/AppIcon.icon")

func glyph(_ character: String, size: CGFloat) -> CGPath {
    guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: font) as CFURL)
        as? [CTFontDescriptor], let descriptor = descriptors.first
    else { fatalError("missing \(font); run scripts/fetch-fixtures.sh") }
    let ctFont = CTFontCreateWithFontDescriptor(descriptor, size, nil)
    var units = Array(character.utf16)
    var glyphs = [CGGlyph](repeating: 0, count: units.count)
    guard CTFontGetGlyphsForCharacters(ctFont, &units, &glyphs, units.count),
        let path = CTFontCreatePathForGlyph(ctFont, glyphs[0], nil)
    else { fatalError("\(character) not in the font") }
    // Centred by ink, not by advance: the icon has no baseline to sit on.
    let box = path.boundingBoxOfPath
    var centre = CGAffineTransform(
        translationX: CGFloat(canvas) / 2 - box.midX, y: CGFloat(canvas) / 2 - box.midY)
    return path.copy(using: &centre)!
}

func white(_ alpha: CGFloat = 1) -> CGColor { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha) }

func writeLayer(_ name: String, _ draw: (CGContext) -> Void) {
    let context = CGContext(
        data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(context)
    let url = document.appendingPathComponent("Assets/\(name).png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(url.path)") }
}

try? FileManager.default.removeItem(at: document)
try FileManager.default.createDirectory(
    at: document.appendingPathComponent("Assets"), withIntermediateDirectories: true)

let yong = glyph("永", size: 700)
let half = CGFloat(canvas) / 2

writeLayer("thin") { context in
    context.clip(to: CGRect(x: 0, y: 0, width: half, height: CGFloat(canvas)))
    context.addPath(yong)
    // Dimmed so the emboldened half reads as the result.
    context.setFillColor(white(0.55))
    context.fillPath()
}
writeLayer("bold") { context in
    context.clip(to: CGRect(x: half, y: 0, width: half, height: CGFloat(canvas)))
    context.addPath(yong)
    // A stroke in the fill colour thickens every stroke evenly, as 加粗 does.
    context.setFillColor(white())
    context.setStrokeColor(white())
    context.setLineWidth(34)
    context.setLineJoin(.round)
    context.drawPath(using: .fillStroke)
}
writeLayer("rule") { context in
    context.setFillColor(CGColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 1))
    context.fill(CGRect(x: half - 6, y: 150, width: 12, height: 724))
}

func group(_ layer: String, translucency: Double) -> [String: Any] {
    [
        "name": layer,
        "layers": [["image-name": "\(layer).png", "name": layer]],
        "shadow": ["kind": "neutral", "opacity": 0.5],
        "translucency": ["enabled": true, "value": translucency],
    ]
}

let json: [String: Any] = [
    "fill": [
        "linear-gradient": [
            "extended-srgb:0.10196,0.23137,0.47843,1.00000",
            "extended-srgb:0.03922,0.09804,0.23529,1.00000",
        ],
        "orientation": ["start": ["x": 0.5, "y": 0], "stop": ["x": 0.5, "y": 1]],
    ],
    // First group is frontmost.
    "groups": [
        group("rule", translucency: 0.4), group("bold", translucency: 0.4), group("thin", translucency: 0.6),
    ],
    "supported-platforms": ["squares": "shared"],
]
let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
try data.write(to: document.appendingPathComponent("icon.json"))
print("wrote \(document.path)")
