"""fontTools oracle for Phase 2 recipe outputs (technical design §5, §8).

Run with python3 -I. Never imports anything from the font directories.

  verify_phase2r.py check FONT --source SOURCE
      Full decompile (lazy=False, checksums enforced) and table consistency:
      maxp/hmtx/vmtx/post agree with the glyph count, head/hhea/OS/2 summaries
      agree with the glyphs.
  verify_phase2r.py names FONT --source SOURCE [--forbid WORD ...] [--weight-class N]
      Name table after rename: no source family name (nor any --forbid word,
      e.g. a reserved font name) outside IDs 0/13/14, FontsMaker provenance in
      IDs 0 and 5, style bits match ID 2, usWeightClass as given.
  verify_phase2r.py s2t SOURCE OURS REFERENCE --opencc DIR --label LABEL
      Over every OpenCC simplified code point the source maps: does OURS show
      the same outline as REFERENCE (e.g. GuanKiapTsingKhai-T)? Disagreements
      are classified against the source's own glyphs; code points whose first
      OpenCC candidate the source lacks (where `single` falls back) are listed.
  verify_phase2r.py vertical SOURCE OURS REFERENCE --orientation VO.txt --iou TSV --label LABEL
      Per code point, by UAX #50 class and punctuation: outline equality with
      REFERENCE (e.g. GuanKiapTsingKhai-90), IoU from phase2r_tools for the
      rest, the rotation each font applied, and advance widths.
  verify_phase2r.py centre SOURCE TURNED
      Which quarter turn TURNED applied to SOURCE's glyphs (centre histogram).

Prints PASS/FAIL lines for checks and RESULT lines for measurements; exits 1
if any check fails.
"""

import argparse
import collections
import os
import re
import sys
import unicodedata

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script directory
sys.dont_write_bytecode = True  # no __pycache__ in scripts/

from fontTools.misc.roundTools import otRound  # noqa: E402
from fontTools.ttLib import TTFont  # noqa: E402

from verify_roundtrip import file_checksum_ok, load_fully, vertical_map  # noqa: E402

failures = 0


def report(ok, name, detail=""):
    global failures
    if not ok:
        failures += 1
    print(f"{'PASS' if ok else 'FAIL'}  {name}{('  ' + detail) if detail else ''}")


def char(cp):
    return f"{chr(cp)} U+{cp:04X}"


# ---------------------------------------------------------------------------
# check


