"""Question 7: how GuanKiapTsingKhai -W / -TW (V1.20) do word-level s2t.

Usage: python3 -I prior_art.py <work> <source.ttf> <out dir> <name>=<font.ttf>...

For each font: GSUB structure (scripts, features, lookup types, rule
counts, bytes), glyph and cmap counts, and a glyph map to the source font so
the accuracy metrics of evaluate.py can run on it: glyphs are matched by name
and accepted only when their outlines are identical. The font is linked into
work/fonts/<name>.ttf with work/fonts/<name>.gidmap.json next to it.
"""

import collections
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model  # noqa: E402
from fontTools.ttLib import TTFont  # noqa: E402

work, source, out = sys.argv[1:4]
fonts = dict(arg.split("=", 1) for arg in sys.argv[4:])
os.makedirs(out, exist_ok=True)
src = TTFont(source)
src_glyf = src["glyf"]
src_order = src.getGlyphOrder()
src_ids = {n: i for i, n in enumerate(src_order)}
src_cmap = model.best_cmap(source)
st_chars = model.load_dict(os.path.join(work, "opencc", "STCharacters.txt"))
tw_vars = model.load_dict(os.path.join(work, "opencc", "TWVariants.txt"))
char_s = model.best_cmap(os.path.join(work, "fonts", "char-s.ttf"))
char_tw = model.best_cmap(os.path.join(work, "fonts", "char-tw.ttf"))


def outline(glyf, name):
    coords, ends, flags = glyf[name].getCoordinates(glyf)
    return (tuple(coords), tuple(ends), tuple(f & 1 for f in flags))


report = {}
for name, path in fonts.items():
    font = TTFont(path)
    gsub = font["GSUB"].table
    r = {"file_bytes": os.path.getsize(path), "num_glyphs": font["maxp"].numGlyphs,
         "cmap_code_points": len(font["cmap"].getBestCmap()), "gsub_bytes": len(font.reader["GSUB"])}
    r["scripts"] = {
        sr.ScriptTag: {
            "default": [gsub.FeatureList.FeatureRecord[i].FeatureTag for i in sr.Script.DefaultLangSys.FeatureIndex]
            if sr.Script.DefaultLangSys else None,
            "langs": [lr.LangSysTag for lr in sr.Script.LangSysRecord],
        }
        for sr in gsub.ScriptList.ScriptRecord
    }
    lookups = []
    for i, lookup in enumerate(gsub.LookupList.Lookup):
        subs = [st.ExtSubTable if lookup.LookupType == 7 else st for st in lookup.SubTable]
        kind = subs[0].LookupType if lookup.LookupType == 7 else lookup.LookupType
        c = collections.Counter()
        for st in subs:
            if kind == 1:
                c["pairs"] += len(st.mapping)
            elif kind == 2:
                c["sequences"] += len(st.mapping)
                c["output_glyphs"] += sum(len(v) for v in st.mapping.values())
            elif kind == 4:
                c["ligatures"] += sum(len(v) for v in st.ligatures.values())
                c["components"] += sum(len(l.Component) + 1 for v in st.ligatures.values() for l in v)
        feats = [fr.FeatureTag for fr in gsub.FeatureList.FeatureRecord if i in fr.Feature.LookupListIndex]
        lookups.append({"index": i, "type": lookup.LookupType, "real_type": kind, "subtables": len(subs),
                        "features": feats, **c})
    r["lookups"] = lookups

    # Glyph map: same name and identical outline.
    glyf = font["glyf"]
    order = font.getGlyphOrder()
    gidmap = {}
    same = differ = absent = 0
    for gid, gname in enumerate(order):
        if gname in src_ids:
            if outline(glyf, gname) == outline(src_glyf, gname):
                gidmap[str(gid)] = src_ids[gname]
                same += 1
            else:
                differ += 1
        else:
            absent += 1
    r["glyph_map"] = {"same_name_same_outline": same, "same_name_other_outline": differ, "name_not_in_source": absent}

    # cmap behaviour: is it a character-level s2t cmap like ours?
    cmap = model.best_cmap(path)
    agree = collections.Counter()
    for key, cands in st_chars.items():
        cp = ord(key)
        if cp not in cmap or cp not in char_s:
            continue
        g = gidmap.get(str(cmap[cp]), -1)
        agree["simplified_keys_in_both"] += 1
        agree["same_as_our_single"] += g == char_s[cp]
        agree["same_as_our_single_tw"] += g == char_tw[cp]
        agree["still_source_glyph"] += g == src_cmap.get(cp)
    r["cmap_vs_ours"] = dict(agree)
    r["source_code_points_missing"] = sum(1 for cp in src_cmap if cp not in cmap)

    os.makedirs(os.path.join(work, "fonts"), exist_ok=True)
    link = os.path.join(work, "fonts", name + ".ttf")
    if os.path.lexists(link):
        os.remove(link)
    os.symlink(path, link)
    with open(os.path.join(work, "fonts", name + ".gidmap.json"), "w") as stream:
        json.dump(gidmap, stream)
    report[name] = r
    font.close()

model.dump_json(os.path.join(out, "prior-art.json"), report)
print(json.dumps(report, ensure_ascii=False, indent=1))
