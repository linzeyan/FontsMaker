import CoreGraphics
import CoreText
import Foundation

// Phase 2E acceptance: checks the font file written by `fontsmaker embolden`,
// read back through CoreText, so the engine's own reader and metrics are not
// the judge of their output. Compares it with BailuKai Medium (by glyph ID) and
// with this spike's float result (the cost of cu2qu + rounding).

/// CoreText must accept the bytes the way an app would load them.
private func coreTextLoads(_ path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path) else { return "cannot read \(path)" }
    guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
        let descriptor = descriptors.first
    else { return "CTFontManagerCreateFontDescriptorsFromData returned no descriptor" }
    let font = CTFontCreateWithFontDescriptor(descriptor, 1000, nil)
    guard CTFontGetGlyphCount(font) > 0 else { return "CoreText font has no glyphs" }
    return nil
}

/// Outer contours must be clockwise and holes counter-clockwise (y up), the
/// TrueType convention. Depth = how many other contours contain a probe point
/// at the middle of the contour's longest edge; even depth means outer.
private func misorientedContours(_ cs: [Contour]) -> Int {
    var bad = 0
    for (i, c) in cs.enumerated() {
        var best = (0, 0.0)
        for k in c.pts.indices {
            let a = c.pts[k], b = c.pts[(k + 1) % c.pts.count]
            let len = Double(hypot(b.x - a.x, b.y - a.y))
            if len > best.1 { best = (k, len) }
        }
        let a = c.pts[best.0], b = c.pts[(best.0 + 1) % c.pts.count]
        let probe = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        var depth = 0
        for (j, d) in cs.enumerated() where j != i && d.bbox.contains(probe) && pointInPolygon(d.pts, probe) {
            depth += 1
        }
        let outer = depth % 2 == 0
        if outer ? c.area >= 0 : c.area <= 0 { bad += 1 }
    }
    return bad
}

private func analyzeFinal(_ g: CGGlyph, final fin: LoadedFont, src: LoadedFont, ref: LoadedFont, p: EmboldenParams,
                          raster: Raster) -> Row {
    var r = Row()
    r.add("gid", Int(g))
    let cps = src.charsByGlyph[Int(g)] ?? []
    r.add("cp", cps.first.map { String(format: "%04X", $0) } ?? "")
    let raw = src.outline(g)
    let out = fin.outline(g)
    let srcEmpty = raw?.isEmpty ?? true
    let outEmpty = out?.isEmpty ?? true
    r.add("src_empty", srcEmpty ? 1 : 0)
    r.add("out_empty", outEmpty ? 1 : 0)
    r.add("adv_src", src.advance(g), 0)
    r.add("adv_out", fin.advance(g), 0)
    guard let raw, let out, !srcEmpty, !outEmpty else { return r }

    let outNZ = raster.render([out], .winding)
    r.add("nz_eo_px", mismatch(outNZ, raster.render([out], .evenOdd)))
    let floatBold = embolden(raw, p).bold
    let floatNZ = raster.render([floatBold], .winding)
    r.add("iou_final_float", iou(outNZ, floatNZ), 5)
    r.add("mismatch_final_float_px", mismatch(outNZ, floatNZ))
    if let refPath = ref.outline(g), !refPath.isEmpty {
        let refNZ = raster.render([refPath], .winding)
        r.add("iou_final_ref", iou(outNZ, refNZ), 5)
        r.add("iou_float_ref", iou(floatNZ, refNZ), 5)
    }

    let cs = flattenContours(out)
    r.add("contours", cs.count)
    r.add("misoriented", misorientedContours(cs))
    r.add("debris", cs.filter { max($0.bbox.width, $0.bbox.height) < OutlineStats.debrisExtent || abs($0.area) < OutlineStats.tinyArea }.count)
    let crossings = properCrossings(cs)
    r.add("crossings", crossings.count)
    if let first = crossings.first {
        r.add("cross_x", Double(first.at.x), 2)
        r.add("cross_y", Double(first.at.y), 2)
    }
    let floatCrossings = properCrossings(flattenContours(floatBold)).count
    r.add("float_crossings", floatCrossings)

    let s = OutlineStats(raw.normalized(using: .winding))
    let f = OutlineStats(out)
    let m = matchHoles(before: s.holes, after: f.holes)
    r.add("holes_vanished", m.vanished)
    r.add("min_hole_ratio", m.minRatio, 4)
    return r
}

