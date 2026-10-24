"""fontTools oracle for import normalization (plan Phase 4a).

Run with python3 -I. Never imports anything from the font directories.

  verify_normalize.py compare OURS REFERENCE [--face N] [--every K] [--json OUT]
      OURS was written by `fontsmaker roundtrip` from a CFF, variable or
      collection font. REFERENCE is the same design as a static font: a
      static .ttf, the CFF source itself, or a fontTools instancer output.
      Checks that fontTools fully decompiles OURS, that it is a plain static
      TrueType font, and compares glyph by glyph (by glyph ID): outline
      distance, contour direction, advance, cmap; lists every differing
      hhea / OS/2 / post / head field. --every K compares every K-th glyph
      only (outline distance is the slow part on a 37,000-glyph font).
      --location wght=700,opsz=12: REFERENCE is the variable font itself,
      blended by fontTools in floating point (no rounding anywhere), the
      exact outline both ours and the instancer's approximate.
  verify_normalize.py instance VARIABLE OUT AXIS=VALUE...
      Static instance by fontTools varLib.instancer, the oracle for a
      variable font converted at the same axis values.
  verify_normalize.py parse FONT
      fontTools fully decompiles FONT; prints its glyph count.
  verify_normalize.py otf2ttf CFF OUT
      fontTools' own CFF → TrueType conversion (cu2qu at 1 unit, reversed
      to TrueType direction), the oracle for a converted CFF font.
  verify_normalize.py cmap4 FONT
      Size of FONT's BMP cmap as format 4: the subtable in FONT, fontTools'
      encoding, and the encoding before Phase 4a (one segment per run of
      code points), which fails past 65,535 bytes.
  verify_normalize.py points OURS REFERENCE [--face N]
      Both TrueType: every glyph's points, contour ends and on-curve flags
      compared exactly; the glyphs that differ get the outline distance.
      Covers all glyphs of a CJK font, where `compare` has to sample.
  verify_normalize.py vertical-sample FONT OUT.txt STEP
      Text for scripts/ct_vertical_ink.swift, one character per line: every
      STEP-th mapped CJK ideograph of FONT plus the punctuation vertical
      forms apply to.
  verify_normalize.py vertical-ink SOURCE.jsonl OURS.jsonl TEXT
      Ink boxes from ct_vertical_ink for the source and the converted font:
      fails when any edge moved by more than 1 pixel (1 unit at 1000 pt).
  verify_normalize.py outliers OURS.json REFERENCE.json
      Both from `compare --json` against the same static font: fails when
      OURS has glyphs over 1 u that REFERENCE (an oracle compared the same
      way) does not, i.e. differences that are ours rather than the font's.

Prints one PASS/FAIL line per check (INFO lines are measurements, not
checks); exits 1 if any check fails.
"""

import argparse
import json
import math
import struct
import sys

import numpy as np
from fontTools.pens.basePen import BasePen
from fontTools.ttLib import TTFont
from scipy.spatial import cKDTree

# Tables a converted font must not keep: the outlines and variations it no
# longer has, and hinting for outlines it no longer has.
DROPPED = {"CFF ", "CFF2", "VORG", "fvar", "gvar", "avar", "cvar", "HVAR", "VVAR", "MVAR", "STAT", "DSIG",
           "fpgm", "prep", "cvt ", "hdmx", "LTSH", "VDMX"}
# Curves are flattened to points this close together, so a nearest-point
# distance overstates the true distance to the curve by at most half of it.
SPACING = 0.2

failures = 0


def report(ok, name, detail=""):
    global failures
    if not ok:
        failures += 1
    print(f"{'PASS' if ok else 'FAIL'}  {name}{('  ' + detail) if detail else ''}")


def load_fully(path, face=0):
    font = TTFont(path, lazy=False, checkChecksums=2, fontNumber=face)
    for tag in font.keys():
        font[tag]
    font.ensureDecompiled()
    return font


def file_checksum_ok(path):
    data = open(path, "rb").read()
    data += b"\0" * (-len(data) % 4)
    total = sum(struct.unpack(f">{len(data) // 4}I", data)) & 0xFFFFFFFF
    return total == 0xB1B0AFBA