def check(path, source_path):
    try:
        font = load_fully(path)
    except Exception as error:  # noqa: BLE001 - any decompile error is the finding
        report(False, "fontTools full decompile (lazy=False, checkChecksums=2)", repr(error))
        return
    report(True, "fontTools full decompile (lazy=False, checkChecksums=2)")
    report(file_checksum_ok(path), "file checksum (head.checkSumAdjustment)")
    src = TTFont(source_path)

    order = font.getGlyphOrder()
    count = font["maxp"].numGlyphs
    source_count = src["maxp"].numGlyphs
    report(count == len(order) == len(font["glyf"].glyphs), "maxp.numGlyphs = glyph order = glyf",
           f"{count} glyphs (source {source_count}, +{count - source_count})")

    before = {k: getattr(font["maxp"], k) for k in ("maxPoints", "maxContours", "maxCompositePoints",
                                                     "maxCompositeContours", "maxComponentElements",
                                                     "maxComponentDepth")}
    font["maxp"].recalc(font)
    after = {k: getattr(font["maxp"], k) for k in before}
    report(before == after, "maxp outline maxima match the glyphs", str(before) if before != after else "")

    long_h = font["hhea"].numberOfHMetrics
    report(len(font.reader["hmtx"]) == 4 * long_h + 2 * (count - long_h), "hmtx length",
           f"{len(font.reader['hmtx'])} bytes, numberOfHMetrics {long_h}")
    if "vmtx" in src:
        report("vmtx" in font and "vhea" in font, "vmtx/vhea kept")
        long_v = font["vhea"].numberOfVMetrics
        report(len(font.reader["vmtx"]) == 4 * long_v + 2 * (count - long_v), "vmtx length",
               f"{len(font.reader['vmtx'])} bytes, numberOfLongVerMetrics {long_v}")
        report(len(font["vmtx"].metrics) == count, "vmtx has an entry per glyph")

    post = font["post"].formatType
    expected_post = 3.0 if count != source_count else src["post"].formatType
    report(post == expected_post, "post format", f"{post} (source {src['post'].formatType}, "
           + ("glyph count changed" if count != source_count else "glyph count unchanged") + ")")
    if post == 3.0:
        report(len(font.reader["post"]) == 32, "post format 3 is the 32-byte header only")

    glyf = font["glyf"]
    boxes = [glyf[n] for n in order if getattr(glyf[n], "numberOfContours", 0) != 0]
    head = font["head"]
    expected_box = (min(g.xMin for g in boxes), min(g.yMin for g in boxes),
                    max(g.xMax for g in boxes), max(g.yMax for g in boxes))
    actual_box = (head.xMin, head.yMin, head.xMax, head.yMax)
    report(actual_box == expected_box, "head bounding box covers the glyphs", str(actual_box))

    widths = [w for w, _ in font["hmtx"].metrics.values()]
    report(font["hhea"].advanceWidthMax == max(widths), "hhea.advanceWidthMax", str(font["hhea"].advanceWidthMax))
    source_widths = [w for w, _ in src["hmtx"].metrics.values()]
    nonzero = [w for w in widths if w > 0]
    recomputed = otRound(sum(nonzero) / len(nonzero))
    xavg = font["OS/2"].xAvgCharWidth
    if widths != source_widths:
        report(xavg == recomputed, "OS/2.xAvgCharWidth follows the new advances",
               f"{xavg} (source {src['OS/2'].xAvgCharWidth})")
    else:
        report(xavg == src["OS/2"].xAvgCharWidth, "OS/2.xAvgCharWidth unchanged with unchanged advances", str(xavg))

    cmap = font.getBestCmap()
    report(all(name in glyf.glyphs for name in cmap.values()), "cmap targets exist",
           f"{len(cmap)} code points (source {len(src.getBestCmap())})")
    hinting = [t for t in ("fpgm", "prep", "cvt ") if t in font]
    composites = sum(1 for n in order if glyf[n].isComposite())
    print(f"INFO  hinting tables {hinting or 'none'}, composite glyphs {composites}")


# ---------------------------------------------------------------------------
# names

IDENTITY = {1, 2, 3, 4, 5, 6, 16, 17}
STYLE_BITS = {"Regular": (0x40, 0), "Italic": (0x01, 2), "Bold": (0x20, 1), "Bold Italic": (0x21, 3)}


def comparable(text):
    return "".join(text.split()).lower()


