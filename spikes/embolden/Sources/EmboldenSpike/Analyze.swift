import CoreGraphics
import Foundation

struct Row {
    var cells: [(String, String)] = []
    mutating func add(_ k: String, _ v: Int) { cells.append((k, String(v))) }
    mutating func add(_ k: String, _ v: String) { cells.append((k, v)) }
    mutating func add(_ k: String, _ v: Double, _ digits: Int = 3) {
        cells.append((k, v.isFinite ? String(format: "%.\(digits)f", v) : ""))
    }
}

private func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

private func ratio(_ a: Double, _ b: Double) -> Double { b > 0 ? a / b : .nan }

private func analyzeGlyph(_ g: CGGlyph, src: LoadedFont, ref: LoadedFont?, p: EmboldenParams,
                          raster: Raster) -> Row {
    var r = Row()
    r.add("gid", Int(g))
    r.add("name", src.name(g))
    let cps = src.charsByGlyph[Int(g)] ?? []
    r.add("cp", cps.first.map { String(format: "%04X", $0) } ?? "")
    r.add("ncodes", cps.count)
    r.add("adv", src.advance(g), 0)
    guard let raw = src.outline(g), !raw.isEmpty else {
        r.add("src_empty", 1)
        return r
    }
    r.add("src_empty", 0)

    // Raw source: may contain overlapping contours, so only count, never classify.
    let rawCs = flattenContours(raw)
    r.add("src_raw_contours", rawCs.count)
    r.add("src_raw_crossings", properCrossings(rawCs).count)
    let rawNZ = raster.render([raw], .winding)
    r.add("src_overlap_px", mismatch(rawNZ, raster.render([raw], .evenOdd)))
    let rawDom = rawCs.max(by: { abs($0.area) < abs($1.area) })
    r.add("src_dir", (rawDom?.area ?? 0) > 0 ? 1 : -1)

    // "Before" metrics come from the normalized source so overlapping strokes
    // that enclose a counter are measured the same way as the union output.
    let s = OutlineStats(raw.normalized(using: .winding))
    let sSeg = segCounts(raw)
    r.add("src_contours", s.contours.count)
    r.add("src_outer", s.outer.count)
    r.add("src_holes", s.holes.count)
    r.add("src_tiny", s.tiny)
    r.add("src_hole_area", s.holeArea, 1)
    r.add("src_area", s.filledArea, 1)
    r.add("src_perim", s.perimeter, 1)
    r.add("src_xmin", Double(s.bbox.minX), 2); r.add("src_ymin", Double(s.bbox.minY), 2)
    r.add("src_xmax", Double(s.bbox.maxX), 2); r.add("src_ymax", Double(s.bbox.maxY), 2)
    r.add("src_points", sSeg.points)
    r.add("src_lines", sSeg.lines); r.add("src_quads", sSeg.quads); r.add("src_cubics", sSeg.cubics)

    let t0 = nowNs()
    let stroke = raw.copy(strokingWithWidth: p.weight, lineCap: .butt, lineJoin: p.join,
                          miterLimit: p.miterLimit)
    let t1 = nowNs()
    let bold = raw.union(stroke, using: .winding)
    let t2 = nowNs()
    r.add("t_stroke_us", Double(t1 - t0) / 1000, 1)
    r.add("t_union_us", Double(t2 - t1) / 1000, 1)

    let b = OutlineStats(bold)
    let bSeg = segCounts(bold)
    r.add("b_empty", b.empty ? 1 : 0)
    r.add("b_contours", b.contours.count)
    r.add("b_outer", b.outer.count)
    r.add("b_holes", b.holes.count)
    r.add("b_debris", b.debris)
    r.add("b_tiny", b.tiny)
    r.add("b_small", b.small)
    r.add("b_hole_area", b.holeArea, 1)
    r.add("b_area", b.filledArea, 1)
    r.add("b_xmin", Double(b.bbox.minX), 2); r.add("b_ymin", Double(b.bbox.minY), 2)
    r.add("b_xmax", Double(b.bbox.maxX), 2); r.add("b_ymax", Double(b.bbox.maxY), 2)
    r.add("b_points", bSeg.points)
    r.add("b_lines", bSeg.lines); r.add("b_quads", bSeg.quads); r.add("b_cubics", bSeg.cubics)
    r.add("b_dir", Int(b.dominantSign))
    r.add("b_crossings", properCrossings(b.contours).count)

    let m = matchHoles(before: s.holes, after: b.holes)
    let w = Double(p.weight)
    // New counters (strokes merging around a gap) would inflate the ratio and
    // mask shrinking ones, so the headline ratio only counts surviving counters.
    r.add("hole_area_ratio", ratio(m.matchedArea, s.holeArea), 4)
    r.add("hole_area_ratio_all", ratio(b.holeArea, s.holeArea), 4)
    r.add("min_hole_ratio", m.minRatio, 4)
    r.add("holes_vanished", m.vanished)
    r.add("src_sliver_holes", m.slivers)
    r.add("holes_new", m.new)
    r.add("new_hole_min_area", m.newMinArea, 1)
    r.add("src_min_hole_area", s.holes.map { abs($0.area) }.min() ?? .nan, 1)
    r.add("b_min_hole_area", b.holes.map { abs($0.area) }.min() ?? .nan, 1)
    r.add("holes_split", m.split)
    r.add("contour_delta", b.contours.count - s.contours.count)
    r.add("outer_delta", b.outer.count - s.outer.count)
    r.add("holes_delta", b.holes.count - s.holes.count)
    r.add("bbox_growth_w", Double(b.bbox.width - s.bbox.width) / w, 4)
    r.add("bbox_growth_h", Double(b.bbox.height - s.bbox.height) / w, 4)
    r.add("point_ratio", ratio(Double(bSeg.points), Double(sSeg.points)), 3)
    r.add("d_eff", ratio(b.filledArea - s.filledArea, s.perimeter), 3)

    let boldNZ = raster.render([bold], .winding)
    r.add("union_mismatch_px", mismatch(boldNZ, raster.render([raw, stroke], .winding)))
    r.add("self_overlap_px", mismatch(boldNZ, raster.render([bold], .evenOdd)))

    // What survives integer rounding is what a TrueType file would contain.
    let q = quantized(bold)
    let qs = OutlineStats(q)
    r.add("q_contours", qs.contours.count)
    r.add("q_debris", qs.debris + qs.tiny)
    r.add("q_crossings", properCrossings(qs.contours).count)
    let qNZ = raster.render([q], .winding)
    r.add("q_self_overlap_px", mismatch(qNZ, raster.render([q], .evenOdd)))
    r.add("q_mismatch_px", mismatch(qNZ, boldNZ))

    if let ref, let refRaw = ref.outline(g), !refRaw.isEmpty {
        let rs = OutlineStats(refRaw.normalized(using: .winding))
        let rm = matchHoles(before: s.holes, after: rs.holes)
        r.add("r_raw_crossings", properCrossings(flattenContours(refRaw)).count)
        r.add("r_contours", rs.contours.count)
        r.add("r_holes", rs.holes.count)
        r.add("r_hole_area", rs.holeArea, 1)
        r.add("r_area", rs.filledArea, 1)
        r.add("r_xmin", Double(rs.bbox.minX), 2); r.add("r_ymin", Double(rs.bbox.minY), 2)
        r.add("r_xmax", Double(rs.bbox.maxX), 2); r.add("r_ymax", Double(rs.bbox.maxY), 2)
        r.add("r_d_eff", ratio(rs.filledArea - s.filledArea, s.perimeter), 3)
        r.add("r_hole_area_ratio", ratio(rm.matchedArea, s.holeArea), 4)
        r.add("r_min_hole_ratio", rm.minRatio, 4)
        r.add("r_holes_vanished", rm.vanished)
        r.add("r_bbox_growth_w", Double(rs.bbox.width - s.bbox.width) / w, 4)
        r.add("r_bbox_growth_h", Double(rs.bbox.height - s.bbox.height) / w, 4)
        let refNZ = raster.render([refRaw], .winding)
        r.add("r_overlap_px", mismatch(refNZ, raster.render([refRaw], .evenOdd)))
        r.add("iou_src_ref", iou(rawNZ, refNZ), 4)
        r.add("iou_bold_ref", iou(boldNZ, refNZ), 4)
        r.add("area_ratio_bold_ref", ratio(b.filledArea, rs.filledArea), 4)
    }
    return r
}