class FlattenPen(BasePen):
    """Contours as dense point lists; BasePen splits TrueType quadratic runs
    (implied on-curve points) and hands every curve over as one segment."""

    def __init__(self, glyphSet):
        super().__init__(glyphSet)
        self.contours = []
        self.current = None

    def _moveTo(self, pt):
        self.current = [pt]
        self.contours.append(self.current)

    def _lineTo(self, pt):
        self._sample(lambda t, a=self._getCurrentPoint(), b=pt: (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t),
                     math.dist(self._getCurrentPoint(), pt))

    def _curveToOne(self, p1, p2, p3):
        p0 = self._getCurrentPoint()
        length = math.dist(p0, p1) + math.dist(p1, p2) + math.dist(p2, p3)

        def at(t):
            u = 1 - t
            return tuple(u * u * u * p0[i] + 3 * u * u * t * p1[i] + 3 * u * t * t * p2[i] + t * t * t * p3[i]
                         for i in (0, 1))
        self._sample(at, length)

    def _qCurveToOne(self, p1, p2):
        p0 = self._getCurrentPoint()
        length = math.dist(p0, p1) + math.dist(p1, p2)

        def at(t):
            u = 1 - t
            return tuple(u * u * p0[i] + 2 * u * t * p1[i] + t * t * p2[i] for i in (0, 1))
        self._sample(at, length)

    def _closePath(self):
        start = self.current[0]
        if self.current[-1] != start:
            self._lineTo(start)

    def _endPath(self):
        pass

    def _sample(self, at, length):
        steps = max(1, math.ceil(length / SPACING))
        self.current.extend(at(i / steps) for i in range(1, steps + 1))


def glyph_contours(glyph_set, name):
    pen = FlattenPen(glyph_set)
    glyph_set[name].draw(pen)
    return [np.array(c) for c in pen.contours if len(c) > 1]


def signed_area(contours):
    """Shoelace sum over all contours, y up: TrueType ink is clockwise (negative)."""
    total = 0.0
    for c in contours:
        x, y = c[:, 0], c[:, 1]
        total += 0.5 * float(np.dot(x, np.roll(y, -1)) - np.dot(y, np.roll(x, -1)))
    return total


def hausdorff(a, b):
    if not a and not b:
        return 0.0
    if not a or not b:
        return math.inf
    pa = np.concatenate(a)
    pb = np.concatenate(b)
    da, _ = cKDTree(pb).query(pa)
    db, _ = cKDTree(pa).query(pb)
    return float(max(da.max(), db.max()))


def is_cff(font):
    return "CFF " in font or "CFF2" in font


