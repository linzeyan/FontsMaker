"""Cross-check facts about the source and reference fonts with fontTools.

Answers, independently of CoreText: do source and BailuKai share glyph order,
which glyphs BailuKai left untouched (its hand-made skip list), and how its
bbox / advance / position moved relative to the source.
Usage: python3 -I probe_reference.py SRC.ttf REF.ttf OUT_DIR
"""

import statistics
import sys
from pathlib import Path

from fontTools.ttLib import TTFont


def glyph_key(glyf, name):
    g = glyf[name]
    if g.isComposite():
        return ("comp", tuple((c.glyphName, c.x, c.y) for c in g.components))
    if g.numberOfContours == 0:
        return ("empty",)
    coords, ends, flags = g.getCoordinates(glyf)
    return ("simple", tuple(coords), tuple(ends), tuple(f & 1 for f in flags))


def pct(vals, p):
    vals = sorted(vals)
    return vals[min(len(vals) - 1, int(p / 100 * len(vals)))]


def main():
    src_path, ref_path, out_dir = sys.argv[1], sys.argv[2], Path(sys.argv[3])
    src, ref = TTFont(src_path), TTFont(ref_path)
    so, ro = src.getGlyphOrder(), ref.getGlyphOrder()
    print("glyphs", len(so), len(ro), "same order:", so == ro)
    scmap, rcmap = src.getBestCmap(), ref.getBestCmap()
    print("cmap sizes", len(scmap), len(rcmap), "same:", scmap == rcmap)
    sglyf, rglyf = src["glyf"], ref["glyf"]
    shmtx, rhmtx = src["hmtx"], ref["hmtx"]
    rev = {}
    for cp, name in scmap.items():
        rev.setdefault(name, []).append(cp)

    identical, dw, dx, dxmax, dymin, dymax, adv = [], [], [], [], [], [], []
    for name in so:
        ks, kr = glyph_key(sglyf, name), glyph_key(rglyf, name)
        if ks == kr:
            if ks[0] != "empty":
                identical.append(name)
            continue
        gs, gr = sglyf[name], rglyf[name]
        gs.recalcBounds(sglyf)
        gr.recalcBounds(rglyf)
        if gs.numberOfContours == 0 or gr.numberOfContours == 0:
            continue
        dx.append(gr.xMin - gs.xMin)
        dxmax.append(gr.xMax - gs.xMax)
        dymin.append(gr.yMin - gs.yMin)
        dymax.append(gr.yMax - gs.yMax)
        dw.append((gr.xMax - gr.xMin) - (gs.xMax - gs.xMin))
        adv.append(rhmtx[name][0] - shmtx[name][0])

    print("non-empty glyphs identical in ref:", len(identical))
    lines = []
    for name in identical:
        chars = "".join(chr(c) for c in rev.get(name, []))
        lines.append(f"{so.index(name)}\t{name}\t{chars}")
    (out_dir / "ref-identical-glyphs.tsv").write_text("\n".join(lines) + "\n")
    print("  first 40:", [l.split("\t")[2] or l.split("\t")[1] for l in lines[:40]])
    for label, v in [("xMin shift", dx), ("xMax shift", dxmax), ("yMin shift", dymin),
                     ("yMax shift", dymax), ("width growth", dw), ("advance change", adv)]:
        print(f"{label:15s} n={len(v)} median={statistics.median(v)} p5={pct(v,5)} p95={pct(v,95)}")
    for ch in "一永傳導育國的Ag。":
        name = scmap.get(ord(ch))
        gs, gr = sglyf[name], rglyf[name]
        gs.recalcBounds(sglyf)
        gr.recalcBounds(rglyf)
        print(ch, name, so.index(name), "src bbox", (gs.xMin, gs.yMin, gs.xMax, gs.yMax),
              "ref bbox", (gr.xMin, gr.yMin, gr.xMax, gr.yMax),
              "adv", shmtx[name][0], rhmtx[name][0],
              "contours", gs.numberOfContours, gr.numberOfContours)


main()
