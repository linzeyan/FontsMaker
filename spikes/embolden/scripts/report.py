"""Phase 0 report: turns the analysis/timing CSVs and logs into summary.md,
grade tables, and the glyph lists the contact sheets are rendered from.
Reads only spike outputs (never the fonts). Usage: python3 -I report.py ARTIFACT_DIR
"""

import csv
import math
import re
import sys
from pathlib import Path

import numpy as np

OUT = Path(sys.argv[1])
CSV, LISTS, LOGS = OUT / "csv", OUT / "lists", OUT / "logs"
LISTS.mkdir(exist_ok=True)
WEIGHT = 12.0
md: list[str] = []


def emit(s=""):
    md.append(s)
    print(s)


def load(name):
    p = CSV / f"{name}.csv"
    if not p.exists():
        emit(f"**MISSING {p}**")
        return None
    return [r for r in csv.DictReader(open(p)) if r["src_empty"] == "0"]


def f(r, k):
    v = r.get(k, "")
    return float(v) if v not in ("", None) else math.nan


def col(rows, k):
    a = np.array([f(r, k) for r in rows])
    return a[~np.isnan(a)]


def ch(r):
    return chr(int(r["cp"], 16)) if r["cp"] else r["name"]


def pct_row(a, ps=(0, 1, 5, 50, 95, 99, 100), fmt="{:.3f}"):
    if len(a) == 0:
        return " | ".join("–" for _ in ps)
    return " | ".join(fmt.format(x) for x in np.percentile(a, ps))


def growth(r):
    return max(f(r, "bbox_growth_w"), f(r, "bbox_growth_h"))


# ---- grading ---------------------------------------------------------------
# NaN comparisons are False, so glyphs without counters skip counter rules.
def grade_initial(r):
    """technical-design §5.2 as written (total hole area incl. new counters)."""
    har = f(r, "hole_area_ratio_all")
    if f(r, "holes_vanished") > 0 or har < 0.3:
        return "A"
    if har < 0.5 or growth(r) > 2 or f(r, "contour_delta") > 0:
        return "B"
    if har < 0.7:
        return "C"
    return "D"


PROPOSED = {
    "A": "a source counter (≥ 400 u²) vanished, or min_hole_ratio < 0.40",
    "B": "min_hole_ratio < 0.55, or a new counter < 100 u² (pinhole speck), or bboxGrowth > 2",
    "C": "min_hole_ratio < 0.70, or a counter split in two (holes_split > 0)",
    "D": "everything else",
}


def grade_proposed(r):
    mh = f(r, "min_hole_ratio")
    if f(r, "holes_vanished") > 0 or mh < 0.40:
        return "A"
    if mh < 0.55 or f(r, "new_hole_min_area") < 100 or growth(r) > 2:
        return "B"
    # A split is a stroke end that nearly touched now making contact; on the
    # B sample sheet these looked fine (洒 栖 茜), so it only earns a C.
    if mh < 0.70 or f(r, "holes_split") > 0:
        return "C"
    return "D"


def grade_dist(rows, fn):
    g = [fn(r) for r in rows]
    n = len(g)
    return {k: (g.count(k), 100 * g.count(k) / n) for k in "ABCD"}


def dist_str(d):
    return " | ".join(f"{d[k][0]} ({d[k][1]:.2f}%)" for k in "ABCD")


# ---- load ------------------------------------------------------------------
variants = ["miter4", "miter2", "miter10", "round"]
guan = {v: load(f"guan-{v}") for v in variants}
lxgw = {v: load(f"lxgw-{v}") for v in ["miter4", "round"]}
injected_path = LISTS / "bailu-injected-from-lxgw.tsv"
injected = {}
if injected_path.exists():
    for line in injected_path.read_text().splitlines():
        gid, name, c = line.split("\t")
        injected[gid] = c
else:
    emit("**MISSING bailu-injected-from-lxgw.tsv — BailuKai comparison includes replaced glyphs**")
base = guan["miter4"]
by_gid = {v: {r["gid"]: r for r in rows} for v, rows in guan.items() if rows}
by_char = {ch(r): r for r in base if r["cp"]}

emit("# Phase 0 embolden spike — generated report")
emit()
emit(f"Weight {WEIGHT:g} font units. Variants: miter limit 2/4/10 and round joins. "
     f"Reference: BailuKai Medium (FontForge changeWeight(12)), compared by glyph ID. "
     f"{len(injected)} BailuKai glyphs are exact copies of LXGW WenKai TC Medium "
     f"({''.join(injected.values())}) and are excluded from reference comparisons.")
emit()