def compare(args):
    ours = load_fully(args.ours)
    report(True, "fontTools decompiles every table of OURS")
    report(file_checksum_ok(args.ours), "OURS whole-file checksum is 0xB1B0AFBA")
    reference = TTFont(args.reference, lazy=False, fontNumber=args.face)

    left = sorted(DROPPED & set(ours.keys()))
    report(not left, "no CFF/variation/hinting tables left", ", ".join(left))
    report("glyf" in ours and "loca" in ours, "OURS has glyf/loca")
    report(ours.sfntVersion == "\x00\x01\x00\x00", "sfntVersion 0x00010000", repr(ours.sfntVersion))
    report(ours["maxp"].tableVersion == 0x00010000, "maxp version 1.0", hex(ours["maxp"].tableVersion))
    kept = sorted((set(reference.keys()) - DROPPED - {"GlyphOrder", "glyf", "loca"}) - set(ours.keys()))
    report(not kept, "every other reference table is present in OURS", ", ".join(kept))

    order_ours = ours.getGlyphOrder()
    order_ref = reference.getGlyphOrder()
    report(len(order_ours) == len(order_ref), "glyph count", f"{len(order_ours)} vs {len(order_ref)}")
    count = min(len(order_ours), len(order_ref))

    cmap_ours = {cp: ours.getGlyphID(n) for cp, n in ours.getBestCmap().items()}
    cmap_ref = {cp: reference.getGlyphID(n) for cp, n in reference.getBestCmap().items()}
    diff = sorted(set(cmap_ours.items()) ^ set(cmap_ref.items()))
    report(not diff, "cmap (code point → glyph ID) identical", f"{len(cmap_ours)} code points; {len(diff)} differ")

    # With --location the reference is the variable font itself, blended
    # in floating point by fontTools (gvar with IUP, HVAR): no rounding at all.
    location = dict((k, float(v)) for k, v in (item.split("=") for item in args.location.split(","))) \
        if args.location else None
    set_ours = ours.getGlyphSet()
    set_ref = reference.getGlyphSet(location=location) if location else reference.getGlyphSet()
    if location:
        gaps = [abs(ours["hmtx"][order_ours[g]][0] - set_ref[order_ref[g]].width) for g in range(count)]
        adv_diff = [g for g in range(count) if gaps[g] > 0.5]
        report(not adv_diff, "advance widths are the float advances rounded (|ours - exact| ≤ 0.5)",
               f"max |ours - exact| {max(gaps):.3f}; {len(adv_diff)} of {count} beyond 0.5")
    else:
        adv_diff = [g for g in range(count)
                    if ours["hmtx"][order_ours[g]][0] != reference["hmtx"][order_ref[g]][0]]
        report(not adv_diff, "advance widths identical",
               f"{len(adv_diff)} of {count} differ" + (f", first gid {adv_diff[:5]}" if adv_diff else ""))

    if "vmtx" in reference:
        vdiff = [g for g in range(count) if "vmtx" not in ours
                 or ours["vmtx"][order_ours[g]] != reference["vmtx"][order_ref[g]]]
        print(f"INFO  vmtx entries differing from the reference: {len(vdiff)} of {count}"
              + (f" (first gid {vdiff[:5]})" if vdiff else ""))

    expect_flip = is_cff(reference)
    distances = []
    direction_wrong = []
    sampled = range(0, count, args.every)
    for g in sampled:
        a = glyph_contours(set_ours, order_ours[g])
        b = glyph_contours(set_ref, order_ref[g])
        distances.append((hausdorff(a, b), g))
        area_a, area_b = signed_area(a), signed_area(b)
        if abs(area_b) > 1 and (area_a * area_b > 0) == expect_flip:
            direction_wrong.append(g)
    values = np.array([d for d, _ in distances])
    worst = sorted(distances, reverse=True)[:8]
    over = int((values > 1.0).sum())
    detail = (f"{len(values)} glyphs; max {values.max():.3f} u, p99 {np.percentile(values, 99):.3f}, "
              f"p50 {np.percentile(values, 50):.3f}; {over} over 1 u; worst (u, gid) "
              + ", ".join(f"{d:.2f}@{g}" for d, g in worst))
    report(over == 0, "outline distance ≤ 1 u (symmetric Hausdorff, sampled every 0.2 u)", detail)
    report(not direction_wrong, "contour direction is TrueType's (clockwise ink)"
           + (" — reversed from CFF" if expect_flip else ""),
           f"{len(direction_wrong)} glyphs wrong" + (f": {direction_wrong[:10]}" if direction_wrong else ""))

    metric_diffs = []
    fields = {
        "hhea": ["ascent", "descent", "lineGap", "advanceWidthMax", "minLeftSideBearing", "minRightSideBearing",
                 "xMaxExtent", "caretSlopeRise", "caretSlopeRun", "caretOffset"],
        "OS/2": ["xAvgCharWidth", "usWeightClass", "usWidthClass", "fsType", "ySubscriptXSize",
                 "ySubscriptYSize", "ySubscriptXOffset", "ySubscriptYOffset", "ySuperscriptXSize",
                 "ySuperscriptYSize", "ySuperscriptXOffset", "ySuperscriptYOffset", "yStrikeoutSize",
                 "yStrikeoutPosition", "sFamilyClass", "fsSelection", "usFirstCharIndex", "usLastCharIndex",
                 "sTypoAscender", "sTypoDescender", "sTypoLineGap", "usWinAscent", "usWinDescent",
                 "sxHeight", "sCapHeight", "usDefaultChar", "usBreakChar", "usMaxContext"],
        "post": ["italicAngle", "underlinePosition", "underlineThickness", "isFixedPitch"],
        "head": ["unitsPerEm", "xMin", "yMin", "xMax", "yMax", "macStyle", "lowestRecPPEM", "fontRevision"],
        "vhea": ["ascent", "descent", "lineGap", "advanceHeightMax"],
    }
    for tag, names in fields.items():
        if tag not in reference or tag not in ours:
            continue
        for name in names:
            a = getattr(ours[tag], name, None)
            b = getattr(reference[tag], name, None)
            if a != b:
                metric_diffs.append(f"{tag}.{name} ours {a} reference {b}")
    print(f"INFO  header fields differing from the reference: {len(metric_diffs)}")
    for line in metric_diffs:
        print(f"INFO    {line}")

    if args.json:
        with open(args.json, "w") as stream:
            json.dump({"glyphs": count, "compared": len(values), "max": values.max(),
                   "overGlyphs": sorted(g for d, g in distances if d > 1.0),
                       "p99": float(np.percentile(values, 99)), "over1": over,
                       "worst": [[d, g] for d, g in worst], "advanceDiffs": len(adv_diff),
                       "cmapDiffs": len(diff), "metricDiffs": metric_diffs}, stream, indent=1)


def instance(args):
    from fontTools.varLib import instancer
    location = {}
    for item in args.location:
        tag, value = item.split("=")
        location[tag] = float(value)
    font = TTFont(args.variable)
    static = instancer.instantiateVariableFont(font, location, static=True)
    static.save(args.out)
    print(f"wrote {args.out} at {location}")