func runFinal(_ a: Args) {
    let finalPath = a.str("final")
    if let problem = coreTextLoads(finalPath) { fail("CoreText rejects \(finalPath): \(problem)") }
    print("CoreText loads \(finalPath) via CTFontManagerCreateFontDescriptorsFromData")
    let fin = LoadedFont(path: finalPath)
    let src = LoadedFont(path: a.str("src"))
    let ref = LoadedFont(path: a.str("ref"))
    guard fin.glyphCount == src.glyphCount else { fail("glyph count \(fin.glyphCount) != source \(src.glyphCount)") }
    let params = EmboldenParams(weight: a.cg("weight", 12), join: .miter, miterLimit: a.cg("miter-limit", 4))
    let n = fin.glyphCount
    var rows = [Row](repeating: Row(), count: n)
    let chunk = 32
    rows.withUnsafeMutableBufferPointer { buf in
        DispatchQueue.concurrentPerform(iterations: (n + chunk - 1) / chunk) { c in
            let raster = Raster()
            for i in (c * chunk)..<min(n, (c + 1) * chunk) {
                buf[i] = autoreleasepool { analyzeFinal(CGGlyph(i), final: fin, src: src, ref: ref, p: params, raster: raster) }
            }
        }
    }
    let header = rows.max(by: { $0.cells.count < $1.cells.count })!.cells.map { $0.0 }
    var text = header.joined(separator: ",") + "\n"
    for row in rows {
        let d = Dictionary(row.cells, uniquingKeysWith: { a, _ in a })
        text += header.map { d[$0] ?? "" }.joined(separator: ",") + "\n"
    }
    let out = a.str("out")
    do { try text.write(toFile: out, atomically: true, encoding: .utf8) } catch { fail("write \(out): \(error)") }
    print("wrote \(out) (\(n) glyphs)")
}

/// Sheet columns: source | final font (ours) | reference, by glyph ID. Every
/// column reads a font file, so it shows what ships.
func runFinalSheet(_ a: Args) {
    let fin = LoadedFont(path: a.str("final"))
    let src = LoadedFont(path: a.str("src"))
    let ref = LoadedFont(path: a.str("ref"))
    var items: [(CGGlyph, String)] = []
    for s in a.str("chars").unicodeScalars {
        guard let g = src.glyph(for: s) else { fail("no glyph for \(s)") }
        items.append((g, "\(s) #\(g)"))
    }
    let columns = ["source", "final (ours)", a.str("ref-label", "BailuKai Medium")]
    let cell = CGFloat(a.int("cell", 260))
    let gap: CGFloat = 4, groupGap: CGFloat = 30, margin: CGFloat = 24, labelH: CGFloat = 28, header: CGFloat = 64
    let groups = a.int("groups", 2)
    let groupW = 3 * cell + 2 * gap
    let rows = (items.count + groups - 1) / groups
    let W = Int(2 * margin + CGFloat(groups) * groupW + CGFloat(groups - 1) * groupGap)
    let H = Int(2 * margin + header + CGFloat(rows) * (cell + labelH + 8))
    let ctx = makeContext(W, H)
    let top = CGFloat(H) - margin
    drawText(ctx, a.str("title", "final font"), x: margin, y: top - 20, size: 18, bold: true)
    drawText(ctx, "columns per group: " + columns.joined(separator: "  |  "), x: margin, y: top - 44, size: 13)
    for (i, item) in items.enumerated() {
        let gx = margin + CGFloat(i % groups) * (groupW + groupGap)
        let gyTop = top - header - CGFloat(i / groups) * (cell + labelH + 8)
        for (col, font) in [src, fin, ref].enumerated() {
            let rect = CGRect(x: gx + CGFloat(col) * (cell + gap), y: gyTop - cell, width: cell, height: cell)
            ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1))
            ctx.fill(rect)
            withGlyphSpace(ctx, rect, upm: src.upm) { s in
                drawEmBox(ctx, adv: font.advance(item.0), upm: src.upm, scale: s)
                if let p = font.outline(item.0) {
                    ctx.addPath(p)
                    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
                    ctx.fillPath(using: .winding)
                }
            }
        }
        drawText(ctx, item.1, x: gx, y: gyTop - cell - 18, size: 13)
    }
    writePNG(ctx, a.str("out") + ".png")
}

