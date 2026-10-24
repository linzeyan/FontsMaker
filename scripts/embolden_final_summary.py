"""Summarize the final-font checks (spike `final` CSV + engine report CSV).

Reads only CSV/TSV files produced by our own tools, never fonts.
Usage:
  python3 -I embolden_final_summary.py FINAL_CSV REPORT_CSV INJECTED_TSV LISTS_DIR

Prints one PASS/FAIL line per acceptance check plus INFO lines, writes the
glyph lists the zoom sheets are drawn from, and exits 1 if any check fails.
"""

import csv
import math
import sys
from pathlib import Path

FINAL_CSV, REPORT_CSV, INJECTED_TSV, LISTS = sys.argv[1:5]
LISTS = Path(LISTS)
LISTS.mkdir(parents=True, exist_ok=True)
# Characters BailuKai replaced by hand with LXGW WenKai Medium (Phase 0 findings).
HAND_FIXED = "傳導帳熱繁聯育鬢"
# Phase 0 grade distribution on GuanKiapTsingKhai (technical design §5.2).
PHASE0 = {"A": 0.31, "B": 1.70, "C": 8.90}
# Phase 2E engine on the same font at weight 12 (`fontsmaker embolden`): the
# build runs the same engine on the same glyphs, so the counts must not move.
PHASE2E = {"A": 75, "B": 419, "C": 2245, "D": 22338}

failures = 0


def report(ok, name, detail=""):
    global failures
    if not ok:
        failures += 1
    print(f"{'PASS' if ok else 'FAIL'}  {name}{('  ' + detail) if detail else ''}")


def num(row, key):
    value = row.get(key, "")
    return float(value) if value not in ("", None) else math.nan


def percentile(values, p):
    values = sorted(values)
    if not values:
        return math.nan
    # Same nearest-rank-below rule as the spike's timing report.
    return values[min(len(values) - 1, int(p / 100 * len(values)))]


def char(row):
    return chr(int(row["cp"], 16)) if row.get("cp") else ""


rows = list(csv.DictReader(open(FINAL_CSV)))
injected = {line.split("\t")[0] for line in open(INJECTED_TSV).read().splitlines() if line}
by_gid = {r["gid"]: r for r in rows}
inked = [r for r in rows if r["src_empty"] == "0"]

# ---- structure ----------------------------------------------------------------
lost = [r["gid"] for r in inked if r["out_empty"] == "1"]
report(not lost, "every glyph with ink in the source has ink in the output", f"lost: {lost[:10]}" if lost else f"{len(inked)} glyphs")
gained = [r["gid"] for r in rows if r["src_empty"] == "1" and r["out_empty"] == "0"]
report(not gained, "empty source glyphs stay empty", f"gained: {gained[:10]}" if gained else "")
adv = [r["gid"] for r in rows if r["adv_src"] != r["adv_out"]]
report(not adv, "advance widths unchanged (CoreText)", f"changed: {adv[:10]}" if adv else f"{len(rows)} glyphs")

# ---- reference IoU -------------------------------------------------------------
cmp_rows = [r for r in inked if r["gid"] not in injected and r.get("iou_final_ref", "") != ""]
iou_ref = [num(r, "iou_final_ref") for r in cmp_rows]
iou_float_ref = [num(r, "iou_float_ref") for r in cmp_rows]
p1, p50 = percentile(iou_ref, 1), percentile(iou_ref, 50)
report(p50 >= 0.99, "IoU(final font, BailuKai Medium) median >= 0.99",
       f"n={len(iou_ref)} (excluding {len(injected)} LXGW copies) min={min(iou_ref):.4f} p1={p1:.4f} p50={p50:.4f}")
print(f"INFO  IoU(spike float result, BailuKai) on the same glyphs: min={min(iou_float_ref):.4f} "
      f"p1={percentile(iou_float_ref, 1):.4f} p50={percentile(iou_float_ref, 50):.4f}")
iou_ff = [num(r, "iou_final_float") for r in inked]
mism = [num(r, "mismatch_final_float_px") for r in inked]
print(f"INFO  IoU(final font, spike float result) = cu2qu + rounding cost: min={min(iou_ff):.5f} "
      f"p1={percentile(iou_ff, 1):.5f} p50={percentile(iou_ff, 50):.5f}; differing 4u-pixels per glyph "
      f"p50={percentile(mism, 50):.0f} p99={percentile(mism, 99):.0f} max={max(mism):.0f}")
