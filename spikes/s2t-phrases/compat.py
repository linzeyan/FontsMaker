"""Question 6: which feature tag and registration make HarfBuzz and CoreText
apply the phrase lookup by default, horizontally and vertically.

Usage: python3 -I compat.py <work> <source.ttf> <out dir>

The source font registers every feature under DFLT only; bopo/hani/kana/latn
exist with empty LangSys. A shaper that picks `hani` for Han text then finds
nothing, so registration is tested along with the tag. `hani-ZHT` registers
only in a ZHT LangSys under hani, to show language-tag sensitivity.
The fonts are scratch files and are deleted after shaping.
"""

import json
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import derive  # noqa: E402
import model  # noqa: E402
from fontTools.ttLib import TTFont  # noqa: E402
from fontTools.ttLib.tables import otTables as ot  # noqa: E402

work, source, out = sys.argv[1:4]
scratch = os.path.join(work, "compat")
os.makedirs(scratch, exist_ok=True)
os.makedirs(out, exist_ok=True)
built = os.path.join(work, "fonts", "char-tw.ttf")
ct = os.path.join(work, "bin", "ct_shape")

sets = derive.rule_sets(work, source, built, "tw")[0]
rules, order = sets["R1"]
src_cmap = model.best_cmap(source)
built_cmap = model.best_cmap(built)
LI = src_cmap[ord("里")]
LI_CHAR_LEVEL = built_cmap[ord("里")]

# vert alternate of （ in the base font, to confirm vert itself is active
base = TTFont(built, lazy=True)
order_names = base.getGlyphOrder()
vert = {}
for fr in base["GSUB"].table.FeatureList.FeatureRecord:
    if fr.FeatureTag == "vert":
        for li in fr.Feature.LookupListIndex:
            for st in base["GSUB"].table.LookupList.Lookup[li].SubTable:
                vert.update(getattr(st, "mapping", {}))
PAREN = built_cmap[ord("（")]
PAREN_VERT = order_names.index(vert[order_names[PAREN]]) if order_names[PAREN] in vert else None
base.close()

text = os.path.join(scratch, "probe.txt")
model.write_lines(text, ["这个国家的发展为后来里程碑", "（里程碑）"])

TAGS = ["calt", "ccmp", "clig", "liga", "locl", "rclt", "rlig", "dlig", "trad"]
REGS = {
    "all": lambda s, l: True,
    "DFLT": lambda s, l: s == "DFLT",
    "hani": lambda s, l: s == "hani",
    "hani-ZHT": lambda s, l: s == "hani" and l == "ZHT ",
    # Which script does CoreText use in vertical layout? (hani and DFLT alone
    # both fail there.)
    "DFLT+hani": lambda s, l: s in ("DFLT", "hani"),
    "kana": lambda s, l: s == "kana",
    "latn": lambda s, l: s == "latn",
    "bopo": lambda s, l: s == "bopo",
}
plan = (
    [(tag, "all") for tag in TAGS]
    + [(tag, reg) for tag in ("rlig", "calt", "ccmp") for reg in ("DFLT", "hani", "hani-ZHT")]
    + [("rlig", reg) for reg in ("DFLT+hani", "kana", "latn", "bopo")]
)

HB = {
    "hb ltr zh-Hans": ["--language=zh-Hans"],
    "hb ltr zh-Hant": ["--language=zh-Hant"],
    "hb ltr en": ["--language=en"],
    "hb ttb zh-Hant": ["--language=zh-Hant", "--direction=ttb"],
}
CT = {
    "ct default": [],
    "ct zh-Hans": ["--lang", "zh-Hans"],
    "ct zh-Hant": ["--lang", "zh-Hant"],
    "ct vertical-forms": ["--vertical"],
    "ct vertical-frame": ["--vertical", "--frame"],
}


def build(tag, reg, path):
    font = TTFont(built, recalcBBoxes=False, recalcTimestamp=False)
    gsub = font["GSUB"].table
    if reg == "hani-ZHT":
        script = next(sr.Script for sr in gsub.ScriptList.ScriptRecord if sr.ScriptTag == "hani")
        record = ot.LangSysRecord()
        record.LangSysTag = "ZHT "
        record.LangSys = ot.LangSys()
        record.LangSys.LookupOrder = None
        record.LangSys.ReqFeatureIndex = 0xFFFF
        record.LangSys.FeatureIndex = []
        record.LangSys.FeatureCount = 0
        script.LangSysRecord.append(record)
        script.LangSysCount = len(script.LangSysRecord)
    model.add_phrase_lookups(font, rules, tag=tag, where=REGS[reg], order=order)
    font.save(path)
    font.close()


def hb(path, args):
    res = subprocess.run(
        ["hb-shape", "--font-file", path, "--text-file", text, "--output-format=json", "--no-glyph-names"] + args,
        capture_output=True, text=True, check=True,
    )
    return [[g["g"] for g in json.loads(line)] for line in res.stdout.splitlines()]


def ct_run(path, args):
    target = os.path.join(scratch, os.path.basename(path) + ".ct.jsonl")
    subprocess.run([ct, path, text, target] + args, capture_output=True, text=True, check=True)
    with open(target) as stream:
        return [[g[0] for g in json.loads(line)] for line in stream]


def verdict(lines):
    li = lines[0][10] == LI
    li2 = lines[1][1] == LI
    paren = {PAREN: "h", PAREN_VERT: "v"}.get(lines[1][0], "?")
    return ("Y" if li and li2 else ("N" if not li and not li2 else "mixed")), paren


results = {}
for tag, reg in plan:
    path = os.path.join(scratch, f"{tag}-{reg}.ttf")
    build(tag, reg, path)
    row = {}
    for name, args in HB.items():
        row[name] = verdict(hb(path, args))
    for name, args in CT.items():
        row[name] = verdict(ct_run(path, args))
    results[f"{tag}/{reg}"] = row
    os.remove(path)
    print(tag, reg, json.dumps(row))

# Control: the character-level font itself (no phrase lookup).
row = {}
for name, args in HB.items():
    row[name] = verdict(hb(built, args))
for name, args in CT.items():
    row[name] = verdict(ct_run(built, args))
results["(none)/char-level"] = row
shutil.rmtree(scratch, ignore_errors=True)

cols = list(HB) + list(CT)
with open(os.path.join(out, "compat.txt"), "w", encoding="utf-8") as t:
    t.write("Phrase lookup applied by default? Y = 里程碑 shows 里 (rule fired), N = 裡 (char-level).\n")
    t.write("Second letter: glyph of （ in （里程碑）: v = vertical alternate (vert active), h = horizontal.\n\n")
    t.write(f"{'tag/registration':<18}" + "".join(f"{c:>19}" for c in cols) + "\n")
    for key, row in results.items():
        t.write(f"{key:<18}" + "".join(f"{row[c][0] + '/' + row[c][1]:>19}" for c in cols) + "\n")
model.dump_json(os.path.join(out, "compat.json"), results)
print(open(os.path.join(out, "compat.txt"), encoding="utf-8").read())