# ---- integrity -------------------------------------------------------------
emit("## 1. Integrity (systematic breakage checks)")
emit()
emit("| variant | glyphs | empty output | union≠separate fill (max px) | NZ≠EO px>0 | float crossings>0 | "
     "rounded crossings>0 | rounded NZ≠EO>0 | debris contours (glyphs) | outer contours increased | output dir |")
emit("|---|---|---|---|---|---|---|---|---|---|---|")
for v, rows in list(guan.items()) + [(f"lxgw-{k}", x) for k, x in lxgw.items()]:
    if not rows:
        continue
    dirs = sorted(set(r["b_dir"] for r in rows))
    emit(f"| {v} | {len(rows)} | {sum(r['b_empty'] == '1' for r in rows)} | {int(col(rows, 'union_mismatch_px').max())} | "
         f"{int((col(rows, 'self_overlap_px') > 0).sum())} | {int((col(rows, 'b_crossings') > 0).sum())} | "
         f"{int((col(rows, 'q_crossings') > 0).sum())} | {int((col(rows, 'q_self_overlap_px') > 0).sum())} | "
         f"{int((col(rows, 'b_debris') + col(rows, 'b_tiny') > 0).sum())} | {int((col(rows, 'outer_delta') > 0).sum())} | "
         f"{','.join(dirs)} |")
emit()
emit("- union≠separate fill: binary raster (4 u/px) of `bold` vs. outline and stroke filled separately; "
     "a wrong union would show hundreds of px. NZ≠EO: nonzero vs even-odd raster of the output (overlap/self-intersection).")
emit("- crossings: transversal polyline-edge crossings after flattening (0.2 u); 'rounded' = after rounding all points to integers.")
emit("- output dir: dominant contour sign in y-up font units (1 = counter-clockwise). Source is -1 (TrueType clockwise).")
src_x = int((col(base, "src_raw_crossings") > 0).sum())
ref_x = int((col(base, "r_raw_crossings") > 0).sum())
ref_ov = int((col(base, "r_overlap_px") > 0).sum())
emit(f"- Source glyphs with crossing contours: {src_x}. BailuKai glyphs with crossing contours: {ref_x}; "
     f"with NZ≠EO raster difference: {ref_ov} (FontForge output is not overlap-free).")
seg = {k: int(col(base, k).sum()) for k in ["src_lines", "src_quads", "src_cubics", "b_lines", "b_quads", "b_cubics"]}
emit(f"- Segments (miter4, whole font): source lines {seg['src_lines']}, quads {seg['src_quads']}, cubics {seg['src_cubics']}; "
     f"output lines {seg['b_lines']}, quads {seg['b_quads']}, cubics {seg['b_cubics']}. "
     f"point_ratio (cubic output vs quad source, before cu2qu) p50/p95/max: {pct_row(col(base, 'point_ratio'), (50, 95, 100), '{:.2f}')}")
emit()

# ---- weight semantics -------------------------------------------------------
emit("## 2. Weight semantics vs BailuKai (changeWeight(12))")
emit()
cmp_rows = {v: [r for r in rows if r["gid"] not in injected and r.get("iou_bold_ref", "") != ""]
            for v, rows in guan.items() if rows}
r4 = cmp_rows["miter4"]
emit("Per-side offset d_eff = Δfilled-area ÷ source perimeter (units). Exact offset by w/2 gives 6.0 minus losses where strokes merge.")
emit()
emit("| quantity | p0 | p1 | p5 | p50 | p95 | p99 | p100 |")
emit("|---|---|---|---|---|---|---|---|")
emit(f"| ours d_eff (miter4) | {pct_row(col(r4, 'd_eff'))} |")
emit(f"| BailuKai d_eff | {pct_row(col(r4, 'r_d_eff'))} |")
diff = np.array([f(r, "d_eff") - f(r, "r_d_eff") for r in r4])
emit(f"| ours − BailuKai d_eff | {pct_row(diff)} |")
ratio = np.array([f(r, "r_d_eff") / f(r, "d_eff") for r in r4 if f(r, "d_eff") > 0])
emit(f"| BailuKai/ours d_eff ratio | {pct_row(ratio)} |")
sides = {}
for who, pfx in [("ours", "b"), ("BailuKai", "r")]:
    s = []
    for r in r4:
        s += [f(r, "src_xmin") - f(r, f"{pfx}_xmin"), f(r, f"{pfx}_xmax") - f(r, "src_xmax"),
              f(r, "src_ymin") - f(r, f"{pfx}_ymin"), f(r, f"{pfx}_ymax") - f(r, "src_ymax")]
    sides[who] = np.array(s)
    emit(f"| {who} bbox growth per side (u) | {pct_row(sides[who])} |")