def parse(args):
    font = load_fully(args.font)
    print(f"PASS  fontTools decompiles every table ({len(font.getGlyphOrder())} glyphs)")


def otf2ttf(args):
    from fontTools.pens.cu2quPen import Cu2QuPen
    from fontTools.pens.ttGlyphPen import TTGlyphPen
    from fontTools.ttLib import newTable
    font = TTFont(args.cff)
    order = font.getGlyphOrder()
    glyph_set = font.getGlyphSet()
    glyf = newTable("glyf")
    glyf.glyphOrder = order
    glyf.glyphs = {}
    for name in order:
        pen = TTGlyphPen(glyph_set)
        glyph_set[name].draw(Cu2QuPen(pen, 1.0, reverse_direction=True))
        glyf[name] = pen.glyph()
    font["glyf"] = glyf
    # TrueType places a glyph by its glyf xMin, which counts off-curve
    # points; the CFF lsb is the curve's own bound. Left as is, the glyph
    # would be drawn shifted by the difference wherever cu2qu put an
    # off-curve point outside the curve.
    for name in order:
        glyph = glyf[name]
        glyph.recalcBounds(glyf)
        advance, _ = font["hmtx"][name]
        font["hmtx"][name] = (advance, glyph.xMin if glyph.numberOfContours else 0)
    font["loca"] = newTable("loca")
    font["maxp"] = maxp = newTable("maxp")
    maxp.tableVersion = 0x00010000
    for attr in ("maxZones", "maxTwilightPoints", "maxStorage", "maxFunctionDefs", "maxInstructionDefs",
                 "maxStackElements", "maxSizeOfInstructions", "maxComponentElements"):
        setattr(maxp, attr, 0)
    maxp.maxZones = 1
    for tag in ("CFF ", "VORG"):
        if tag in font:
            del font[tag]
    font.sfntVersion = "\000\001\000\000"
    font.save(args.out)
    print(f"wrote {args.out}")


def cmap4(args):
    from fontTools.ttLib.tables._c_m_a_p import cmap_format_4
    font = TTFont(args.font)
    bmp = {cp: font.getGlyphID(n) for cp, n in font.getBestCmap().items() if cp <= 0xFFFF}
    in_font = [t for t in font["cmap"].tables if t.format == 4]
    print(f"INFO  BMP code points: {len(bmp)}")
    if in_font:
        raw = font.reader["cmap"]
        offsets = [struct.unpack(">HHI", raw[4 + 8 * i:12 + 8 * i])[2] for i in range(struct.unpack(">H", raw[2:4])[0])]
        lengths = sorted({struct.unpack(">H", raw[o + 2:o + 4])[0] for o in offsets
                          if struct.unpack(">H", raw[o:o + 2])[0] == 4})
        print(f"INFO  format 4 subtable as stored in the font: {lengths} bytes")
    sub = cmap_format_4(4)
    sub.platformID, sub.platEncID, sub.language = 3, 1, 0
    sub.cmap = {cp: font.getGlyphOrder()[g] for cp, g in bmp.items()}
    print(f"INFO  fontTools format 4 encoding: {len(sub.compile(font))} bytes")
    # The encoder before Phase 4a: one segment per run of consecutive code
    # points, idDelta if the glyph IDs run along, else a glyphIdArray slice.
    codes = sorted(bmp)
    segments, slots, i = 0, 0, 0
    while i < len(codes):
        j = i
        while j + 1 < len(codes) and codes[j + 1] == codes[j] + 1:
            j += 1
        if any(bmp[codes[k]] - codes[k] != bmp[codes[i]] - codes[i] for k in range(i, j + 1)):
            slots += j - i + 1
        segments += 1
        i = j + 1
    if not codes or codes[-1] != 0xFFFF:
        segments += 1
    old = 16 + 8 * segments + 2 * slots
    print(f"INFO  pre-Phase-4a encoding: {old} bytes ({segments} segments, {slots} glyphIdArray slots)"
          f" — {'over' if old > 65535 else 'within'} the 65,535-byte limit")


