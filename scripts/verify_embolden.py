"""fontTools oracle for `fontsmaker embolden` output (technical design D6).

Run with python3 -I. Never imports anything from the font directories.

  verify_embolden.py SOURCE OUTPUT [--renamed]

OUTPUT was written by `fontsmaker embolden SOURCE OUTPUT`, or with --renamed
by `fontsmaker build` from a recipe whose only step is embolden: decomposed,
emboldened, hinting stripped. Checks that fontTools fully decompiles it and
that everything except the outlines is what the source dictates (glyph order,
cmap, advance widths, passthrough tables), and that the recomputed tables
agree with fontTools' own recalculation. --renamed leaves the name table to
verify_phase2r.py and lets OS/2 differ in the fields rename owns.

Prints one PASS/FAIL line per check; exits 1 if any check fails.
"""

import struct
import sys

from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.ttLib import TTFont

REGENERATED = {"head", "hhea", "maxp", "OS/2", "hmtx", "loca", "glyf", "cmap", "name"}
DROPPED = {"fpgm", "prep", "cvt ", "hdmx", "LTSH", "VDMX", "DSIG"}
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
    return sum(struct.unpack(f">{len(data) // 4}I", data)) & 0xFFFFFFFF == 0xB1B0AFBA


def has_ink(glyph_set, name):
    pen = DecomposingRecordingPen(glyph_set)
    glyph_set[name].draw(pen)
    return any(op in ("lineTo", "qCurveTo", "curveTo") for op, _ in pen.value)


def without_rename_fields(os2):
    """OS/2 bytes with usWeightClass and fsSelection, which rename sets, zeroed."""
    data = bytearray(os2)
    data[4:6] = b"\0\0"
    data[62:64] = b"\0\0"
    return bytes(data)


def main():
    source_path, output_path = sys.argv[1], sys.argv[2]
    renamed = sys.argv[3:] == ["--renamed"]
    src = load_fully(source_path)
    try:
        out = load_fully(output_path)
    except Exception as error:  # report, don't traceback: the summary must show it
        report(False, "fontTools decompiles every table", repr(error))
        return
    report(True, "fontTools decompiles every table (lazy=False, ensureDecompiled, checkChecksums=2)",
           f"{len(out.keys()) - 1} tables")
    report(file_checksum_ok(output_path), "head.checkSumAdjustment balances the file")

    order = src.getGlyphOrder()
    report(order == out.getGlyphOrder(), "glyph order identical", f"{len(order)} glyphs")
    oglyf = out["glyf"]
    composites = [n for n in order if oglyf[n].isComposite()]
    report(not composites, "no composite glyphs", f"found {composites[:5]}" if composites else "")
    programs = [n for n in order if hasattr(oglyf[n], "program") and oglyf[n].program.getBytecode()]
    report(not programs, "no glyph instructions", f"found in {programs[:5]}" if programs else "")
    src_set, out_set = src.getGlyphSet(), out.getGlyphSet()
    lost = [n for n in order if has_ink(src_set, n) and not has_ink(out_set, n)]
    gained = [n for n in order if not has_ink(src_set, n) and has_ink(out_set, n)]
    inked = sum(1 for n in order if has_ink(out_set, n))
    report(not lost and not gained, "glyphs with ink keep ink, empty glyphs stay empty",
           f"{inked} inked" + (f"; lost {lost[:5]} gained {gained[:5]}" if lost or gained else ""))

    report(src.getBestCmap() == out.getBestCmap(), "cmap identical (getBestCmap)", f"{len(src.getBestCmap())} code points")
    src_uvs = next((t.uvsDict for t in src["cmap"].tables if t.format == 14), None)
    out_uvs = next((t.uvsDict for t in out["cmap"].tables if t.format == 14), None)
    report(src_uvs == out_uvs, "cmap format 14 identical", "present" if src_uvs else "absent in source")
    advances = lambda f: {n: f["hmtx"][n][0] for n in order}
    report(advances(src) == advances(out), "advance widths identical (design §5.1)")
    if renamed:
        report(without_rename_fields(src.reader["OS/2"]) == without_rename_fields(out.reader["OS/2"]),
               "OS/2 bytes identical apart from usWeightClass and fsSelection")
    else:
        names = lambda f: sorted((n.platformID, n.platEncID, n.langID, n.nameID, n.toBytes()) for n in f["name"].names)
        report(names(src) == names(out), "name records identical", f"{len(src['name'].names)} records")
        report(src.reader["OS/2"] == out.reader["OS/2"], "OS/2 bytes identical")

    passthrough = sorted(t for t in src.reader.keys() if t not in REGENERATED and t not in DROPPED)
    differing = [t for t in passthrough if t not in out.reader or src.reader[t] != out.reader[t]]
    report(not differing, "passthrough tables byte-identical", f"{passthrough}" + (f" differ: {differing}" if differing else ""))
    present = sorted(t for t in DROPPED if t in out.reader)
    report(not present, "hinting tables and DSIG absent", f"still present: {present}" if present else "")
    head_fields = lambda f: {k: v for k, v in vars(f["head"]).items()
                             if k not in ("checkSumAdjustment", "indexToLocFormat", "tableTag", "xMin", "yMin", "xMax", "yMax")}
    diff = {k: (v, head_fields(out)[k]) for k, v in head_fields(src).items() if head_fields(out)[k] != v}
    report(not diff, "head identical except checksum, loca format and bbox (created/modified kept)", str(diff) if diff else "")

    # Recomputed tables must equal what fontTools itself computes for the output.
    check = TTFont(output_path, lazy=False)
    before_maxp = {k: getattr(check["maxp"], k) for k in MAXP_OUTLINE}
    hh = check["hhea"]
    before_hhea = (hh.advanceWidthMax, hh.minLeftSideBearing, hh.minRightSideBearing, hh.xMaxExtent)
    before_head = tuple(getattr(check["head"], k) for k in ("xMin", "yMin", "xMax", "yMax"))
    lsb_before = {n: check["hmtx"][n][1] for n in order}
    check["maxp"].recalc(check)
    check["hhea"].recalc(check)
    after_maxp = {k: getattr(check["maxp"], k) for k in MAXP_OUTLINE}
    report(before_maxp == after_maxp, "maxp outline fields equal fontTools recalc", str(after_maxp))
    report(before_hhea == (hh.advanceWidthMax, hh.minLeftSideBearing, hh.minRightSideBearing, hh.xMaxExtent),
           "hhea extents equal fontTools recalc", str(before_hhea))
    after_head = tuple(getattr(check["head"], k) for k in ("xMin", "yMin", "xMax", "yMax"))
    report(before_head == after_head, "head bbox equals fontTools recalc", str(after_head))
    glyf = check["glyf"]
    bad_lsb = [n for n in order if glyf[n].numberOfContours and lsb_before[n] != glyf[n].xMin]
    report(not bad_lsb, "every lsb equals the glyph's xMin", f"mismatches {bad_lsb[:5]}" if bad_lsb else "")
    hinting = {k: getattr(out["maxp"], k) for k in MAXP_HINTING}
    report(hinting == dict.fromkeys(MAXP_HINTING, 0) | {"maxZones": 1}, "maxp hinting fields reset", str(hinting))


if __name__ == "__main__":
    main()
    print(f"{'OK' if failures == 0 else 'FAILED'}: {failures} failing checks")
    sys.exit(1 if failures else 0)