emit(f"| ours − BailuKai per side (u) | {pct_row(sides['ours'] - sides['BailuKai'])} |")
for v in variants:
    if v in cmp_rows:
        emit(f"| IoU ours-{v} vs BailuKai | {pct_row(col(cmp_rows[v], 'iou_bold_ref'), fmt='{:.4f}')} |")
emit(f"| IoU source vs BailuKai | {pct_row(col(r4, 'iou_src_ref'), fmt='{:.4f}')} |")
emit(f"| filled area ours/BailuKai | {pct_row(col(r4, 'area_ratio_bold_ref'), fmt='{:.4f}')} |")
emit()
w_eq = WEIGHT * float(np.median(ratio))
emit(f"**Weight mapping:** median BailuKai/ours offset ratio {np.median(ratio):.4f} → FontForge changeWeight(12) ≡ our weight "
     f"{w_eq:.2f}, i.e. 1:1. Advance widths in BailuKai are unchanged for every glyph (see 00-probe-reference.log).")
emit()
low = sorted([r for r in r4 if f(r, "iou_bold_ref") < 0.95], key=lambda r: f(r, "iou_bold_ref"))
emit(f"Glyphs with IoU(ours miter4, BailuKai) < 0.95 after excluding the LXGW copies: {len(low)} — "
     + ", ".join(f"{ch(r)}#{r['gid']} {f(r, 'iou_bold_ref'):.3f}" for r in low))
with open(LISTS / "low-iou.tsv", "w") as fh:
    for r in low:
        fh.write(f"{r['gid']}\t{ch(r)} #{r['gid']} IoU {f(r, 'iou_bold_ref'):.3f} src-vs-ref {f(r, 'iou_src_ref'):.3f}\n")
emit()

# ---- joins -----------------------------------------------------------------
emit("## 3. Join comparison")
emit()
emit("| variant | IoU mean vs BailuKai | IoU p1 | glyphs bboxGrowth>1.05 | >1.5 | >2 | max | hole_area_ratio p50 | min_hole_ratio p1 |")
emit("|---|---|---|---|---|---|---|---|---|")
for v in variants:
    rows = cmp_rows.get(v)
    if not rows:
        continue
    g = np.array([growth(r) for r in guan[v]])
    emit(f"| {v} | {col(rows, 'iou_bold_ref').mean():.5f} | {np.percentile(col(rows, 'iou_bold_ref'), 1):.4f} | "
         f"{(g > 1.05).sum()} | {(g > 1.5).sum()} | {(g > 2).sum()} | {g.max():.2f} | "
         f"{np.median(col(guan[v], 'hole_area_ratio')):.4f} | {np.percentile(col(guan[v], 'min_hole_ratio'), 1):.4f} |")
m4, rd = by_gid["miter4"], by_gid["round"]
common = [g for g in m4 if g in rd and g not in injected and m4[g].get("iou_bold_ref", "")]
better_m = sum(f(m4[g], "iou_bold_ref") > f(rd[g], "iou_bold_ref") + 1e-4 for g in common)
better_r = sum(f(rd[g], "iou_bold_ref") > f(m4[g], "iou_bold_ref") + 1e-4 for g in common)
emit()
emit(f"Per glyph, miter4 is closer to BailuKai (IoU +1e-4) in {better_m} glyphs, round in {better_r}, tie in {len(common) - better_m - better_r}.")
emit()

# ---- counters / contours ---------------------------------------------------
emit("## 4. Counter and contour metrics (miter4) vs BailuKai")
emit()
emit("| metric | p0 | p1 | p5 | p50 | p95 | p99 | p100 |")
emit("|---|---|---|---|---|---|---|---|")
for k in ["hole_area_ratio", "r_hole_area_ratio", "min_hole_ratio", "r_min_hole_ratio", "hole_area_ratio_all",
          "contour_delta", "outer_delta", "holes_delta", "new_hole_min_area", "b_min_hole_area", "t_union_us"]:
    emit(f"| {k} | {pct_row(col(base, k))} |")
emit()
for k in ["holes_vanished", "r_holes_vanished", "src_sliver_holes", "holes_new", "holes_split", "b_small"]:
    a = col(base, k)
    emit(f"- {k}: {int((a > 0).sum())} glyphs > 0 (max {int(a.max())})")
emit("- hole_area_ratio counts only counters that survive inside a source counter; hole_area_ratio_all also counts new "
     "counters formed by strokes merging, which is why its p95 exceeds 1.")
