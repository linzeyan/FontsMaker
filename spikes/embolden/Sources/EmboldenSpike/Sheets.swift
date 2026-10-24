import CoreGraphics
import CoreText
import Foundation
import ImageIO

private struct SheetItem {
    var gid: CGGlyph
    var label: String
    var cp: UInt32?
}

private let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
private let faint = CGColor(srgbRed: 0.85, green: 0.85, blue: 0.88, alpha: 1)

private func loadItems(_ a: Args, _ src: LoadedFont) -> [SheetItem] {
    func auto(_ g: CGGlyph) -> SheetItem {
        let cp = src.charsByGlyph[Int(g)]?.first
        let ch = cp.flatMap { Unicode.Scalar($0) }.map { String(Character($0)) + " " } ?? ""
        return SheetItem(gid: g, label: "\(ch)\(src.name(g)) #\(g)", cp: cp)
    }
    if let list = a.opts["list"] {
        guard let text = try? String(contentsOfFile: list, encoding: .utf8) else { fail("read \(list)") }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let g = UInt16(parts[0]) else { return nil }
            var item = auto(g)
            if parts.count > 1, !parts[1].isEmpty { item.label = String(parts[1]) }
            return item
        }
    }
    var seen = Set<CGGlyph>()
    var items: [SheetItem] = []
    for s in a.str("chars").unicodeScalars {
        guard let g = src.glyph(for: s) else {
            print("warning: no glyph for U+\(String(format: "%04X", s.value)) \(s)")
            continue
        }
        if seen.insert(g).inserted { items.append(auto(g)) }
    }
    return items
}

func makeContext(_ w: Int, _ h: Int) -> CGContext {
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("cannot create \(w)x\(h) context") }
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx
}

func writePNG(_ ctx: CGContext, _ path: String) {
    guard let img = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                     "public.png" as CFString, 1, nil)
    else { fail("cannot write \(path)") }
    CGImageDestinationAddImage(dest, img, nil)
    if !CGImageDestinationFinalize(dest) { fail("finalize \(path)") }
    print("wrote \(path)")
}

func drawText(_ ctx: CGContext, _ s: String, x: CGFloat, y: CGFloat, size: CGFloat,
                      color: CGColor = black, bold: Bool = false) {
    let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, "zh-Hant" as CFString)!
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    ctx.saveGState()
    ctx.textMatrix = .identity
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

/// Maps font units into a square cell: x from -0.1 em, y from -0.22 em (just
/// below the -0.12 em descender), 1.2 em across, so every font shares one frame.
func withGlyphSpace(_ ctx: CGContext, _ cell: CGRect, upm: Int, window: CGRect? = nil,
                            _ body: (CGFloat) -> Void) {
    let em = CGFloat(upm)
    // An explicit window (font units) zooms into a corner or junction.
    let frame = window ?? CGRect(x: -0.1 * em, y: -0.22 * em, width: 1.2 * em, height: 1.2 * em)
    let s = cell.width / frame.width
    ctx.saveGState()
    ctx.clip(to: cell)
    ctx.translateBy(x: cell.minX - frame.minX * s, y: cell.minY - frame.minY * s)
    ctx.scaleBy(x: s, y: s)
    body(s)
    ctx.restoreGState()
}

func drawEmBox(_ ctx: CGContext, adv: Double, upm: Int, scale: CGFloat) {
    let em = CGFloat(upm)
    ctx.setStrokeColor(faint)
    ctx.setLineWidth(1 / scale)
    ctx.stroke(CGRect(x: 0, y: -0.12 * em, width: CGFloat(adv), height: em))
}

func runSheet(_ a: Args) {
    let src = LoadedFont(path: a.str("font"))
    let ref = a.opts["ref"].map { LoadedFont(path: $0) }
    let refByChar = a.str("ref-by", "gid") == "char"
    let weight = a.cg("weight", 12)
    let miter = EmboldenParams(weight: weight, join: .miter, miterLimit: a.cg("miter-limit", 4))
    let round = EmboldenParams(weight: weight, join: .round, miterLimit: 4)
    let items = loadItems(a, src)
    let cell = CGFloat(a.int("cell", 110))
    let groups = a.int("groups", 4)
    let perPage = a.int("per-page", 40)
    let columns = ["source", "ours \(miter.label)", "ours round", a.str("ref-label", "BailuKai Medium")]
    let gap: CGFloat = 3, groupGap: CGFloat = 30, margin: CGFloat = 24, labelH: CGFloat = 26, header: CGFloat = 64
    let groupW = 4 * cell + 3 * gap
    let W = Int(2 * margin + CGFloat(groups) * groupW + CGFloat(groups - 1) * groupGap)
    let pages = Swift.stride(from: 0, to: items.count, by: perPage).map { Array(items[$0..<min(items.count, $0 + perPage)]) }
    let title = a.str("title", "contact sheet")
    let out = a.str("out")

    for (pi, page) in pages.enumerated() {
        let rows = (page.count + groups - 1) / groups
        let H = Int(2 * margin + header + CGFloat(rows) * (cell + labelH + 10))
        let ctx = makeContext(W, H)
        let top = CGFloat(H) - margin
        let pageNote = pages.count > 1 ? "  (page \(pi + 1)/\(pages.count))" : ""
        drawText(ctx, title + pageNote, x: margin, y: top - 20, size: 18, bold: true)
        drawText(ctx, "columns per group: " + columns.joined(separator: "  |  ") + "   ·   weight \(Int(weight)) font units, faint box = advance × em",
                 x: margin, y: top - 44, size: 13)
        for (i, item) in page.enumerated() {
            let gx = margin + CGFloat(i % groups) * (groupW + groupGap)
            let gyTop = top - header - CGFloat(i / groups) * (cell + labelH + 10)
            var paths: [CGPath?] = [nil, nil, nil, nil]
            var refAdv = src.advance(item.gid)
            if let p = src.outline(item.gid), !p.isEmpty {
                paths[0] = p
                paths[1] = embolden(p, miter).bold
                paths[2] = embolden(p, round).bold
            }
            if let ref {
                let rg: CGGlyph? = refByChar ? item.cp.flatMap { Unicode.Scalar($0) }.flatMap { ref.glyph(for: $0) } : item.gid
                if let rg, let rp = ref.outline(rg) { paths[3] = rp; refAdv = ref.advance(rg) }
            }
            for col in 0..<4 {
                let rect = CGRect(x: gx + CGFloat(col) * (cell + gap), y: gyTop - cell, width: cell, height: cell)
                ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1))
                ctx.fill(rect)
                withGlyphSpace(ctx, rect, upm: src.upm) { s in
                    drawEmBox(ctx, adv: col == 3 ? refAdv : src.advance(item.gid), upm: src.upm, scale: s)
                    if let p = paths[col] {
                        ctx.addPath(p)
                        ctx.setFillColor(black)
                        ctx.fillPath(using: .winding)
                    }
                }
            }
            drawText(ctx, item.label, x: gx, y: gyTop - cell - 17, size: 12)
        }
        writePNG(ctx, pages.count > 1 ? "\(out)-p\(pi + 1).png" : "\(out).png")
    }
}

