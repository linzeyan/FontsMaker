"""fontTools oracle for the Swift sfnt reader/writer (technical design D6).

Run with python3 -I. Never imports anything from the font directories.

  verify_roundtrip.py roundtrip SOURCE OUTPUT [--decomposed] [--stripped]
      OUTPUT was written by `fontsmaker roundtrip` from SOURCE. Checks that
      fontTools fully decompiles OUTPUT and that glyph order, outlines, cmap,
      hmtx, names and passthrough tables match SOURCE.
  verify_roundtrip.py vert FONT MAP_JSON
      MAP_JSON is `fontsmaker vert-map FONT`; checks it equals the vert/vrt2
      single-substitution map fontTools reads.

Prints one PASS/FAIL line per check; exits 1 if any check fails.
"""

import argparse
import copy
import json
import struct
import sys

from fontTools.pens.recordingPen import DecomposingRecordingPen, RecordingPen
from fontTools.ttLib import TTFont

REGENERATED = {"head", "hhea", "maxp", "OS/2", "hmtx", "loca", "glyf", "cmap", "name"}
HINTING = {"fpgm", "prep", "cvt ", "hdmx", "LTSH", "VDMX"}
ALWAYS_DROPPED = {"DSIG"}
MAXP_HINTING = ("maxZones", "maxTwilightPoints", "maxStorage", "maxFunctionDefs",
                "maxInstructionDefs", "maxStackElements", "maxSizeOfInstructions")
MAXP_OUTLINE = ("numGlyphs", "maxPoints", "maxContours", "maxCompositePoints", "maxCompositeContours",
                "maxComponentElements", "maxComponentDepth")

failures = 0


def report(ok, name, detail=""):
    global failures
    if not ok:
        failures += 1
    print(f"{'PASS' if ok else 'FAIL'}  {name}{('  ' + detail) if detail else ''}")


def load_fully(path):
    """lazy=False plus ensureDecompiled: every table and every subtable is parsed."""
    font = TTFont(path, lazy=False, checkChecksums=2)
    for tag in font.keys():
        font[tag]
    font.ensureDecompiled()
    return font


def file_checksum_ok(path):
    data = open(path, "rb").read()
    data += b"\0" * (-len(data) % 4)
    total = sum(struct.unpack(f">{len(data) // 4}I", data)) & 0xFFFFFFFF
    return total == 0xB1B0AFBA


def simple_outline(glyph):
    coords = [tuple(c) for c in glyph.coordinates]
    flags = [f & 0x01 for f in glyph.flags]
    overlap = bool(glyph.flags[0] & 0x40) if len(glyph.flags) else False
    return coords, list(glyph.endPtsOfContours), flags, overlap


def components(glyph):
    return [
        (c.glyphName, getattr(c, "x", None), getattr(c, "y", None), getattr(c, "firstPt", None),
         getattr(c, "secondPt", None), c.flags, getattr(c, "transform", None))
        for c in glyph.components
    ]


def flattened(glyph, glyf):
    coords, end_pts, flags = glyph.getCoordinates(glyf)
    return [tuple(c) for c in coords], list(end_pts), [f & 1 for f in flags]


def program(glyph):
    return glyph.program.getBytecode() if hasattr(glyph, "program") else b""


def pens_match(expected, actual, tolerance=0.5 + 1e-9):
    """Same drawing operations; coordinates equal up to rounding to integers."""
    if len(expected) != len(actual):
        return False
    for (op_a, pts_a), (op_b, pts_b) in zip(expected, actual):
        if op_a != op_b or len(pts_a) != len(pts_b):
            return False
        for pa, pb in zip(pts_a, pts_b):
            if (pa is None) != (pb is None):
                return False
            if pa is not None and (abs(pa[0] - pb[0]) > tolerance or abs(pa[1] - pb[1]) > tolerance):
                return False
    return True


