"""Find BailuKai glyphs whose outlines were copied from LXGW WenKai Medium.

BailuKai's README says fragile glyphs were excluded from changeWeight(12) and
replaced by the LXGW WenKai Medium outline. Those glyphs are a human-labeled
"emboldening breaks this" set, which is what risk thresholds should catch.
Usage: python3 -I probe_injected.py BAILU.ttf LXGW_MEDIUM.ttf OUT_TSV
"""

import sys

from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.ttLib import TTFont


def outline(font, gs, name):
    pen = DecomposingRecordingPen(gs)
    gs[name].draw(pen)
    return pen.value


def main():
    bailu, lx, out = TTFont(sys.argv[1]), TTFont(sys.argv[2]), sys.argv[3]
    bgs, lgs = bailu.getGlyphSet(), lx.getGlyphSet()
    bcmap, lcmap = bailu.getBestCmap(), lx.getBestCmap()
    border = bailu.getGlyphOrder()
    exact, shifted = [], []
    seen = set()
    for cp, bname in sorted(bcmap.items()):
        if bname in seen or cp not in lcmap:
            continue
        seen.add(bname)
        bo, lo = outline(bailu, bgs, bname), outline(lx, lgs, lcmap[cp])
        if not bo or not lo:
            continue
        if bo == lo:
            exact.append((border.index(bname), bname, chr(cp)))
            continue
        # Same structure but translated (e.g. re-centered into a different advance)?
        if len(bo) == len(lo) and all(a[0] == b[0] for a, b in zip(bo, lo)):
            # qCurveTo may carry None for an all-off-curve contour.
            pa = [p for op, args in bo for p in args if p is not None]
            pb = [p for op, args in lo for p in args if p is not None]
            if pa and len(pa) == len(pb):
                dx, dy = pa[0][0] - pb[0][0], pa[0][1] - pb[0][1]
                if all(abs(a[0] - b[0] - dx) <= 1 and abs(a[1] - b[1] - dy) <= 1 for a, b in zip(pa, pb)):
                    shifted.append((border.index(bname), bname, chr(cp)))
    with open(out, "w") as f:
        for gid, name, ch in exact + shifted:
            f.write(f"{gid}\t{name}\t{ch}\n")
    print("exact copies:", len(exact), "".join(c for _, _, c in exact))
    print("translated copies:", len(shifted), "".join(c for _, _, c in shifted))


main()