/// Zoomed views of residual crossings in the final font: gray fill, red
/// outline with its vertices, a 24-unit window centred on the crossing.
func runCrossingZoom(_ a: Args) {
    let fin = LoadedFont(path: a.str("final"))
    guard let text = try? String(contentsOfFile: a.str("list"), encoding: .utf8) else { fail("read list") }
    let items: [(CGGlyph, CGPoint, String)] = text.split(separator: "\n").compactMap { line in
        let f = line.split(separator: "\t")
        guard f.count >= 4, let g = UInt16(f[0]), let x = Double(f[1]), let y = Double(f[2]) else { return nil }
        return (g, CGPoint(x: x, y: y), String(f[3]))
    }
    let size = CGFloat(a.int("window", 24))
    let cell = CGFloat(a.int("cell", 300))
    let groups = a.int("groups", 4)
    let gap: CGFloat = 12, margin: CGFloat = 24, labelH: CGFloat = 24, header: CGFloat = 56
    let rows = max(1, (items.count + groups - 1) / groups)
    let W = Int(2 * margin + CGFloat(groups) * cell + CGFloat(groups - 1) * gap)
    let H = Int(2 * margin + header + CGFloat(rows) * (cell + labelH + 8))
    let ctx = makeContext(W, H)
    let top = CGFloat(H) - margin
    drawText(ctx, a.str("title", "crossings"), x: margin, y: top - 20, size: 18, bold: true)
    drawText(ctx, "window \(Int(size)) units centred on the first crossing; gray = fill (nonzero), red = outline, dots = points",
             x: margin, y: top - 42, size: 13)
    for (i, item) in items.enumerated() {
        let x = margin + CGFloat(i % groups) * (cell + gap)
        let yTop = top - header - CGFloat(i / groups) * (cell + labelH + 8)
        let rect = CGRect(x: x, y: yTop - cell, width: cell, height: cell)
        ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.98, blue: 0.98, alpha: 1))
        ctx.fill(rect)
        let window = CGRect(x: item.1.x - size / 2, y: item.1.y - size / 2, width: size, height: size)
        withGlyphSpace(ctx, rect, upm: fin.upm, window: window) { s in
            guard let p = fin.outline(item.0) else { return }
            ctx.addPath(p)
            ctx.setFillColor(CGColor(srgbRed: 0.75, green: 0.75, blue: 0.75, alpha: 1))
            ctx.fillPath(using: .winding)
            ctx.addPath(p)
            ctx.setStrokeColor(CGColor(srgbRed: 0.9, green: 0, blue: 0, alpha: 1))
            ctx.setLineWidth(1.5 / s)
            ctx.strokePath()
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0.8, alpha: 1))
            p.applyWithBlock { el in
                let e = el.pointee
                let n: Int
                switch e.type {
                case .moveToPoint, .addLineToPoint: n = 1
                case .addQuadCurveToPoint: n = 2
                case .addCurveToPoint: n = 3
                default: n = 0
                }
                for k in 0..<n {
                    let q = e.points[k]
                    ctx.fillEllipse(in: CGRect(x: q.x - 2.5 / s, y: q.y - 2.5 / s, width: 5 / s, height: 5 / s))
                }
            }
        }
        drawText(ctx, item.2, x: x, y: yTop - cell - 17, size: 13)
    }
    writePNG(ctx, a.str("out") + ".png")
}