def verify_roundtrip(source_path, output_path, decomposed, stripped):
    src = load_fully(source_path)
    try:
        out = load_fully(output_path)
    except Exception as error:  # report, don't traceback: the summary must show it
        report(False, "fontTools decompiles every table", repr(error))
        return
    report(True, "fontTools decompiles every table", f"{len(out.keys()) - 1} tables, per-table checksums verified")
    report(file_checksum_ok(output_path), "head.checkSumAdjustment balances the file")

    order = src.getGlyphOrder()
    report(order == out.getGlyphOrder(), "glyph order identical", f"{len(order)} glyphs")

    sglyf, oglyf = src["glyf"], out["glyf"]
    src_set, out_set = src.getGlyphSet(), out.getGlyphSet()
    bad_simple, bad_components, bad_flat, bad_decomposed, bad_programs = [], [], [], [], []
    composites = 0
    for name in order:
        sg, og = sglyf[name], oglyf[name]
        if sg.isComposite():
            composites += 1
            if decomposed:
                expected = DecomposingRecordingPen(src_set)
                src_set[name].draw(expected)
                actual = RecordingPen()
                out_set[name].draw(actual)
                if og.isComposite() or not pens_match(expected.value, actual.value):
                    bad_decomposed.append(name)
                continue
            if not og.isComposite() or components(sg) != components(og):
                bad_components.append(name)
            elif flattened(sg, sglyf) != flattened(og, oglyf):
                bad_flat.append(name)
        elif sg.numberOfContours == 0:
            if og.numberOfContours != 0:
                bad_simple.append(name)
        elif og.isComposite() or simple_outline(sg) != simple_outline(og):
            bad_simple.append(name)
        expected_program = b"" if (stripped or (decomposed and sg.isComposite())) else program(sg)
        if program(og) != expected_program:
            bad_programs.append(name)

    report(not bad_simple, "simple glyph outlines identical (coordinates, endPts, on-curve flags)",
           f"mismatches: {bad_simple[:5]}" if bad_simple else "")
    if decomposed:
        out_composites = sum(1 for n in order if oglyf[n].isComposite())
        report(out_composites == 0, "no composites after --decompose", f"{composites} in source, {out_composites} in output")
        report(not bad_decomposed, "decomposed glyphs match DecomposingRecordingPen of source (to rounding)",
               f"mismatches: {bad_decomposed[:5]}" if bad_decomposed else f"{composites} glyphs")
    else:
        report(not bad_components, "composite glyphs identical as components",
               f"mismatches: {bad_components[:5]}" if bad_components else f"{composites} glyphs")
        report(not bad_flat, "composite glyphs identical as decomposed outlines",
               f"mismatches: {bad_flat[:5]}" if bad_flat else "")
    report(not bad_programs, "glyph instructions " + ("removed" if stripped else "preserved"),
           f"mismatches: {bad_programs[:5]}" if bad_programs else "")

    report(src.getBestCmap() == out.getBestCmap(), "cmap identical (getBestCmap)", f"{len(src.getBestCmap())} code points")
    src_uvs = next((t.uvsDict for t in src["cmap"].tables if t.format == 14), None)
    out_uvs = next((t.uvsDict for t in out["cmap"].tables if t.format == 14), None)
    report(src_uvs == out_uvs, "cmap format 14 identical", "present" if src_uvs else "absent in source")
    layout = sorted((t.platformID, t.platEncID, t.format) for t in out["cmap"].tables)
    print(f"INFO  output cmap subtables {layout}")

    report(src["hmtx"].metrics == out["hmtx"].metrics, "hmtx identical")
    names = lambda f: sorted((n.platformID, n.platEncID, n.langID, n.nameID, n.toBytes()) for n in f["name"].names)
    report(names(src) == names(out), "name records identical", f"{len(src['name'].names)} records")

    dropped = ALWAYS_DROPPED | (HINTING if stripped else set())
    passthrough = sorted(t for t in src.reader.keys() if t not in REGENERATED and t not in dropped)
    same = lambda tag: tag in out.reader and src.reader[tag] == out.reader[tag]
    differing = [t for t in passthrough if not same(t)]
    report(not differing, "passthrough tables byte-identical", f"{passthrough}" + (f" differ: {differing}" if differing else ""))
    for required in ("GSUB", "GPOS", "vmtx"):
        if required in src.reader:
            report(same(required), f"{required} bytes identical")
    present = sorted(t for t in dropped if t in out.reader)
    report(not present, "dropped tables absent", f"{sorted(dropped)}" + (f" still present: {present}" if present else ""))
    report(src.reader["OS/2"] == out.reader["OS/2"], "OS/2 bytes identical")

    head_fields = lambda f: {k: v for k, v in vars(f["head"]).items() if k not in ("checkSumAdjustment", "indexToLocFormat", "tableTag")}
    diff = {k: (v, head_fields(out)[k]) for k, v in head_fields(src).items() if head_fields(out)[k] != v}
    report(not diff, "head identical except checkSumAdjustment/indexToLocFormat (created/modified kept)", str(diff) if diff else "")

    # Recomputed tables must equal what fontTools itself computes for the output.
    check = TTFont(output_path, lazy=False)
    before_maxp = {k: getattr(check["maxp"], k) for k in MAXP_OUTLINE}
    hh = check["hhea"]
    before_hhea = (hh.advanceWidthMax, hh.minLeftSideBearing, hh.minRightSideBearing, hh.xMaxExtent)
    before_head = tuple(getattr(check["head"], k) for k in ("xMin", "yMin", "xMax", "yMax"))
    check["maxp"].recalc(check)
    check["hhea"].recalc(check)
    after_maxp = {k: getattr(check["maxp"], k) for k in MAXP_OUTLINE}
    report(before_maxp == after_maxp, "maxp outline fields equal fontTools recalc", str(after_maxp))
    report(before_hhea == (hh.advanceWidthMax, hh.minLeftSideBearing, hh.minRightSideBearing, hh.xMaxExtent),
           "hhea extents equal fontTools recalc", str(before_hhea))
    after_head = tuple(getattr(check["head"], k) for k in ("xMin", "yMin", "xMax", "yMax"))
    report(before_head == after_head, "head bbox equals fontTools recalc", str(after_head))
    hinting = {k: getattr(out["maxp"], k) for k in MAXP_HINTING}
    if stripped:
        expected_hinting = dict.fromkeys(MAXP_HINTING, 0) | {"maxZones": 1}
    else:
        expected_hinting = {k: getattr(src["maxp"], k) for k in MAXP_HINTING}
    report(hinting == expected_hinting, "maxp hinting fields " + ("reset" if stripped else "preserved"), str(hinting))