def points(args):
    ours = TTFont(args.ours)
    reference = TTFont(args.reference, fontNumber=args.face)
    order_ours, order_ref = ours.getGlyphOrder(), reference.getGlyphOrder()
    report(len(order_ours) == len(order_ref), "glyph count", f"{len(order_ours)} vs {len(order_ref)}")
    differ = []
    for g in range(min(len(order_ours), len(order_ref))):
        a = ours["glyf"][order_ours[g]].getCoordinates(ours["glyf"])
        b = reference["glyf"][order_ref[g]].getCoordinates(reference["glyf"])
        if list(a[0]) != list(b[0]) or list(a[1]) != list(b[1]) or [f & 1 for f in a[2]] != [f & 1 for f in b[2]]:
            differ.append(g)
    print(f"INFO  {len(order_ours) - len(differ)} glyphs point for point identical, {len(differ)} differ")
    set_ours, set_ref = ours.getGlyphSet(), reference.getGlyphSet()
    distances = [(hausdorff(glyph_contours(set_ours, order_ours[g]), glyph_contours(set_ref, order_ref[g])), g)
                 for g in differ]
    for d, g in distances:
        print(f"INFO    gid {g} ({order_ours[g]}): {d:.3f} u")
    over = [g for d, g in distances if d > 1.0]
    report(not over, "every differing glyph is within 1 u", f"{len(over)} over" + (f": {over[:20]}" if over else ""))


def vertical_sample(args):
    font = TTFont(args.font)
    cmap = font.getBestCmap()
    cjk = [cp for cp in sorted(cmap) if 0x4E00 <= cp <= 0x9FFF][::args.step]
    punctuation = [cp for cp in map(ord, "、。，．：；！？「」『』（）《》〈〉【】〔〕—…ー～") if cp in cmap]
    with open(args.out, "w") as stream:
        for cp in cjk + punctuation:
            stream.write(chr(cp) + "\n")
    print(f"INFO  {len(cjk) + len(punctuation)} characters ({len(cjk)} ideographs, {len(punctuation)} punctuation)")


def vertical_ink(args):
    text = [line.rstrip("\n") for line in open(args.text)]
    source = [json.loads(line) for line in open(args.source)]
    ours = [json.loads(line) for line in open(args.ours)]
    report(len(source) == len(text) == len(ours), "one ink box per character")
    one_sided = [char for char, a, b in zip(text, source, ours) if (a is None) != (b is None)]
    report(not one_sided, "every character draws in both fonts or in neither", "".join(one_sided[:20]))
    moved = sorted(((max(abs(p - q) for p, q in zip(a, b)), char, a, b)
                    for char, a, b in zip(text, source, ours) if a is not None and b is not None), reverse=True)
    over = [m for m in moved if m[0] > 1]
    report(not over, "ink in vertical text within 1 u of the source (every box edge)",
           f"{len(moved)} characters; max {moved[0][0] if moved else 0} px; {len(over)} over 1 px")
    for distance, char, a, b in moved[:8]:
        print(f"INFO    {char} {distance} px: source {a} ours {b}")


def outliers(args):
    ours = set(json.load(open(args.ours))["overGlyphs"])
    reference = set(json.load(open(args.reference))["overGlyphs"])
    own = sorted(ours - reference)
    report(not own, "every glyph over 1 u is also over 1 u for the oracle (the font's own difference)",
           f"ours {len(ours)}, oracle {len(reference)}, only ours {len(own)}" + (f": {own[:20]}" if own else ""))


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    c = sub.add_parser("compare")
    c.add_argument("ours")
    c.add_argument("reference")
    c.add_argument("--face", type=int, default=-1)
    c.add_argument("--every", type=int, default=1)
    c.add_argument("--json")
    c.add_argument("--location", help="REFERENCE is variable: compare with it blended at e.g. wght=700,opsz=12")
    i = sub.add_parser("instance")
    i.add_argument("variable")
    i.add_argument("out")
    i.add_argument("location", nargs="+")
    p = sub.add_parser("parse")
    p.add_argument("font")
    o = sub.add_parser("otf2ttf")
    o.add_argument("cff")
    o.add_argument("out")
    m = sub.add_parser("cmap4")
    m.add_argument("font")
    q = sub.add_parser("points")
    q.add_argument("ours")
    q.add_argument("reference")
    q.add_argument("--face", type=int, default=-1)
    vs = sub.add_parser("vertical-sample")
    vs.add_argument("font")
    vs.add_argument("out")
    vs.add_argument("step", type=int)
    vi = sub.add_parser("vertical-ink")
    vi.add_argument("source")
    vi.add_argument("ours")
    vi.add_argument("text")
    x = sub.add_parser("outliers")
    x.add_argument("ours")
    x.add_argument("reference")
    args = parser.parse_args()
    {"compare": compare, "instance": instance, "parse": parse, "otf2ttf": otf2ttf, "cmap4": cmap4,
     "points": points, "vertical-sample": vertical_sample, "vertical-ink": vertical_ink,
     "outliers": outliers}[args.command](args)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