func selectGlyphs(_ a: Args, _ font: LoadedFont) -> [CGGlyph] {
    if let chars = a.opts["chars"] {
        var seen = Set<CGGlyph>()
        return chars.unicodeScalars.compactMap { font.glyph(for: $0) }.filter { seen.insert($0).inserted }
    }
    let n = min(font.glyphCount, a.int("limit", font.glyphCount))
    return (0..<n).map { CGGlyph($0) }
}

func runAnalyze(_ a: Args) {
    let src = LoadedFont(path: a.str("font"))
    let ref = a.opts["ref"].map { LoadedFont(path: $0) }
    let params = EmboldenParams(weight: a.cg("weight", 12), join: parseJoin(a.str("join", "miter")),
                                miterLimit: a.cg("miter-limit", 4))
    let gids = selectGlyphs(a, src)
    print("font \(src.path): upm \(src.upm), glyphs \(src.glyphCount), cmap chars \(src.glyphByChar.count)")
    if let ref {
        let mismatched = (0..<min(src.glyphCount, ref.glyphCount)).filter {
            src.name(CGGlyph($0)) != ref.name(CGGlyph($0))
        }.count
        print("ref \(ref.path): glyphs \(ref.glyphCount), glyph-name mismatches by gid: \(mismatched)")
    }
    print("params weight \(params.weight) join \(params.label) — analyzing \(gids.count) glyphs")

    var rows = [Row](repeating: Row(), count: gids.count)
    let chunk = 32
    let nChunks = (gids.count + chunk - 1) / chunk
    let t0 = nowNs()
    rows.withUnsafeMutableBufferPointer { buf in
        DispatchQueue.concurrentPerform(iterations: nChunks) { c in
            let raster = Raster()
            for i in (c * chunk)..<min(gids.count, (c + 1) * chunk) {
                buf[i] = autoreleasepool { analyzeGlyph(gids[i], src: src, ref: ref, p: params, raster: raster) }
            }
        }
    }
    let wall = Double(nowNs() - t0) / 1e9
    print(String(format: "analysis wall time %.1f s on %d cores (includes metrics + rasters)",
                 wall, ProcessInfo.processInfo.activeProcessorCount))

    let header = rows.max(by: { $0.cells.count < $1.cells.count })!.cells.map { $0.0 }
    var text = header.joined(separator: ",") + "\n"
    for row in rows {
        let d = Dictionary(row.cells, uniquingKeysWith: { a, _ in a })
        text += header.map { d[$0] ?? "" }.joined(separator: ",") + "\n"
    }
    let out = a.str("out")
    do { try text.write(toFile: out, atomically: true, encoding: .utf8) } catch { fail("write \(out): \(error)") }
    print("wrote \(out)")
}

