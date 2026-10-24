"""Question 8: phrase lookups on a font built with s2t + pseudoVertical
(the recipes/examples order).

Usage: python3 -I pv.py <work> <source.ttf> <out dir>

pseudoVertical turns only glyphs some code point reaches through the cmap.
After s2t + TW, 后 maps to 後's glyph, so no code point reaches 后's own
glyph and it stays upright, yet the phrase rule for 皇后 substitutes it.
(里 escapes by luck: the Kangxi radical U+2FA5 still maps to its glyph.)
This counts such targets, shows the defect, and prototypes the fix: turn
every glyph the phrase lookups can produce, with the engine's formula
(x' = A − y, y' = x + ⌊(A + D − adv)/2⌋, advance A − D).
"""

import collections
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import derive  # noqa: E402
import model  # noqa: E402
from fontTools.pens.transformPen import TransformPen  # noqa: E402
from fontTools.pens.ttGlyphPen import TTGlyphPen  # noqa: E402
from fontTools.ttLib import TTFont  # noqa: E402

work, source, out = sys.argv[1:4]
os.makedirs(out, exist_ok=True)
fdir = os.path.join(work, "fonts")
pv_path = os.path.join(fdir, "char-tw-pv.ttf")

src = TTFont(source)
pv = TTFont(pv_path)
A, D = src["OS/2"].sTypoAscender, src["OS/2"].sTypoDescender
src_order = src.getGlyphOrder()
pv_order = pv.getGlyphOrder()


def coords(font, name):
    c, ends, flags = font["glyf"][name].getCoordinates(font["glyf"])
    return [tuple(p) for p in c]


def turned(points, adv):
    shift = (A + D - adv) // 2
    return [(A - y, x + shift) for x, y in points]


def classify(gid):
    """'turned', 'upright' (untouched) or 'other' for a source glyph ID in the PV font."""
    name = src_order[gid]
    s = coords(src, name)
    p = coords(pv, pv_order[gid])
    adv = src["hmtx"][name][0] or (A - D)
    if p == s:
        return "upright" if s else "empty"
    if p == turned(s, adv):
        return "turned"
    return "other"


sets, info, rules, *_ = derive.rule_sets(work, source, pv_path, "tw")
active = sets["R2"][0]
targets = collections.Counter(dst for r in active for _, _, dst in r.subs)
classes = {g: classify(g) for g in targets}
upright_targets = sorted(g for g, c in classes.items() if c == "upright")
src_rev = model.reverse_cmap(model.best_cmap(source))
report = {
    "rules": len(active),
    "rules_with_substitutions": sum(1 for r in active if r.subs),
    "distinct_target_glyphs": len(targets),
    "target_glyph_classes": dict(collections.Counter(classes.values())),
    "rules_hitting_upright_target": sum(1 for r in active if any(classes[d] == "upright" for _, _, d in r.subs)),
    "upright_target_examples": ["".join(chr(c) for c in src_rev[g][:1]) for g in upright_targets[:40]],
}

# Naive: rules built against the PV font as is.
naive = os.path.join(fdir, "char-tw-pv-R2.ttf")
report["naive"] = derive.build_variant(pv_path, naive, active, sets["R2"][1], "rlig")

# Fix prototype: turn the upright targets in place.
fixed = os.path.join(fdir, "char-tw-pv-R2-fixed.ttf")
font = TTFont(naive, recalcTimestamp=False)
glyf = font["glyf"]
gs = font.getGlyphSet()
for gid in upright_targets:
    name = font.getGlyphOrder()[gid]
    adv = font["hmtx"][name][0]
    pen = TTGlyphPen(gs)
    shift = (A + D - (adv or (A - D))) // 2
    gs[name].draw(TransformPen(pen, (0, 1, -1, 0, A, shift)))
    glyf[name] = pen.glyph()
    if adv:
        font["hmtx"][name] = (A - D, font["hmtx"][name][1])
font.save(fixed)
font.close()
pv_fixed = TTFont(fixed)
still = []
for gid in upright_targets:
    name = src_order[gid]
    if coords(pv_fixed, pv_fixed.getGlyphOrder()[gid]) != turned(coords(src, name), src["hmtx"][name][0] or (A - D)):
        still.append(gid)
report["fixed_turned_glyphs"] = len(upright_targets)
report["fixed_targets_not_turned_after_fix"] = len(still)
report["fixed_file_bytes"] = os.path.getsize(fixed)

# Shape the probe sentence and the novel: how often would a reader see an
# upright (wrong) glyph?
sentence = "这个国家的发展为后来里程碑，皇后"
upright_set = set(upright_targets)
src_cmap = model.best_cmap(source)
for label, path in (("char-level", pv_path), ("naive", naive), ("fixed", fixed)):
    res = subprocess.run(["hb-shape", "--font-file", path, "--output-format=json", "--no-glyph-names",
                          "--language=zh-Hans", sentence], capture_output=True, text=True, check=True)
    glyphs = [g["g"] for g in json.loads(res.stdout)]
    report[f"sentence_{label}"] = {
        "glyph_at_里": glyphs[10], "source_glyph_里": src_cmap[ord("里")],
        "glyph_at_皇后_后": glyphs[15], "source_glyph_后": src_cmap[ord("后")],
        "upright_glyphs_in_sentence": sum(1 for g in glyphs if g in upright_set) if label != "fixed" else "n/a (turned)",
    }
    res = subprocess.run(["hb-shape", "--font-file", path, "--output-format=json", "--no-glyph-names",
                          "--language=zh-Hans", "--text-file", os.path.join(work, "corpora", "nahan.s.txt")],
                         capture_output=True, text=True, check=True)
    count = 0
    for line in res.stdout.splitlines():
        count += sum(1 for g in json.loads(line) if g["g"] in upright_set)
    report[f"nahan_upright_glyph_occurrences_{label}"] = count if label != "fixed" else "n/a (turned)"
    subprocess.run(["hb-view", "--font-file", path, "--font-size=64", "--margin=16", "--output-format=png",
                    "--output-file", os.path.join(out, f"pv-{label}.png"), sentence], check=True)

model.dump_json(os.path.join(out, "pv.json"), report)
print(json.dumps(report, ensure_ascii=False, indent=1))