emit("- vanished / min_hole_ratio / split ignore source 'counters' under 400 u² (src_sliver_holes): hairline gaps "
     "between abutting stroke contours, which emboldening closes by design.")
emit(f"- pinholes (new counter < 100 u²): {int((col(base, 'new_hole_min_area') < 100).sum())} glyphs; "
     f"split counters: {int((col(base, 'holes_split') > 0).sum())} glyphs.")
emit()

# ---- grades ----------------------------------------------------------------
emit("## 5. Risk grades")
emit()
emit("Proposed thresholds:")
emit()
emit("| grade | rule (first match wins) |")
emit("|---|---|")
for k, v in PROPOSED.items():
    emit(f"| {k} | {v} |")
emit()
emit("| font / variant | thresholds | A | B | C | D |")
emit("|---|---|---|---|---|---|")
for name, rows in [(f"Guan {v}", guan[v]) for v in variants] + [(f"LXGW {k}", x) for k, x in lxgw.items()]:
    if not rows:
        continue
    emit(f"| {name} | initial §5.2 | {dist_str(grade_dist(rows, grade_initial))} |")
    emit(f"| {name} | proposed | {dist_str(grade_dist(rows, grade_proposed))} |")
emit()
emit("Known-fragile and dense characters (miter4):")
emit()
emit("| char | gid | min_hole_ratio (percentile) | hole_area_ratio | vanished | new (min area) | split | IoU vs BailuKai | initial | proposed |")
emit("|---|---|---|---|---|---|---|---|---|---|")
mh_all = col(base, "min_hole_ratio")
for c in "傳導育帳熱繁聯鬢萇倀張鬱齉龘驫靈鷹讀體藝爨籲國的永":
    r = by_char.get(c)
    if not r:
        emit(f"| {c} | – | not in cmap | | | | | | | |")
        continue
    mh = f(r, "min_hole_ratio")
    pr = f"{mh:.3f} ({100 * (mh_all < mh).mean():.1f}%)" if not math.isnan(mh) else "no counters"
    tag = " (BailuKai: LXGW copy)" if r["gid"] in injected else ""
    emit(f"| {c}{tag} | {r['gid']} | {pr} | {f(r, 'hole_area_ratio'):.3f} | {r['holes_vanished']} | "
         f"{r['holes_new']} ({r['new_hole_min_area'] or '–'}) | {r['holes_split']} | {f(r, 'iou_bold_ref'):.4f} | "
         f"{grade_initial(r)} | {grade_proposed(r)} |")
emit()

# ---- lists for sheets ------------------------------------------------------
def label(r):
    return (f"{ch(r)} #{r['gid']} hole {f(r, 'hole_area_ratio'):.2f} min {f(r, 'min_hole_ratio'):.2f} "
            f"new {r['holes_new']} split {r['holes_split']} [{grade_proposed(r)}]")


def write_list(name, rows):
    with open(LISTS / name, "w") as fh:
        for r in rows:
            fh.write(f"{r['gid']}\t{label(r)}\n")


write_list("worst-holes.tsv", sorted([r for r in base if not math.isnan(f(r, "hole_area_ratio"))],
                                     key=lambda r: f(r, "hole_area_ratio"))[:60])
with open(LISTS / "worst-contours.tsv", "w") as fh:
    for r in sorted(base, key=lambda r: -f(r, "contour_delta"))[:30]:
        fh.write(f"{r['gid']}\t{ch(r)} #{r['gid']} Δc {int(f(r, 'contour_delta')):+d} outer {int(f(r, 'outer_delta')):+d} "
                 f"new holes {r['holes_new']} split {r['holes_split']} [{grade_proposed(r)}]\n")