worst_ff = sorted(inked, key=lambda r: num(r, "iou_final_float"))[:8]
print("INFO  lowest IoU(final, float): " + ", ".join(f"{char(r)}#{r['gid']} {num(r, 'iou_final_float'):.4f}" for r in worst_ff))

# ---- integrity on the final integer outlines ------------------------------------
nz = [r for r in inked if num(r, "nz_eo_px") > 0]
report(not nz, "nonzero fill == even-odd fill for every glyph (4 u/px)",
       f"{len(nz)} glyphs differ: " + ", ".join(f"{char(r)}#{r['gid']}:{r['nz_eo_px']}px" for r in nz[:10]) if nz else f"{len(inked)} glyphs")
mis = [r for r in inked if num(r, "misoriented") > 0]
report(not mis, "outer contours clockwise, holes counter-clockwise (y up)",
       f"{len(mis)} glyphs: " + ", ".join(f"{char(r)}#{r['gid']}" for r in mis[:10]) if mis else
       f"{sum(int(r['contours']) for r in inked)} contours")
van = [r for r in inked if num(r, "holes_vanished") > 0]
print(f"INFO  glyphs where a source counter >= 400 u2 has no surviving hole: {len(van)} "
      + ", ".join(f"{char(r)}#{r['gid']}" for r in van[:20]))
deb = [r for r in inked if num(r, "debris") > 0]
report(not deb, "no debris contours (extent < 2 u or area < 4 u2) in the output",
       f"{len(deb)} glyphs: " + ", ".join(f"{char(r)}#{r['gid']}" for r in deb[:10]) if deb else "")
cross = [r for r in inked if num(r, "crossings") > 0]
fcross = [r for r in inked if num(r, "float_crossings") > 0]
print(f"INFO  glyphs with polyline crossings after cu2qu + rounding (residual spurs): {len(cross)} "
      f"(total crossings {sum(int(r['crossings']) for r in cross)}); spike float union without cleanup: {len(fcross)} glyphs")
with open(LISTS / "crossings.tsv", "w") as fh:
    step = max(1, len(cross) // 24)
    for r in cross[::step][:24]:
        fh.write(f"{r['gid']}\t{r['cross_x']}\t{r['cross_y']}\t{char(r)} #{r['gid']} crossings {r['crossings']}\n")

# ---- the glyphs BailuKai replaced by hand ---------------------------------------
grades = {r["glyph_id"]: r for r in csv.DictReader(open(REPORT_CSV))}
by_char = {char(r): r for r in rows if r.get("cp")}
fixed_ok = True
details = []
for c in HAND_FIXED:
    r = by_char.get(c)
    if r is None:
        fixed_ok = False
        details.append(f"{c}: missing")
        continue
    clean = (num(r, "nz_eo_px") == 0 and num(r, "misoriented") == 0 and num(r, "crossings") == 0
             and num(r, "holes_vanished") == 0 and num(r, "debris") == 0)
    fixed_ok &= clean
    g = grades.get(r["gid"], {})
    details.append(f"{c}#{r['gid']} {'clean' if clean else 'NOT CLEAN'} grade {g.get('grade', '?')} "
                   f"min_hole {g.get('min_hole_ratio', '')} vs-LXGW-Medium IoU {num(r, 'iou_final_ref'):.4f}")
report(fixed_ok, "the 8 glyphs BailuKai replaced by hand are clean", "; ".join(details))

# ---- grades -------------------------------------------------------------------------
graded = list(grades.values())
counts = {k: sum(1 for g in graded if g["grade"] == k) for k in "ABCD"}
total = len(graded)
dist = " ".join(f"{k}={counts[k]} ({100 * counts[k] / total:.2f}%)" for k in "ABCD")
drift = max(abs(100 * counts[k] / total - PHASE0[k]) for k in "ABC")
report(drift <= 0.5, "grade distribution within 0.5 points of Phase 0 (A 0.31%, B 1.70%, C 8.90%)", dist)
report(counts == PHASE2E, "grade counts equal Phase 2E's `fontsmaker embolden` run",
       " ".join(f"{k}={counts[k]} (2E {PHASE2E[k]})" for k in "ABCD"))

print(f"{'OK' if failures == 0 else 'FAILED'}: {failures} failing checks")
sys.exit(1 if failures else 0)
