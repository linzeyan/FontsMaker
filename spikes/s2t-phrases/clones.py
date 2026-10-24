"""Prototype of a fix for the side effects on traditional text (question 4).

Today s2t points 车 at 車's glyph, so in glyph space simplified 车夫 and
traditional 車夫 are the same input and a phrase rule cannot tell them apart.
Here every code point the s2t step remapped gets its own alias glyph: a
composite with one unscaled component, the traditional glyph. Without GSUB it
draws exactly what the character-level font draws; with GSUB, rules keyed on
the alias only fire on simplified input.

Usage: python3 -I clones.py <source.ttf> <char-level.ttf> <out.ttf> <resaved.ttf>
Writes <out stem>.gidmap.json (glyph → drawn glyph), and <resaved.ttf>: the
input saved through fontTools unchanged, so the size delta isolates the aliases.
"""

import json
import sys

from fontTools.ttLib import TTFont
from fontTools.ttLib.tables._g_l_y_f import Glyph, GlyphComponent

source, built, out, resaved = sys.argv[1:5]
src_cmap = TTFont(source, lazy=True)["cmap"].getBestCmap()

base = TTFont(built, recalcTimestamp=False)
base.save(resaved)

font = TTFont(built, recalcTimestamp=False)
glyf = font["glyf"]
order = list(font.getGlyphOrder())
cmap = font["cmap"].getBestCmap()
remapped = sorted(cp for cp, name in cmap.items() if src_cmap.get(cp) != name)
aliases = {}
for cp in remapped:
    target = cmap[cp]
    name = f"s2t.u{cp:04X}"
    glyph = Glyph()
    glyph.numberOfContours = -1
    component = GlyphComponent()
    component.glyphName = target
    component.x = component.y = 0
    # ARGS_ARE_XY_VALUES | USE_MY_METRICS: offsets, and the alias takes the
    # traditional glyph's metrics.
    component.flags = 0x0002 | 0x0200
    glyph.components = [component]
    glyf.glyphs[name] = glyph
    order.append(name)
    aliases[name] = target
    font["hmtx"].metrics[name] = font["hmtx"].metrics[target]
    if "vmtx" in font:
        font["vmtx"].metrics[name] = font["vmtx"].metrics[target]
font.setGlyphOrder(order)
glyf.glyphOrder = order
for table in font["cmap"].tables:
    if table.isUnicode():
        for cp in remapped:
            if cp in table.cmap:
                table.cmap[cp] = f"s2t.u{cp:04X}"
font.save(out)

ids = {name: i for i, name in enumerate(order)}
gidmap = {str(i): ids[aliases.get(name, name)] for i, name in enumerate(order)}
with open(out[: -len(".ttf")] + ".gidmap.json", "w") as stream:
    json.dump(gidmap, stream)
print(json.dumps({"aliases": len(aliases), "glyphs": len(order)}))