/// Large single cells: reference fill in gray, our outline in red, source
/// outline in thin blue — makes thickness and corner shape differences visible.
func runOverlay(_ a: Args) {
    let src = LoadedFont(path: a.str("font"))
    let ref = LoadedFont(path: a.str("ref"))
    let params = EmboldenParams(weight: a.cg("weight", 12), join: parseJoin(a.str("join", "miter")),
                                miterLimit: a.cg("miter-limit", 4))
    let items = loadItems(a, src)
    let cell = CGFloat(a.int("cell", 380))
    let groups = a.int("groups", 4)
    let window: CGRect? = a.opts["window"].map {
        let v = $0.split(separator: ",").compactMap { Double($0) }
        guard v.count == 3 else { fail("--window expects x,y,size") }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[2])
    }
    let compare = a.opts["compare-join"].map {
        EmboldenParams(weight: params.weight, join: parseJoin($0), miterLimit: params.miterLimit)
    }
    let gap: CGFloat = 16, margin: CGFloat = 24, labelH: CGFloat = 24, header: CGFloat = 64
    let rows = (items.count + groups - 1) / groups
    let W = Int(2 * margin + CGFloat(groups) * cell + CGFloat(groups - 1) * gap)
    let H = Int(2 * margin + header + CGFloat(rows) * (cell + labelH + 8))
    let ctx = makeContext(W, H)
    let top = CGFloat(H) - margin
    drawText(ctx, a.str("title", "overlay"), x: margin, y: top - 20, size: 18, bold: true)
    let extra = compare.map { ",  green = ours (\($0.label))" } ?? ""
    let win = window.map { String(format: ",  window x %.0f y %.0f size %.0f u", $0.minX, $0.minY, $0.width) } ?? ""
    drawText(ctx, "gray fill = \(a.str("ref-label", "BailuKai Medium")),  red line = ours (\(params.label), weight \(Int(params.weight))),  thin blue = source\(extra)\(win)",
             x: margin, y: top - 44, size: 13)
    for (i, item) in items.enumerated() {
        let x = margin + CGFloat(i % groups) * (cell + gap)
        let yTop = top - header - CGFloat(i / groups) * (cell + labelH + 8)
        let rect = CGRect(x: x, y: yTop - cell, width: cell, height: cell)
        ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.98, blue: 0.98, alpha: 1))
        ctx.fill(rect)
        withGlyphSpace(ctx, rect, upm: src.upm, window: window) { s in
            if let rp = ref.outline(item.gid) {
                ctx.addPath(rp)
                ctx.setFillColor(CGColor(srgbRed: 0.72, green: 0.72, blue: 0.72, alpha: 1))
                ctx.fillPath(using: .winding)
            }
            guard let p = src.outline(item.gid), !p.isEmpty else { return }
            ctx.addPath(p)
            ctx.setStrokeColor(CGColor(srgbRed: 0.1, green: 0.35, blue: 1, alpha: 0.9))
            ctx.setLineWidth(0.8 / s)
            ctx.strokePath()
            if let compare {
                ctx.addPath(embolden(p, compare).bold)
                ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0.6, blue: 0.2, alpha: 1))
                ctx.setLineWidth(1.3 / s)
                ctx.strokePath()
            }
            ctx.addPath(embolden(p, params).bold)
            ctx.setStrokeColor(CGColor(srgbRed: 0.9, green: 0, blue: 0, alpha: 1))
            ctx.setLineWidth(1.3 / s)
            ctx.strokePath()
        }
        drawText(ctx, item.label, x: x, y: yTop - cell - 17, size: 13)
    }
    writePNG(ctx, a.str("out") + ".png")
}