def names(path, source_path, forbid, weight_class):
    font = TTFont(path)
    src = TTFont(source_path)
    records = sorted(font["name"].names, key=lambda r: (r.platformID, r.platEncID, r.langID, r.nameID))
    for r in records:
        text = r.toUnicode()
        print(f"      {r.platformID}/{r.platEncID}/0x{r.langID:04X} id{r.nameID:<2} {text[:110]}"
              + ("…" if len(text) > 110 else ""))

    old = sorted({comparable(r.toUnicode()) for r in src["name"].names if r.nameID in (1, 16)})
    leftovers = [(r.nameID, r.langID, o) for r in records if r.nameID not in (0, 13, 14)
                 for o in old if o in comparable(r.toUnicode())]
    report(not leftovers, "no source family name outside IDs 0/13/14",
           f"checked {len(old)} source names {old}" + (f"; found {leftovers[:5]}" if leftovers else ""))
    if forbid:
        # Reserved names may be declared only outside the font file (product spec §4.3).
        words = [comparable(w) for w in forbid]
        hits = [(r.nameID, r.langID, w) for r in records if r.nameID not in (0, 13, 14)
                for w in words if w in comparable(r.toUnicode())]
        report(not hits, "no forbidden word outside IDs 0/13/14",
               f"checked {words}" + (f"; found {hits[:5]}" if hits else ""))
    if weight_class is not None:
        actual = font["OS/2"].usWeightClass
        report(actual == weight_class, "OS/2.usWeightClass", f"{actual} (expected {weight_class})")

    key = lambda r: (r.platformID, r.platEncID, r.langID)  # noqa: E731
    source_copyright = {key(r): r.toUnicode() for r in src["name"].names if r.nameID == 0}
    copyright_ok = [r.toUnicode() == source_copyright.get(key(r), "\0") + "; Modified with FontsMaker"
                    for r in records if r.nameID == 0]
    report(copyright_ok and all(copyright_ok) and len(copyright_ok) == len(source_copyright),
           "ID 0 = source copyright + '; Modified with FontsMaker' (every record)", f"{len(copyright_ok)} records")
    for nid in (13, 14):
        ours = {key(r): r.toUnicode() for r in records if r.nameID == nid}
        theirs = {key(r): r.toUnicode() for r in src["name"].names if r.nameID == nid}
        report(ours == theirs, f"ID {nid} kept verbatim", f"{len(ours)} records")

    version = [r.toUnicode() for r in records if r.nameID == 5]
    pattern = re.compile(r"^Version \d+\.\d{3}; FontsMaker \d+\.\d+\.\d+; recipe [0-9a-f]{8}$")
    report(version and all(pattern.match(v) for v in version), "ID 5 = Version x.yyy; FontsMaker <engine>; recipe <hash8>",
           "; ".join(version))

    identity = [r for r in records if r.nameID in IDENTITY]
    report(all(r.platformID == 3 and r.langID in (0x409, 0x404) for r in identity),
           "identity names only on Windows en (0x409) / zh-TW (0x404)")
    report(all(r.langID == 0x409 for r in identity if r.nameID in (3, 5, 6)), "IDs 3/5/6 English only")
    en = {r.nameID: r.toUnicode() for r in identity if r.langID == 0x409}
    ps = en.get(6, "")
    report(0 < len(ps) <= 63 and all(33 <= ord(c) <= 126 and c not in "[](){}<>/%" for c in ps),
           "PostScript name is printable ASCII without []{}()<>/%, ≤ 63", ps)
    typographic = 16 in en
    family, style = (en[16], en.get(17, "")) if typographic else (en.get(1, ""), en.get(2, ""))
    report(en.get(4) == f"{family} {style}", "ID 4 = family + style", en.get(4, ""))

    style_name = en.get(2, "")
    if style_name in STYLE_BITS:
        bits, mac = STYLE_BITS[style_name]
        fs = font["OS/2"].fsSelection & 0x61
        report(fs == bits, "OS/2.fsSelection italic/bold/regular bits match ID 2", f"0x{fs:02X} for {style_name}")
        report(font["head"].macStyle & 0x03 == mac, "head.macStyle bold/italic bits match ID 2",
               f"{font['head'].macStyle & 0x03} for {style_name}")
    print(f"INFO  usWeightClass {font['OS/2'].usWeightClass}, family {family!r}, style {style!r}, PostScript {ps}")


# ---------------------------------------------------------------------------
# outlines shared by s2t and vertical


class Outlines:
    """Flattened, rounded outlines per code point (composites resolved by fontTools)."""

    def __init__(self, path):
        self.font = TTFont(path)
        self.glyf = self.font["glyf"]
        self.cmap = self.font.getBestCmap()
        self.hmtx = self.font["hmtx"].metrics
        self.order = self.font.getGlyphOrder()
        self._cache = {}

    def glyph(self, name):
        if name not in self._cache:
            coords, ends, flags = self.glyf[name].getCoordinates(self.glyf)
            self._cache[name] = (tuple((otRound(x), otRound(y)) for x, y in coords), tuple(ends),
                                 tuple(f & 1 for f in flags))
        return self._cache[name]

    def of(self, cp):
        name = self.cmap.get(cp)
        return None if name is None else self.glyph(name)

    def advance(self, cp):
        return self.hmtx[self.cmap[cp]][0]


