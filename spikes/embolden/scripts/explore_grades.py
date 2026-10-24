"""Exploration for threshold calibration: where do known-fragile glyphs sit?"""

import csv
import sys

import numpy as np

rows = [r for r in csv.DictReader(open(sys.argv[1])) if r["src_empty"] == "0"]
by_cp = {chr(int(r["cp"], 16)): r for r in rows if r["cp"]}


def f(r, k):
    v = r.get(k, "")
    return float(v) if v != "" else float("nan")


def pct_rank(k, v):
    vals = np.array([f(r, k) for r in rows])
    vals = vals[~np.isnan(vals)]
    return (vals < v).mean() * 100


keys = ["hole_area_ratio", "min_hole_ratio", "holes_vanished", "holes_new", "new_hole_min_area",
        "holes_split", "src_min_hole_area", "b_min_hole_area", "outer_delta", "contour_delta",
        "iou_bold_ref", "b_small"]
print("char " + " ".join(f"{k[:12]:>12s}" for k in keys))
for ch in "傳導育帳熱繁聯鬢萇倀長鬱齉龘驫靈鷹讀體藝爨籲國的永":
    r = by_cp.get(ch)
    if not r:
        print(ch, "missing")
        continue
    print(f"{ch}    " + " ".join(f"{r[k]:>12s}" for k in keys)
          + f"   [min_hole pct {pct_rank('min_hole_ratio', f(r, 'min_hole_ratio')):.1f}%]")

for k in ["new_hole_min_area", "b_min_hole_area", "src_min_hole_area", "min_hole_ratio", "hole_area_ratio"]:
    v = np.array([f(r, k) for r in rows])
    v = v[~np.isnan(v)]
    print(k, len(v), np.percentile(v, [0, 0.5, 1, 2, 5, 10, 25, 50]).round(3))

# How many glyphs would each candidate condition flag?
conds = {
    "vanished>0": lambda r: f(r, "holes_vanished") > 0,
    "min_hole<0.3": lambda r: f(r, "min_hole_ratio") < 0.3,
    "min_hole<0.4": lambda r: f(r, "min_hole_ratio") < 0.4,
    "min_hole<0.5": lambda r: f(r, "min_hole_ratio") < 0.5,
    "min_hole<0.6": lambda r: f(r, "min_hole_ratio") < 0.6,
    "hole_ratio<0.5": lambda r: f(r, "hole_area_ratio") < 0.5,
    "hole_ratio<0.6": lambda r: f(r, "hole_area_ratio") < 0.6,
    "hole_ratio<0.7": lambda r: f(r, "hole_area_ratio") < 0.7,
    "split>0": lambda r: f(r, "holes_split") > 0,
    "new>0": lambda r: f(r, "holes_new") > 0,
    "new_min<100": lambda r: f(r, "new_hole_min_area") < 100,
    "new_min<300": lambda r: f(r, "new_hole_min_area") < 300,
    "new_min<1000": lambda r: f(r, "new_hole_min_area") < 1000,
    "b_min_hole<300": lambda r: f(r, "b_min_hole_area") < 300,
    "contour_delta>0": lambda r: f(r, "contour_delta") > 0,
    "bbox>2": lambda r: max(f(r, "bbox_growth_w"), f(r, "bbox_growth_h")) > 2,
}
for name, c in conds.items():
    hits = [r for r in rows if c(r)]
    sample = "".join(chr(int(r["cp"], 16)) for r in hits if r["cp"])[:40]
    print(f"{name:16s} {len(hits):6d} {100 * len(hits) / len(rows):5.2f}%  {sample}")