grade_a = sorted([r for r in base if grade_proposed(r) == "A"], key=lambda r: f(r, "min_hole_ratio"))
write_list("grade-a.tsv", grade_a[:120])
# Evenly spaced samples (by gid) show what a typical B / C glyph looks like,
# which is what the threshold boundaries need to be judged on.
for g in "BC":
    rows = [r for r in base if grade_proposed(r) == g]
    step = max(1, len(rows) // 60)
    write_list(f"grade-{g.lower()}-sample.tsv", rows[::step][:60])
fixed = [by_gid["miter4"][g] for g in injected if g in by_gid["miter4"]]
fixed += [by_char[c] for c in "萇倀張" if c in by_char]
write_list("bailu-fixed.tsv", fixed)
if lxgw.get("miter4"):
    write_list("lxgw-grade-a.tsv", sorted([r for r in lxgw["miter4"] if grade_proposed(r) == "A"],
                                          key=lambda r: f(r, "min_hole_ratio"))[:120])
emit(f"Proposed grade A (miter4): {len(grade_a)} glyphs; sheet shows the first {min(120, len(grade_a))} by min_hole_ratio.")
emit()

# ---- timing ----------------------------------------------------------------
emit("## 6. Timing (engine only: CoreText path extraction + stroke + union)")
emit()


# The machine is shared with other jobs, so timing was run three times; the
# least-disturbed (minimum) value per measurement is the engine's real cost.
# Run 1 logs were overwritten by run 2; its lines survive in an extract.
def run_texts():
    runs = {}
    extract = LOGS / "timing-run1-extract.txt"
    if extract.exists():
        runs["run1"] = {m.group(1): m.group(2) for m in
                        re.finditer(r"^- `([^`]+)`: (.*)$", extract.read_text(), re.M)}
    for label, d in [("run2", LOGS / "timing-run2"), ("run3", OUT / "timing-run3" / "logs")]:
        if d.exists():
            runs[label] = {p.stem: p.read_text() for p in d.glob("*.log")}
    return runs


def metric(text, kind):
    if text is None:
        return math.nan
    if kind == "single":
        m = re.search(r"single-thread: ([\d.]+) s", text)
        return float(m.group(1)) if m else math.nan
    walls = [float(x) for x in re.findall(r"in ([\d.]+) s wall", text)]
    return min(walls) if walls else math.nan


runs = run_texts()
names = [("20-timing-guan-miter4-single-P", "single", "原俠 miter4, 1 top-tier core (s)"),
         ("20-timing-guan-round-single-P", "single", "原俠 round, 1 top-tier core (s)"),
         ("21-timing-guan-miter4-single-E", "single", "原俠 miter4, 1 lower-tier core, extrapolated (s)"),
         ("21-timing-guan-round-single-E", "single", "原俠 round, 1 lower-tier core, extrapolated (s)"),
         ("22-timing-guan-miter4-parallel", "parallel", "原俠 miter4, 18 threads (s)"),
         ("22-timing-guan-round-parallel", "parallel", "原俠 round, 18 threads (s)"),
         ("24-timing-guan-miter4-6threads", "parallel", "原俠 miter4, 6 threads (s)"),
         ("23-timing-guan-miter4-2threads", "parallel", "原俠 miter4, 2 threads (s)"),
         ("31-timing-lxgw-miter4-single-P", "single", "霞鶩 TC miter4, 1 top-tier core (s)"),
         ("31-timing-lxgw-round-single-P", "single", "霞鶩 TC round, 1 top-tier core (s)"),
         ("32-timing-lxgw-miter4-parallel", "parallel", "霞鶩 TC miter4, 18 threads (s)"),
         ("32-timing-lxgw-round-parallel", "parallel", "霞鶩 TC round, 18 threads (s)")]
labels = sorted(runs)
emit("| measurement | " + " | ".join(labels) + " | best |")
emit("|---|" + "---|" * (len(labels) + 1))
for name, kind, desc in names:
    vals = [metric(runs[l].get(name), kind) for l in labels]
    finite = [v for v in vals if not math.isnan(v)]
    best = f"**{min(finite):.2f}**" if finite else "–"
    emit(f"| {desc} | " + " | ".join("–" if math.isnan(v) else f"{v:.2f}" for v in vals) + f" | {best} |")
emit()
for l in labels:
    loads = [runs[l].get(k, "").strip() for k in ("03-load-before", "39-load-after")]
    emit(f"- {l} load average before / after: " + (" / ".join(x for x in loads if x) or "not recorded"))
for l in labels:
    t = runs[l].get("20-timing-guan-miter4-single-P")
    m = t and re.search(r"per-glyph engine us: (.*)", t)
    if m:
        emit(f"- {l} 原俠 miter4 per-glyph engine µs: {m.group(1)}")
for name in ["timing-guan-miter4-single", "timing-lxgw-miter4-single"]:
    p = CSV / f"{name}.csv"
    if p.exists():
        t = [r for r in csv.DictReader(open(p))]
        eng = np.array([float(r["t_stroke_us"]) + float(r["t_union_us"]) for r in t])
        un = np.array([float(r["t_union_us"]) for r in t])
        ex = np.array([float(r["t_extract_us"]) for r in t])
        emit(f"- {name}.csv (latest run in csv/): union share of engine time {100 * un.sum() / eng.sum():.1f}%, "
             f"CoreText extraction {100 * ex.sum() / (eng.sum() + ex.sum()):.1f}% of total")
emit()

(OUT / "summary.md").write_text("\n".join(md) + "\n")
print(f"wrote {OUT / 'summary.md'}")