def vertical_map(font):
    order = font.getGlyphOrder()
    gid = {n: i for i, n in enumerate(order)}
    gsub = font["GSUB"].table if "GSUB" in font else None
    result = {}
    if gsub is None or gsub.FeatureList is None:
        return result
    indices = sorted({i for fr in gsub.FeatureList.FeatureRecord if fr.FeatureTag in ("vert", "vrt2")
                      for i in fr.Feature.LookupListIndex})
    for index in indices:
        lookup = gsub.LookupList.Lookup[index]
        for sub in lookup.SubTable:
            if lookup.LookupType == 7:
                sub = sub.ExtSubTable
            if sub.LookupType == 1:
                for src, dst in sub.mapping.items():
                    result.setdefault(gid[src], gid[dst])
    return result


def verify_vert(font_path, json_path):
    expected = vertical_map(TTFont(font_path, lazy=False))
    actual = {int(k): v for k, v in json.load(open(json_path)).items()}
    missing = sorted(set(expected) - set(actual))
    extra = sorted(set(actual) - set(expected))
    wrong = sorted(k for k in set(expected) & set(actual) if expected[k] != actual[k])
    report(expected == actual, "vert/vrt2 map equals fontTools",
           f"{len(expected)} substitutions" + (f" missing {missing[:5]} extra {extra[:5]} wrong {wrong[:5]}"
                                               if expected != actual else ""))


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    rt = sub.add_parser("roundtrip")
    rt.add_argument("source")
    rt.add_argument("output")
    rt.add_argument("--decomposed", action="store_true")
    rt.add_argument("--stripped", action="store_true")
    vt = sub.add_parser("vert")
    vt.add_argument("font")
    vt.add_argument("map_json")
    args = parser.parse_args()
    if args.command == "roundtrip":
        verify_roundtrip(args.source, args.output, args.decomposed, args.stripped)
    else:
        verify_vert(args.font, args.map_json)
    print(f"{'OK' if failures == 0 else 'FAILED'}: {failures} failing checks")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