def turn_fit(source, turned):
    """(a, b) when turned = (a − y, x + b) for every point of source, else None.
    A quarter turn counter-clockwise about (cx, cy) has a = cx + cy, b = cy − cx."""
    if source is None or turned is None or source[1] != turned[1] or source[2] != turned[2] or not source[0]:
        return None
    pairs = {(tx + sy, ty - sx) for (sx, sy), (tx, ty) in zip(source[0], turned[0])}
    return pairs.pop() if len(pairs) == 1 else None


def near_turn_fit(source, turned, tolerance=4):
    """Like turn_fit, but allows each point to be off by `tolerance` units
    (fonts turned by other tools re-round or nudge points); median (a, b)."""
    if source is None or turned is None or source[1] != turned[1] or not source[0]:
        return None
    a_values = sorted(tx + sy for (sx, sy), (tx, ty) in zip(source[0], turned[0]))
    b_values = sorted(ty - sx for (sx, sy), (tx, ty) in zip(source[0], turned[0]))
    a, b = a_values[len(a_values) // 2], b_values[len(b_values) // 2]
    if a_values[-1] - a <= tolerance and a - a_values[0] <= tolerance and b_values[-1] - b <= tolerance \
            and b - b_values[0] <= tolerance:
        return (a, b)
    return None


def centre(fit):
    a, b = fit
    return ((a - b) / 2, (a + b) / 2)


def near(a, b, tolerance=1):
    return (a is not None and b is not None and a[1] == b[1] and a[2] == b[2]
            and all(abs(p[0] - q[0]) <= tolerance and abs(p[1] - q[1]) <= tolerance for p, q in zip(a[0], b[0])))


# ---------------------------------------------------------------------------
# s2t


def opencc(path):
    table = {}
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        key, values = line.split("\t")
        table[ord(key)] = [ord(v) for v in values.split(" ")]
    return table


def s2t(source_path, ours_path, reference_path, opencc_dir, label):
    st = opencc(os.path.join(opencc_dir, "STCharacters.txt"))
    tw = opencc(os.path.join(opencc_dir, "TWVariants.txt"))
    src, ours, ref = Outlines(source_path), Outlines(ours_path), Outlines(reference_path)
    index = collections.defaultdict(list)
    for cp in sorted(src.cmap):
        index[src.of(cp)].append(cp)

    population = sorted(cp for cp in st if cp in src.cmap and cp in ours.cmap and cp in ref.cmap)
    agree = [cp for cp in population if ours.of(cp) == ref.of(cp)]
    converted = [cp for cp in population if ours.of(cp) != src.of(cp) or ref.of(cp) != src.of(cp)]
    agree_converted = [cp for cp in converted if ours.of(cp) == ref.of(cp)]
    print(f"RESULT s2t {label}: {len(agree)}/{len(population)} simplified code points agree with the reference "
          f"({100 * len(agree) / len(population):.2f}%); converted by either font: {len(agree_converted)}/"
          f"{len(converted)} agree ({100 * len(agree_converted) / max(1, len(converted)):.2f}%)")

    def shown(outline, prefer):
        cps = index.get(outline, [])
        preferred = [c for c in cps if c in prefer]
        return chr((preferred or cps)[0]) if cps else "∅"

    reasons = collections.defaultdict(list)
    for cp in population:
        mine, theirs, base = ours.of(cp), ref.of(cp), src.of(cp)
        if mine == theirs:
            continue
        candidates = st[cp]
        mine_cps, theirs_cps = index.get(mine, []), index.get(theirs, [])
        if theirs == base:
            reason = "reference keeps the simplified glyph"
        elif mine == base:
            if candidates[0] == cp:
                reason = "ours keeps it: OpenCC lists the character itself first"
            elif candidates[0] not in src.cmap:
                reason = "ours keeps it: OpenCC's first candidate has no glyph in the source"
            elif len(candidates) > 1:
                reason = "ours keeps it: one-to-many skipped (skipAmbiguous)"
            else:
                reason = "ours keeps it: other"
        elif not theirs_cps:
            reason = "reference glyph is not any source glyph (drawn or edited for -T)"
        elif any(c in candidates[1:] for c in theirs_cps):
            reason = "reference picks another one-to-many candidate"
        elif any(c in tw.get(m, []) for m in mine_cps for c in theirs_cps) or any(
                c in tw.get(t, []) for t in theirs_cps for c in mine_cps):
            reason = "Taiwan variant differs"
        else:
            reason = "other"
        prefer = set(candidates) | {v for c in candidates for v in tw.get(c, [])}
        reasons[reason].append(f"{chr(cp)}→ours {shown(mine, prefer)} / ref {shown(theirs, prefer)}"
                               f" (OpenCC {' '.join(chr(c) for c in candidates)})")
    for reason, items in sorted(reasons.items(), key=lambda kv: -len(kv[1])):
        print(f"  {len(items):5d}  {reason}")
        for item in items[:10]:
            print(f"           {item}")

    # Design §5.4: where `single` takes a later candidate because the source lacks the first.
    fallbacks = [cp for cp in population
                 if st[cp][0] not in src.cmap and any(c in src.cmap for c in st[cp][1:])]
    listed = []
    for cp in fallbacks:
        later = next(c for c in st[cp][1:] if c in src.cmap)
        prefer = {later} | set(tw.get(later, []))
        listed.append(f"{chr(cp)}→ours {shown(ours.of(cp), prefer)} / ref {shown(ref.of(cp), prefer)} "
                      f"(first {chr(st[cp][0])} missing, next present {chr(later)})")
    agree_fallbacks = sum(ours.of(cp) == ref.of(cp) for cp in fallbacks)
    print(f"RESULT s2t {label}: {len(fallbacks)} code points whose first OpenCC candidate the source lacks "
          f"but a later one it has; ours agrees with the reference on {agree_fallbacks}: " + "; ".join(listed))
    report(len(population) > 0, f"s2t comparison {label} ran", f"{len(population)} code points")


# ---------------------------------------------------------------------------
# vertical


def orientation_table(path):
    ranges = []
    for line in open(path, encoding="utf-8"):
        line = line.split("#")[0].strip()
        if not line:
            continue
        span, value = (part.strip() for part in line.split(";"))
        first, _, last = span.partition("..")
        ranges.append((int(first, 16), int(last or first, 16), value))
    ranges.sort()
    starts = [r[0] for r in ranges]

    import bisect

    def lookup(cp):
        i = bisect.bisect_right(starts, cp) - 1
        return ranges[i][2] if i >= 0 and ranges[i][0] <= cp <= ranges[i][1] else "R"

    return lookup


def relation(outline, cp, src, alternates, canonical):
    """How a font's glyph for cp relates to the source glyph(s)."""
    base = src.of(cp)
    if outline == base:
        return "unchanged", None
    alternate = alternates.get(cp)
    if alternate is not None and outline == alternate:
        return "vert alternate, unturned", None
    # Small kana alternates are shifted copies of the base glyph, so both may
    # fit; the one closer to the full-width turn is what the font did.
    candidates = [(kind, turn_fit(glyph, outline)) for kind, glyph in
                  (("turned", base), ("vert alternate turned", alternate)) if glyph is not None]
    candidates = [(kind, fit) for kind, fit in candidates if fit]
    if candidates:
        return min(candidates, key=lambda c: abs(c[1][0] - canonical[0]) + abs(c[1][1] - canonical[1]))
    return "other", None


def vertical(source_path, ours_path, reference_path, orientation_path, iou_path, label):
    vo = orientation_table(orientation_path)
    src, ours, ref = Outlines(source_path), Outlines(ours_path), Outlines(reference_path)
    vert = vertical_map(src.font)
    alternates = {}
    for cp, name in src.cmap.items():
        gid = src.font.getGlyphID(name)
        if gid in vert:
            alternates[cp] = src.glyph(src.order[vert[gid]])
    iou = {}
    for line in open(iou_path, encoding="utf-8"):
        if line.strip():
            cp, value = line.split("\t")
            iou[int(cp)] = float(value)

    # The full-width quarter turn: x' = ascender − y, y' = x + ⌊(ascender + descender − UPM) / 2⌋.
    os2 = src.font["OS/2"]
    canonical = (os2.sTypoAscender,
                 (os2.sTypoAscender + os2.sTypoDescender - src.font["head"].unitsPerEm) // 2)
    population = sorted(set(ours.cmap) & set(ref.cmap) & set(src.cmap))
    groups = collections.defaultdict(list)
    pairs = collections.defaultdict(collections.Counter)
    pair_advances = collections.defaultdict(collections.Counter)
    samples = collections.defaultdict(list)
    fits = {"ours": collections.Counter(), "ref": collections.Counter()}
    advances = collections.Counter()
    same_advance = collections.Counter()
    for cp in population:
        cls = vo(cp)
        punct = unicodedata.category(chr(cp)).startswith("P")
        mine, theirs = ours.of(cp), ref.of(cp)
        exact = mine == theirs
        groups[(cls, punct)].append((exact, near(mine, theirs), iou.get(cp, 1.0 if exact else 0.0)))
        mine_rel, mine_fit = relation(mine, cp, src, alternates, canonical)
        ref_rel, ref_fit = relation(theirs, cp, src, alternates, canonical)
        if cls == "U" and not punct:
            if mine_rel == "turned":
                fits["ours"][(mine_fit, src.advance(cp))] += 1
            if ref_rel == "turned":
                fits["ref"][(ref_fit, src.advance(cp))] += 1
            advances[(ours.advance(cp), ref.advance(cp))] += 1
            if ref_rel == "turned":
                same_advance["turned"] += 1
                same_advance["advance"] += ours.advance(cp) == ref.advance(cp)
                same_advance["both"] += exact and ours.advance(cp) == ref.advance(cp)
        same_advance["all"] += 1
        same_advance["all advance"] += ours.advance(cp) == ref.advance(cp)
        pairs[(cls, punct)][(mine_rel, ref_rel)] += 1
        pair_advances[(cls, punct, mine_rel, ref_rel)][src.advance(cp)] += 1
        if not exact and len(samples[(cls, punct)]) < 12:
            samples[(cls, punct)].append(
                f"{char(cp)} IoU {iou.get(cp, float('nan')):.3f}: ours {mine_rel}"
                + (f" {mine_fit}" if mine_fit else "") + f", ref {ref_rel}" + (f" {ref_fit}" if ref_fit else ""))

    total = [item for rows in groups.values() for item in rows]

    def summary(rows):
        n = len(rows)
        exact = sum(r[0] for r in rows)
        within = sum(r[1] for r in rows)
        good = sum(r[2] >= 0.95 for r in rows)
        mean = sum(r[2] for r in rows) / n
        return (f"{n:6d} cps  outline equal {exact:6d} ({100 * exact / n:6.2f}%)  ±1 unit {within:6d} "
                f"({100 * within / n:6.2f}%)  IoU≥0.95 {good:6d} ({100 * good / n:6.2f}%)  mean IoU {mean:.4f}")

    print(f"RESULT vertical {label}: all {summary(total)}")
    for cls in ("U", "Tu", "Tr", "R"):
        for punct in (False, True):
            rows = groups.get((cls, punct))
            if not rows:
                continue
            name = f"{cls:2s} {'punctuation' if punct else 'other'}"
            print(f"RESULT vertical {label}: {name:15s} {summary(rows)}")
    for cls in ("U", "Tu", "Tr", "R"):
        for punct in (False, True):
            if (cls, punct) not in pairs:
                continue
            print(f"  {cls} {'punctuation' if punct else 'other'}: (ours, reference) treatment counts")
            for (a, b), n in pairs[(cls, punct)].most_common(8):
                widths = pair_advances[(cls, punct, a, b)].most_common(3)
                print(f"      {n:6d}  ours {a:26s} ref {b:26s} source advances "
                      + ", ".join(f"{w}×{k}" for w, k in widths))
            for line in samples[(cls, punct)]:
                print(f"         {line}")
    for who in ("ref", "ours"):
        print(f"  rotation fits for U non-punctuation glyphs ({who}): (a, b) source-advance → centre")
        for ((a, b), advance), n in fits[who].most_common(6):
            cx, cy = centre((a, b))
            print(f"      {n:6d}  x' = {a} − y, y' = x + {b}  (source advance {advance}) → centre ({cx:g}, {cy:g})")
    print("  advance widths for U non-punctuation code points (ours, reference)")
    for (a, b), n in advances.most_common(6):
        print(f"      {n:6d}  ours {a}  ref {b}")
    turned = max(1, same_advance["turned"])
    print(f"RESULT vertical {label}: Hanzi the reference turns (U non-punctuation): {same_advance['turned']}; "
          f"advance equal {same_advance['advance']} ({100 * same_advance['advance'] / turned:.2f}%), "
          f"outline and advance equal {same_advance['both']} ({100 * same_advance['both'] / turned:.2f}%); "
          f"all code points: advance equal {same_advance['all advance']}/{same_advance['all']} "
          f"({100 * same_advance['all advance'] / max(1, same_advance['all']):.2f}%)")
    report(len(population) > 0, f"vertical comparison {label} ran", f"{len(population)} code points")


def centre_only(source_path, turned_path):
    src, turned = Outlines(source_path), Outlines(turned_path)
    fits = collections.Counter()
    kinds = collections.Counter()
    for cp in sorted(set(src.cmap) & set(turned.cmap)):
        base, other = src.of(cp), turned.of(cp)
        if base == other:
            kinds["unchanged"] += 1
            continue
        fit = turn_fit(base, other)
        if fit:
            kinds["exact quarter turn"] += 1
        else:
            fit = near_turn_fit(base, other)
            if fit:
                kinds["quarter turn within ±4 units"] += 1
            elif base is not None and other is not None and base[1] != other[1]:
                kinds["different contours/points (outline redrawn or processed)"] += 1
            else:
                kinds["same structure, not a quarter turn"] += 1
        if fit:
            fits[fit] += 1
    for kind, n in kinds.most_common():
        print(f"      {n:6d}  {kind}")
    print("  turns found, (a, b) in x' = a − y, y' = x + b:")
    for (a, b), n in fits.most_common(6):
        cx, cy = centre((a, b))
        print(f"      {n:6d}  ({a}, {b}) → centre ({cx:g}, {cy:g})")
    top = fits.most_common(1)
    report(bool(top), "a dominant quarter turn exists")
    if top:
        print(f"RESULT centre {os.path.basename(turned_path)}: {top[0][1]} of {sum(fits.values())} turned glyphs "
              f"(exact or ±4) turn about {centre(top[0][0])}; "
              + ", ".join(f"{n} {kind}" for kind, n in kinds.most_common()))


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("check")
    p.add_argument("font")
    p.add_argument("--source", required=True)
    p = sub.add_parser("names")
    p.add_argument("font")
    p.add_argument("--source", required=True)
    p.add_argument("--forbid", action="append", default=[])
    p.add_argument("--weight-class", type=int)
    p = sub.add_parser("s2t")
    p.add_argument("source")
    p.add_argument("ours")
    p.add_argument("reference")
    p.add_argument("--opencc", required=True)
    p.add_argument("--label", required=True)
    p = sub.add_parser("vertical")
    p.add_argument("source")
    p.add_argument("ours")
    p.add_argument("reference")
    p.add_argument("--orientation", required=True)
    p.add_argument("--iou", required=True)
    p.add_argument("--label", required=True)
    p = sub.add_parser("centre")
    p.add_argument("source")
    p.add_argument("turned")
    args = parser.parse_args()
    if args.command == "check":
        check(args.font, args.source)
    elif args.command == "names":
        names(args.font, args.source, args.forbid, args.weight_class)
    elif args.command == "s2t":
        s2t(args.source, args.ours, args.reference, args.opencc, args.label)
    elif args.command == "vertical":
        vertical(args.source, args.ours, args.reference, args.orientation, args.iou, args.label)
    else:
        centre_only(args.source, args.turned)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