/// Debug aid: prints every contour of the bold outline plus the raw path
/// elements of tiny contours, to tell real geometry defects from metric noise.
func runDump(_ a: Args) {
    let src = LoadedFont(path: a.str("font"))
    let params = EmboldenParams(weight: a.cg("weight", 12), join: parseJoin(a.str("join", "miter")),
                                miterLimit: a.cg("miter-limit", 4))
    for g in a.str("gids").split(separator: ",").compactMap({ CGGlyph($0) }) {
        guard let raw = src.outline(g) else { continue }
        let floatBold = embolden(raw, params).bold
        let bold = a.int("quantize", 0) == 1 ? quantized(floatBold) : floatBold
        let cs = flattenContours(bold)
        let xs = properCrossings(cs)
        print("gid \(g) \(src.name(g)): \(cs.count) contours, crossings \(xs.count)")
        for x in xs {
            print(String(format: "  crossing at (%.3f, %.3f) contours %d/%d", x.at.x, x.at.y, x.c1, x.c2))
            // Print the bold-path elements around the crossing, with their
            // index, to see whether it is a real loop or a flattening artifact.
            var k = 0
            var last = CGPoint.zero
            bold.applyWithBlock { el in
                let e = el.pointee
                let n: Int
                switch e.type {
                case .moveToPoint, .addLineToPoint: n = 1
                case .addQuadCurveToPoint: n = 2
                case .addCurveToPoint: n = 3
                default: n = 0
                }
                let pts = (0..<n).map { e.points[$0] }
                if let end = pts.last {
                    if hypot(end.x - x.at.x, end.y - x.at.y) < 12 || hypot(last.x - x.at.x, last.y - x.at.y) < 12 {
                        print("    el \(k) type \(e.type.rawValue) from " + String(format: "%.3f,%.3f", last.x, last.y)
                              + " pts " + pts.map { String(format: "%.3f,%.3f", $0.x, $0.y) }.joined(separator: " "))
                    }
                    last = end
                }
                k += 1
            }
        }
        for (i, c) in cs.enumerated() {
            print(String(format: "  #%d area %.3f perim %.2f pts %d bbox (%.2f,%.2f)-(%.2f,%.2f)", i, c.area,
                         c.perimeter, c.pts.count, c.bbox.minX, c.bbox.minY, c.bbox.maxX, c.bbox.maxY))
        }
        var sub: [String] = []
        var idx = 0
        func flush() {
            if !sub.isEmpty, idx < cs.count, abs(cs[idx].area) < OutlineStats.tinyArea {
                print("  tiny #\(idx): " + sub.joined(separator: " "))
            }
            if !sub.isEmpty { idx += 1 }
            sub.removeAll()
        }
        bold.applyWithBlock { el in
            let e = el.pointee
            func p(_ k: Int) -> String { String(format: "%.3f,%.3f", e.points[k].x, e.points[k].y) }
            switch e.type {
            case .moveToPoint: flush(); sub.append("M" + p(0))
            case .addLineToPoint: sub.append("L" + p(0))
            case .addQuadCurveToPoint: sub.append("Q" + p(0) + " " + p(1))
            case .addCurveToPoint: sub.append("C" + p(0) + " " + p(1) + " " + p(2))
            case .closeSubpath: sub.append("Z")
            @unknown default: break
            }
        }
        flush()
    }
}
