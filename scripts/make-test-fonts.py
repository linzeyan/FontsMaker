"""Generate the small synthetic fonts committed under Tests/FontsMakerKitTests/Fixtures.

Run with:  python3 -I scripts/make-test-fonts.py [OUTPUT_DIR]

Besides the fonts, this writes synthetic-expected.json: facts about
synthetic.ttf computed by fontTools (cmap, decomposed composites, vert map,
name records, ...). The Swift tests compare the engine against it, so the
oracle is fontTools rather than numbers typed by hand.

Output is deterministic: fixed head timestamps, no wall-clock anywhere.
"""

import array
import json
import struct
import sys
from pathlib import Path

from fontTools.fontBuilder import FontBuilder
from fontTools.misc.roundTools import otRound
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTCollection, TTFont, newTable
from fontTools.ttLib.tables import ttProgram
from fontTools.ttLib.tables._g_l_y_f import Glyph, GlyphCoordinates

FIXTURES = Path(__file__).resolve().parent.parent / "Tests" / "FontsMakerKitTests" / "Fixtures"
TIMESTAMP = 3_800_000_000  # seconds since 1904; any fixed value keeps output stable

OFL_DESCRIPTION = (
    "This Font Software is licensed under the SIL Open Font License, Version 1.1. "
    "This license is available with a FAQ at: https://openfontlicense.org"
)

# PUSHB[0] 0, POP — valid bytecode that does nothing.
GLYPH_PROGRAM = bytes([0xB0, 0x00, 0x21])
# PUSHB[0] 0, FDEF, ENDF — defines function 0.
FPGM_PROGRAM = bytes([0xB0, 0x00, 0x2C, 0x2D])
PREP_PROGRAM = bytes([0xB0, 0x01, 0x21])


def program(data):
    p = ttProgram.Program()
    p.fromBytecode(data)
    return p


def contour_glyph(contours, components=(), instructions=b""):
    """contours: list of [(x, y, on_curve)]; components: [(name, (xx, xy, yx, yy, dx, dy))].

    Simple glyphs are built point by point so the stored point order is exactly
    what is written here; composites go through TTGlyphPen, which picks the
    scale / x-y scale / 2x2 encoding from the transform values.
    """
    if components:
        assert not contours
        # The pen only checks that component names exist in its glyph set.
        pen = TTGlyphPen({name for name, _ in components})
        for name, transform in components:
            pen.addComponent(name, transform)
        glyph = pen.glyph()
    else:
        glyph = Glyph()
        coordinates, flags, end_points = [], bytearray(), []
        for contour in contours:
            for x, y, on_curve in contour:
                coordinates.append((x, y))
                flags.append(1 if on_curve else 0)
            end_points.append(len(coordinates) - 1)
        glyph.numberOfContours = len(end_points)
        if end_points:
            glyph.coordinates = GlyphCoordinates(coordinates)
            glyph.flags = flags
            glyph.endPtsOfContours = end_points
    glyph.program = program(instructions)
    return glyph


def rect(x0, y0, x1, y1, clockwise=True):
    pts = [(x0, y0, True), (x0, y1, True), (x1, y1, True), (x1, y0, True)]
    return pts if clockwise else list(reversed(pts))


def set_fixed_head(fb):
    fb.font.recalcTimestamp = False
    fb.updateHead(created=TIMESTAMP, modified=TIMESTAMP)


def build_synthetic(path):
    order = [
        ".notdef", "space", "A", "ring", "uni4E00", "uni4E00.alt", "u20000",
        "uni3001", "uni3002", "uniFF08", "uniFF09",
        "uniFF09.vert", "uni3001.vert", "uniFF08.vert", "uni3002.vert",
        "uni2014", "uni2014.vert",
        "Aring", "A.small", "A.wide", "A.slant", "Aring.nested", "Aring.deep", "A.spaced",
    ]
    cmap = {
        0x20: "space", 0x41: "A", 0xC5: "Aring",
        # One glyph shared by three code points, as CJK fonts do for radicals.
        0x4E00: "uni4E00", 0x2F00: "uni4E00", 0x31D0: "uni4E00",
        0x20000: "u20000",
        0x3001: "uni3001", 0x3002: "uni3002", 0xFF08: "uniFF08", 0xFF09: "uniFF09",
        0x2014: "uni2014",
        0xE000: "A.small", 0xE001: "A.wide", 0xE002: "A.slant",
        0xE003: "Aring.nested", 0xE004: "Aring.deep", 0xE005: "A.spaced",
    }
    a_shape = [
        # Off-curve runs with implied on-curve points, short and long deltas.
        [(20, 0, True), (240, 700, True), (360, 700, True), (580, 0, True), (450, 0, True),
         (400, 180, False), (300, 200, False), (200, 180, False), (150, 0, True)],
        [(220, 300, True), (300, 560, True), (380, 300, True)],
    ]
    ring_shape = [[(0, 100, True), (0, 200, False), (100, 200, True), (200, 200, False),
                   (200, 100, True), (200, 0, False), (100, 0, True), (0, 0, False)]]
    glyphs = {
        ".notdef": contour_glyph([rect(50, 0, 450, 700), rect(100, 50, 400, 650, clockwise=False)]),
        "space": contour_glyph([]),
        "A": contour_glyph(a_shape, instructions=GLYPH_PROGRAM),
        "ring": contour_glyph(ring_shape),
        "uni4E00": contour_glyph([rect(60, 330, 940, 430)]),
        "uni4E00.alt": contour_glyph([rect(60, 300, 940, 460)]),
        "u20000": contour_glyph([rect(100, 100, 900, 200), rect(450, 200, 550, 800)]),
        "uni3001": contour_glyph([rect(100, 0, 250, 150)]),
        "uni3002": contour_glyph([rect(100, 0, 300, 200)]),
        "uniFF08": contour_glyph([rect(600, -100, 700, 800)]),
        "uniFF09": contour_glyph([rect(300, -100, 400, 800)]),
        "uni3001.vert": contour_glyph([rect(650, 650, 800, 800)]),
        "uni3002.vert": contour_glyph([rect(650, 600, 850, 800)]),
        "uniFF08.vert": contour_glyph([rect(50, 500, 950, 600)]),
        "uniFF09.vert": contour_glyph([rect(50, 200, 950, 300)]),
        "uni2014": contour_glyph([rect(0, 330, 1000, 380)]),
        "uni2014.vert": contour_glyph([rect(475, -120, 525, 880)]),
        # Offset only, with its own instructions.
        "Aring": contour_glyph([], [("A", (1, 0, 0, 1, 0, 0)), ("ring", (1, 0, 0, 1, 200, 720))],
                               instructions=GLYPH_PROGRAM),
        # Uniform scale.
        "A.small": contour_glyph([], [("A", (0.5, 0, 0, 0.5, 100, 0))]),
        # Separate x/y scale.
        "A.wide": contour_glyph([], [("A", (1.5, 0, 0, 0.75, 0, 0))]),
        # Full 2x2 (rotation by 30 degrees), offset larger than a byte.
        "A.slant": contour_glyph([], [("A", (0.866, 0.5, -0.5, 0.866, 300, -200))]),
        # Composite of a composite, transformed: depth 2.
        "Aring.nested": contour_glyph([], [("Aring", (0.8, 0.1, -0.1, 0.8, 50, 30)), ("ring", (1, 0, 0, 1, -10, 900))]),
        # Depth 3.
        "Aring.deep": contour_glyph([], [("Aring.nested", (0.5, 0, 0, 0.5, 250, 0))]),
        # Empty component next to a real one.
        "A.spaced": contour_glyph([], [("space", (1, 0, 0, 1, 0, 0)), ("A", (1, 0, 0, 1, 250, 0))]),
    }
    advances = {name: 1000 for name in order}
    advances.update({".notdef": 500, "space": 250, "A": 600, "ring": 0, "Aring": 600,
                     "A.small": 400, "A.wide": 900, "A.slant": 700, "A.spaced": 850})

    fb = FontBuilder(1000, isTTF=True)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap(cmap, uvs=[(0x4E00, 0xE0100, None), (0x4E00, 0xE0101, "uni4E00.alt")])
    fb.setupGlyf(glyphs)
    glyf = fb.font["glyf"]
    fb.setupHorizontalMetrics({n: (advances[n], getattr(glyf[n], "xMin", 0)) for n in order})
    fb.setupHorizontalHeader(ascent=880, descent=-120)
    fb.setupVerticalHeader(ascent=500, descent=-500)
    fb.setupVerticalMetrics({n: (1000, 880 - getattr(glyf[n], "yMax", 880)) for n in order})
    fb.setupOS2(sTypoAscender=880, sTypoDescender=-120, sTypoLineGap=0, usWinAscent=1100,
                usWinDescent=300, fsType=0, usWeightClass=400)
    fb.setupPost()
    fb.setupNameTable({}, mac=False)
    name = fb.font["name"]
    for name_id, text in [
        (0, 'Copyright 2026 FontsMaker Tests, with Reserved Font Name "FM Synth".'),
        (1, "FM Synth"), (2, "Regular"), (4, "FM Synth Regular"), (6, "FMSynth-Regular"),
        (13, OFL_DESCRIPTION), (14, "https://openfontlicense.org"),
    ]:
        name.setName(text, name_id, 3, 1, 0x409)
    name.setName("合成測試", 1, 3, 1, 0x404)
    name.setName("合成測試 Regular", 4, 3, 1, 0x404)
    name.setName("合成测试", 1, 3, 1, 0x804)
    name.setName("FM Synth", 1, 1, 0, 0)
    name.setName("FMSynth-Regular", 6, 1, 0, 0)

    fb.addOpenTypeFeatures(
        """
        languagesystem DFLT dflt;
        lookup VERT_MAIN {
            sub uni3001 by uni3001.vert;
            sub uni3002 by uni3002.vert;
            sub uniFF08 by uniFF08.vert;
            sub uniFF09 by uniFF09.vert;
        } VERT_MAIN;
        lookup VRT2_EXT useExtension {
            sub uni2014 by uni2014.vert;
        } VRT2_EXT;
        feature vert { lookup VERT_MAIN; } vert;
        feature vrt2 { lookup VERT_MAIN; lookup VRT2_EXT; } vrt2;
        """
    )

    fb.font["fpgm"] = fpgm = newTable("fpgm")
    fpgm.program = program(FPGM_PROGRAM)
    fb.font["prep"] = prep = newTable("prep")
    prep.program = program(PREP_PROGRAM)
    fb.font["cvt "] = cvt = newTable("cvt ")
    cvt.values = array.array("h", [0, 100, -120])
    fb.font["gasp"] = gasp = newTable("gasp")
    gasp.version = 1
    gasp.gaspRange = {0xFFFF: 0x000F}
    fb.font["LTSH"] = ltsh = newTable("LTSH")
    ltsh.version = 0
    ltsh.yPels = {n: 1 for n in order}
    fb.font["hdmx"] = hdmx = newTable("hdmx")
    hdmx.version = 0
    hdmx.hdmx = {12: {n: otRound(advances[n] * 12 / 1000) for n in order}}
    fb.setupDummyDSIG()

    maxp = fb.font["maxp"]
    maxp.maxZones = 2
    maxp.maxTwilightPoints = 4
    maxp.maxStorage = 1
    maxp.maxFunctionDefs = 1
    maxp.maxInstructionDefs = 0
    maxp.maxStackElements = 2
    maxp.maxSizeOfInstructions = len(GLYPH_PROGRAM)

    set_fixed_head(fb)
    fb.save(path)


def gsub_single_encodings(data):
    """Binary formats used by single-substitution lookups. fontTools drops the
    format numbers after decompiling, so read them from the raw table."""
    u16 = lambda at: struct.unpack_from(">H", data, at)[0]
    found = set()
    lookup_list = u16(8)
    for i in range(u16(lookup_list)):
        lookup = lookup_list + u16(lookup_list + 2 + 2 * i)
        kind = u16(lookup)
        for j in range(u16(lookup + 4)):
            sub = lookup + u16(lookup + 6 + 2 * j)
            sub_kind = kind
            if kind == 7:
                found.add(("extension", 7))
                sub_kind = u16(sub + 2)
                sub += struct.unpack_from(">I", data, sub + 4)[0]
            if sub_kind == 1:
                found.add(("single", u16(sub)))
                found.add(("coverage", u16(sub + u16(sub + 2))))
    return found


def write_expected(font_path, json_path):
    font = TTFont(font_path, lazy=False)
    order = font.getGlyphOrder()
    gid = {n: i for i, n in enumerate(order)}
    glyf = font["glyf"]

    composites = [gid[n] for n in order if glyf[n].isComposite()]
    decomposed = {}
    for n in order:
        if not glyf[n].isComposite():
            continue
        coords, end_pts, flags = glyf[n].getCoordinates(glyf, round=otRound)
        decomposed[str(gid[n])] = {
            "endPoints": list(end_pts),
            "x": [otRound(x) for x, _ in coords],
            "y": [otRound(y) for _, y in coords],
            "onCurve": [bool(f & 1) for f in flags],
        }

    gsub = font["GSUB"].table
    lookups = sorted({i for fr in gsub.FeatureList.FeatureRecord if fr.FeatureTag in ("vert", "vrt2")
                      for i in fr.Feature.LookupListIndex})
    vert = {}
    for index in lookups:
        lookup = gsub.LookupList.Lookup[index]
        for sub in lookup.SubTable:
            if lookup.LookupType == 7:
                sub = sub.ExtSubTable
            if sub.LookupType != 1:
                continue
            for src, dst in sub.mapping.items():
                vert.setdefault(str(gid[src]), gid[dst])
    # The fixture exists to exercise these encodings; fail if fontTools chose others.
    encodings = gsub_single_encodings(font.reader["GSUB"])
    assert encodings == {("single", 1), ("single", 2), ("coverage", 1), ("coverage", 2), ("extension", 7)}, encodings

    transforms = set()
    for n in order:
        if glyf[n].isComposite():
            for c in glyf[n].components:
                t = getattr(c, "transform", None)
                if t is None:
                    transforms.add("offset")
                elif t[0][1] or t[1][0]:
                    transforms.add("2x2")
                elif t[0][0] != t[1][1]:
                    transforms.add("xy")
                else:
                    transforms.add("scale")
    assert transforms == {"offset", "scale", "xy", "2x2"}, transforms
    assert font["maxp"].maxComponentDepth == 3, font["maxp"].maxComponentDepth

    cmap = font.getBestCmap()
    expected = {
        "numGlyphs": len(order),
        "glyphOrder": order,
        "cmap": {str(cp): gid[n] for cp, n in sorted(cmap.items())},
        "composites": composites,
        "decomposed": decomposed,
        "vert": vert,
        "names": [
            {"platformID": n.platformID, "encodingID": n.platEncID, "languageID": n.langID,
             "nameID": n.nameID, "hex": n.toBytes().hex()}
            for n in sorted(font["name"].names, key=lambda n: (n.platformID, n.platEncID, n.langID, n.nameID))
        ],
        "instructions": {str(gid[n]): glyf[n].program.getBytecode().hex()
                         for n in order if hasattr(glyf[n], "program") and glyf[n].program.getBytecode()},
        "advances": [font["hmtx"][n][0] for n in order],
        "leftSideBearings": [font["hmtx"][n][1] for n in order],
        "tables": sorted(tag for tag in font.keys() if tag != "GlyphOrder"),
        "maxp": {k: getattr(font["maxp"], k) for k in (
            "maxPoints", "maxContours", "maxCompositePoints", "maxCompositeContours",
            "maxComponentElements", "maxComponentDepth")},
    }
    json_path.write_text(json.dumps(expected, indent=1, sort_keys=True, ensure_ascii=False) + "\n")


def build_ops(path):
    """Fixture for the Phase 2 operations (rename, s2t, pseudoVertical).

    Every character is chosen for a case the operations must handle:
    - s2t: 汉→漢 (one candidate), 发→發|髮 and 后→後|后 (one-to-many),
      为→爲 then Taiwan variant 爲→為, 里→裏 then 裏→裡, 们→們 with 們 absent.
    - pseudoVertical, by Unicode Vertical_Orientation: U (一 shared with
      ⼀, ×, 漢, the composite 回 built from 口), Tu punctuation (、。！),
      Tu non-punctuation (ぁ), Tr with and without vert alternates (「」ー),
      R (A), and one glyph shared by an R and a U code point (· and ・).
    - The vert alternate of 、 is also mapped directly from U+FE11, and that
      of 「 from U+FE41, so a rotated alternate must be shared, not doubled.
    - 漢 has vertical advance 1120 (the rotated advance must ignore vmtx and
      use the em-box height) and
      × has an odd horizontal advance (rounding of the rotation centre).
    - Names in several platforms and languages, ID 16/17, and an in-file
      Reserved Font Name that is not part of the family name.
    """
    order = [
        ".notdef", "space", "A", "periodcentered", "multiply",
        "uni4E00", "uni53E3", "uni56DE",
        "uni6C49", "uni6F22", "uni4E3A", "uni7232", "uni70BA", "uni53D1", "uni767C", "uni9AEE",
        "uni540E", "uni5F8C", "uni4EEC", "uni91CC", "uni88CF", "uni88E1",
        "uni3001", "uni3001.vert", "uni3002", "uniFF01", "uni300C", "uniFE41", "uni300D", "uni300D.vert",
        "uni30FC", "uni3041", "uni3041.vert",
    ]
    cmap = {
        0x20: "space", 0x41: "A", 0xB7: "periodcentered", 0x30FB: "periodcentered", 0xD7: "multiply",
        0x4E00: "uni4E00", 0x2F00: "uni4E00", 0x53E3: "uni53E3", 0x56DE: "uni56DE",
        0x6C49: "uni6C49", 0x6F22: "uni6F22", 0x4E3A: "uni4E3A", 0x7232: "uni7232", 0x70BA: "uni70BA",
        0x53D1: "uni53D1", 0x767C: "uni767C", 0x9AEE: "uni9AEE", 0x540E: "uni540E", 0x5F8C: "uni5F8C",
        0x4EEC: "uni4EEC", 0x91CC: "uni91CC", 0x88CF: "uni88CF", 0x88E1: "uni88E1",
        0x3001: "uni3001", 0xFE11: "uni3001.vert", 0x3002: "uni3002", 0xFF01: "uniFF01",
        0x300C: "uni300C", 0xFE41: "uniFE41", 0x300D: "uni300D", 0x30FC: "uni30FC", 0x3041: "uni3041",
    }

    def bars(index):
        # Distinct, asymmetric ideograph stand-ins: a frame plus `index` bars.
        contours = [rect(100, -50, 900, 0), rect(100, 0, 160, 780)]
        for i in range(index):
            contours.append(rect(220 + 60 * i, 100 + 40 * i, 260 + 60 * i, 700))
        return contour_glyph(contours)

    glyphs = {
        ".notdef": contour_glyph([rect(50, 0, 450, 700), rect(100, 50, 400, 650, clockwise=False)]),
        "space": contour_glyph([]),
        "A": contour_glyph([[(20, 0, True), (300, 700, True), (580, 0, True)], [(200, 100, True), (300, 400, True),
                                                                             (400, 100, True)]]),
        "periodcentered": contour_glyph([rect(100, 330, 200, 430)]),
        "multiply": contour_glyph([rect(80, 100, 120, 600), rect(80, 330, 475, 370)]),
        "uni4E00": contour_glyph([rect(60, 330, 940, 430)]),
        "uni53E3": contour_glyph([rect(150, 50, 850, 750), rect(250, 150, 750, 650, clockwise=False)]),
        "uni56DE": contour_glyph([], [("uni53E3", (1, 0, 0, 1, 0, 0)), ("uni53E3", (0.5, 0, 0, 0.5, 250, 200))]),
        "uni3001": contour_glyph([rect(100, -60, 260, 100)]),
        "uni3001.vert": contour_glyph([rect(640, 640, 800, 800)]),
        "uni3002": contour_glyph([rect(80, -70, 300, 150), rect(130, -20, 250, 100, clockwise=False)]),
        "uniFF01": contour_glyph([rect(440, 200, 560, 760), rect(440, -40, 560, 80)]),
        "uni300C": contour_glyph([rect(560, 300, 620, 820), rect(560, 760, 900, 820)]),
        "uniFE41": contour_glyph([rect(180, 300, 760, 360), rect(700, 300, 760, 720)]),
        "uni300D": contour_glyph([rect(380, -80, 440, 440), rect(100, -80, 440, -20)]),
        "uni300D.vert": contour_glyph([rect(240, 40, 820, 100), rect(240, 40, 300, 460)]),
        "uni30FC": contour_glyph([rect(80, 340, 920, 420)]),
        "uni3041": contour_glyph([rect(250, 0, 600, 450)]),
        "uni3041.vert": contour_glyph([rect(400, 250, 750, 700)]),
    }
    hanzi = ["uni6C49", "uni6F22", "uni4E3A", "uni7232", "uni70BA", "uni53D1", "uni767C", "uni9AEE",
             "uni540E", "uni5F8C", "uni4EEC", "uni91CC", "uni88CF", "uni88E1"]
    for index, name in enumerate(hanzi):
        glyphs[name] = bars(index + 1)

    advances = {name: 1000 for name in order}
    advances.update({".notdef": 500, "space": 250, "A": 600, "periodcentered": 300, "multiply": 555})
    vertical_advances = {name: 1000 for name in order}
    vertical_advances["uni6F22"] = 1120

    fb = FontBuilder(1000, isTTF=True)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap(cmap)
    fb.setupGlyf(glyphs)
    glyf = fb.font["glyf"]
    fb.setupHorizontalMetrics({n: (advances[n], getattr(glyf[n], "xMin", 0)) for n in order})
    fb.setupHorizontalHeader(ascent=880, descent=-120)
    fb.setupVerticalHeader(ascent=500, descent=-500)
    fb.setupVerticalMetrics({n: (vertical_advances[n], 880 - getattr(glyf[n], "yMax", 880)) for n in order})
    fb.setupOS2(sTypoAscender=880, sTypoDescender=-120, sTypoLineGap=0, usWinAscent=1100,
                usWinDescent=300, fsType=0, usWeightClass=400, fsSelection=0x40)
    fb.setupPost()
    fb.setupNameTable({}, mac=False)
    name = fb.font["name"]
    copyright_text = 'Copyright 2026 FontsMaker Tests, with Reserved Font Name "Moonlit".'
    for name_id, text in [
        (0, copyright_text), (1, "FM Ops"), (2, "Regular"), (3, "FMOps-Regular;1.500"), (4, "FM Ops Regular"),
        (5, "Version 1.500"), (6, "FMOps-Regular"), (13, OFL_DESCRIPTION), (14, "https://openfontlicense.org"),
        (16, "FM Ops"), (17, "Regular"),
    ]:
        name.setName(text, name_id, 3, 1, 0x409)
    name.setName("運算測試", 1, 3, 1, 0x404)
    name.setName("運算測試 Regular", 4, 3, 1, 0x404)
    name.setName("运算测试", 1, 3, 1, 0x804)
    name.setName("運算測試", 4, 3, 1, 0xC04)
    for name_id, text in [(0, copyright_text), (1, "FM Ops"), (5, "Version 1.500"), (6, "FMOps-Regular")]:
        name.setName(text, name_id, 1, 0, 0)

    fb.addOpenTypeFeatures(
        """
        languagesystem DFLT dflt;
        lookup VERT_FORMS {
            sub uni3001 by uni3001.vert;
            sub uni300C by uniFE41;
            sub uni300D by uni300D.vert;
            sub uni3041 by uni3041.vert;
        } VERT_FORMS;
        feature vert { lookup VERT_FORMS; } vert;
        """
    )
    fb.updateHead(fontRevision=1.5)
    set_fixed_head(fb)
    fb.save(path)


def write_ops_expected(font_path, json_path):
    """Glyph order and cmap as fontTools reads them, so tests address glyphs by name."""
    font = TTFont(font_path, lazy=False)
    order = font.getGlyphOrder()
    gid = {n: i for i, n in enumerate(order)}
    expected = {
        "glyphOrder": order,
        "cmap": {str(cp): gid[n] for cp, n in sorted(font.getBestCmap().items())},
    }
    json_path.write_text(json.dumps(expected, indent=1, sort_keys=True, ensure_ascii=False) + "\n")


def build_restricted(path):
    """OFL wording plus the Restricted License fsType bit: the bit must win."""
    fb = minimal_ttf()
    fb.font["OS/2"].fsType = 0x0002
    name = fb.font["name"]
    name.setName(OFL_DESCRIPTION, 13, 3, 1, 0x409)
    name.setName("https://openfontlicense.org", 14, 3, 1, 0x409)
    fb.save(path)


def minimal_ttf():
    fb = FontBuilder(1000, isTTF=True)
    fb.setupGlyphOrder([".notdef", "A"])
    fb.setupCharacterMap({0x41: "A"})
    fb.setupGlyf({".notdef": contour_glyph([rect(50, 0, 450, 700)]),
                  "A": contour_glyph([[(20, 0, True), (300, 700, True), (580, 0, True)]])})
    fb.setupHorizontalMetrics({".notdef": (500, 50), "A": (600, 20)})
    fb.setupHorizontalHeader(ascent=880, descent=-120)
    fb.setupOS2()
    fb.setupPost()
    fb.setupNameTable({"familyName": "FM Reject", "styleName": "Regular"})
    set_fixed_head(fb)
    return fb


def build_cff(path):
    """A static CFF font, the shape of ButTaiwan's .otf releases: cubic
    curves (O, with a counter; S, long enough for cu2qu to need several
    quadratics), a glyph shared by two code points, a vert alternate,
    vertical metrics and a VORG table, which conversion must drop."""
    order = [".notdef", "space", "A", "O", "S", "uni4E00", "uni3001", "uni3001.vert"]
    cmap = {0x20: "space", 0x41: "A", 0x4F: "O", 0x53: "S", 0x4E00: "uni4E00", 0x2F00: "uni4E00",
            0x3001: "uni3001"}
    advances = {".notdef": 500, "space": 250, "A": 600, "O": 700, "S": 560, "uni4E00": 1000,
                "uni3001": 1000, "uni3001.vert": 1000}

    def draw(pen, name):
        # PostScript direction: ink counter-clockwise (y up), counters clockwise.
        def poly(points):
            pen.moveTo(points[0])
            for p in points[1:]:
                pen.lineTo(p)
            pen.closePath()

        def ellipse(cx, cy, rx, ry, clockwise):
            # Four quarter arcs; k is the usual cubic circle constant.
            k = 0.5523
            right, top, left, bottom = (cx + rx, cy), (cx, cy + ry), (cx - rx, cy), (cx, cy - ry)
            if not clockwise:
                arcs = [(right, (cx + rx, cy + k * ry), (cx + k * rx, cy + ry), top),
                        (top, (cx - k * rx, cy + ry), (cx - rx, cy + k * ry), left),
                        (left, (cx - rx, cy - k * ry), (cx - k * rx, cy - ry), bottom),
                        (bottom, (cx + k * rx, cy - ry), (cx + rx, cy - k * ry), right)]
            else:
                arcs = [(right, (cx + rx, cy - k * ry), (cx + k * rx, cy - ry), bottom),
                        (bottom, (cx - k * rx, cy - ry), (cx - rx, cy - k * ry), left),
                        (left, (cx - rx, cy + k * ry), (cx - k * rx, cy + ry), top),
                        (top, (cx + k * rx, cy + ry), (cx + rx, cy + k * ry), right)]
            pen.moveTo(arcs[0][0])
            for _, c1, c2, end in arcs:
                pen.curveTo(c1, c2, end)
            pen.closePath()

        if name == ".notdef":
            poly([(50, 0), (450, 0), (450, 700), (50, 700)])
            poly([(100, 50), (100, 650), (400, 650), (400, 50)])
        elif name == "A":
            poly([(20, 0), (150, 0), (300, 520), (450, 0), (580, 0), (360, 700), (240, 700)])
        elif name == "O":
            ellipse(350, 350, 320, 360, clockwise=False)
            ellipse(350, 350, 200, 250, clockwise=True)
        elif name == "S":
            pen.moveTo((60, 120))
            pen.curveTo((100, 20), (220, -10), (300, -10))
            pen.curveTo((460, -10), (520, 80), (520, 190))
            pen.curveTo((520, 420), (170, 360), (170, 520))
            pen.curveTo((170, 580), (230, 620), (300, 620))
            pen.curveTo((370, 620), (420, 590), (450, 540))
            pen.lineTo((500, 600))
            pen.curveTo((460, 670), (390, 710), (300, 710))
            pen.curveTo((160, 710), (70, 630), (70, 520))
            pen.curveTo((70, 280), (420, 340), (420, 190))
            pen.curveTo((420, 120), (370, 80), (300, 80))
            pen.curveTo((230, 80), (160, 110), (130, 180))
            pen.closePath()
        elif name == "uni4E00":
            poly([(60, 330), (940, 330), (940, 430), (60, 430)])
        elif name == "uni3001":
            poly([(100, 0), (250, 0), (250, 150), (100, 150)])
        elif name == "uni3001.vert":
            poly([(650, 650), (800, 650), (800, 800), (650, 800)])

    charstrings = {}
    for name in order:
        pen = T2CharStringPen(advances[name], None)
        draw(pen, name)
        charstrings[name] = pen.getCharString()

    fb = FontBuilder(1000, isTTF=False)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap(cmap)
    fb.setupCFF("FMCFF-Regular", {"FullName": "FM CFF Regular"}, charstrings, {})
    bounds = {name: charstrings[name].calcBounds(None) for name in order}
    fb.setupHorizontalMetrics({n: (advances[n], otRound(bounds[n][0]) if bounds[n] else 0) for n in order})
    fb.setupHorizontalHeader(ascent=880, descent=-120)
    fb.setupVerticalHeader(ascent=500, descent=-500)
    fb.setupVerticalMetrics({n: (1000, 880 - otRound(bounds[n][3]) if bounds[n] else 0) for n in order})
    fb.setupOS2(sTypoAscender=880, sTypoDescender=-120, usWinAscent=1100, usWinDescent=300, fsType=0)
    fb.setupPost()
    fb.setupNameTable({}, mac=False)
    name = fb.font["name"]
    for name_id, text in [(1, "FM CFF"), (2, "Regular"), (4, "FM CFF Regular"), (6, "FMCFF-Regular"),
                          (13, OFL_DESCRIPTION), (14, "https://openfontlicense.org")]:
        name.setName(text, name_id, 3, 1, 0x409)
    fb.addOpenTypeFeatures(
        """
        languagesystem DFLT dflt;
        feature vert { sub uni3001 by uni3001.vert; } vert;
        """
    )
    fb.font["VORG"] = vorg = newTable("VORG")
    vorg.majorVersion, vorg.minorVersion = 1, 0
    vorg.defaultVertOriginY = 880
    vorg.VOriginRecords = {}
    set_fixed_head(fb)
    fb.save(path)


def glyph_contours(glyph, glyf):
    """[[[x, y, onCurve], ...] per contour], composites flattened."""
    if glyph.numberOfContours == 0:
        return []
    coords, ends, flags = glyph.getCoordinates(glyf)
    contours, start = [], 0
    for end in ends:
        contours.append([[otRound(coords[i][0]), otRound(coords[i][1]), bool(flags[i] & 1)]
                         for i in range(start, end + 1)])
        start = end + 1
    return contours


def otf_to_ttf_contours(path):
    """The oracle for CFF conversion: fontTools' own CFF → TrueType route
    (Snippets/otf2ttf.py: cu2qu at 1 unit, reversed to TrueType direction)."""
    font = TTFont(path)
    glyph_set = font.getGlyphSet()
    result = []
    for name in font.getGlyphOrder():
        pen = TTGlyphPen(glyph_set)
        glyph_set[name].draw(Cu2QuPen(pen, 1.0, reverse_direction=True))
        result.append(glyph_contours(pen.glyph(), None))
    return result


def write_cff_expected(font_path, json_path):
    from fontTools.pens.boundsPen import BoundsPen

    font = TTFont(font_path)
    order = font.getGlyphOrder()
    gid = {n: i for i, n in enumerate(order)}
    glyph_set = font.getGlyphSet()

    def vertical_origin(name):
        # The origin the CFF font is set by vertically, VORG, which the
        # converted glyph's tsb + yMax must keep; None for an empty glyph.
        pen = BoundsPen(glyph_set)
        glyph_set[name].draw(pen)
        vorg = font["VORG"]
        return vorg.VOriginRecords.get(name, vorg.defaultVertOriginY) if pen.bounds else None

    expected = {
        "glyphs": otf_to_ttf_contours(font_path),
        "advances": [font["hmtx"][n][0] for n in order],
        "verticalAdvances": [font["vmtx"][n][0] for n in order],
        "verticalOrigins": [vertical_origin(n) for n in order],
        "cmap": {str(cp): gid[n] for cp, n in sorted(font.getBestCmap().items())},
        "vert": {str(gid["uni3001"]): gid["uni3001.vert"]},
        "tables": sorted(tag for tag in font.keys() if tag != "GlyphOrder"),
    }
    json_path.write_text(json.dumps(expected, sort_keys=True) + "\n")


VARIABLE_AXES = [("wght", 100, 400, 900, "Weight"), ("opsz", 8, 12, 72, "Optical size")]
# Locations the tests convert at. Every master delta is a multiple of 10, so
# at these normalized positions (0, 0.3, 0.5, 0.6, 1) no coordinate lands on
# a rounding tie and the instancer's output is the exact instance.
VARIABLE_LOCATIONS = [
    {"wght": 400, "opsz": 12}, {"wght": 700, "opsz": 12}, {"wght": 400, "opsz": 72},
    {"wght": 650, "opsz": 30}, {"wght": 250, "opsz": 12},
]


def build_variable(path):
    """A glyf variable font with wght and opsz, built by varLib from three
    masters, so it has gvar and HVAR like google/fonts releases. opsz is the
    axis CoreText sets on its own from the point size; at the 1000 pt the
    engine reads outlines at, that would be the opsz 72 master."""
    from fontTools.designspaceLib import AxisDescriptor, DesignSpaceDocument, SourceDescriptor
    from fontTools.varLib import build as build_varfont

    def master(stem, bowl, advance_l, advance_o):
        # stem: width of "l"; bowl: thickness of "o". The "o" rings are
        # off-curve points only, so every on-curve point of them is implied.
        order = [".notdef", "space", "l", "o"]
        glyphs = {
            ".notdef": contour_glyph([rect(50, 0, 450, 700), rect(100, 50, 400, 650, clockwise=False)]),
            "space": contour_glyph([]),
            "l": contour_glyph([rect(100, 0, 100 + stem, 720)]),
            "o": contour_glyph([
                [(20, 260, False), (20, 520, False), (300, 520, False), (580, 520, False), (580, 260, False),
                 (580, 0, False), (300, 0, False), (20, 0, False)],
                [(20 + bowl, 260, False), (20 + bowl, bowl, False), (300, bowl, False),
                 (580 - bowl, bowl, False), (580 - bowl, 260, False), (580 - bowl, 520 - bowl, False),
                 (300, 520 - bowl, False), (20 + bowl, 520 - bowl, False)],
            ]),
        }
        advances = {".notdef": 500, "space": 250, "l": advance_l, "o": advance_o}
        fb = FontBuilder(1000, isTTF=True)
        fb.setupGlyphOrder(order)
        fb.setupCharacterMap({0x20: "space", 0x6C: "l", 0x6F: "o"})
        fb.setupGlyf(glyphs)
        glyf = fb.font["glyf"]
        fb.setupHorizontalMetrics({n: (advances[n], getattr(glyf[n], "xMin", 0)) for n in order})
        fb.setupHorizontalHeader(ascent=880, descent=-120)
        fb.setupOS2(sTypoAscender=880, sTypoDescender=-120, usWinAscent=1100, usWinDescent=300, fsType=0,
                    usWeightClass=400)
        fb.setupPost()
        fb.setupNameTable({}, mac=False)
        name = fb.font["name"]
        for name_id, text in [(1, "FM Variable"), (2, "Regular"), (4, "FM Variable Regular"),
                              (6, "FMVariable-Regular"), (13, OFL_DESCRIPTION),
                              (14, "https://openfontlicense.org")]:
            name.setName(text, name_id, 3, 1, 0x409)
        set_fixed_head(fb)
        return fb.font

    doc = DesignSpaceDocument()
    for tag, minimum, default, maximum, label in VARIABLE_AXES:
        axis = AxisDescriptor()
        axis.tag, axis.name, axis.minimum, axis.default, axis.maximum = tag, label, minimum, default, maximum
        doc.addAxis(axis)
    for location, font, style in [
        ({"Weight": 400, "Optical size": 12}, master(80, 80, 300, 600), "Regular"),
        ({"Weight": 900, "Optical size": 12}, master(240, 200, 400, 700), "Black"),
        # A different shape at large optical size, so opsz 72 cannot pass for 12.
        ({"Weight": 400, "Optical size": 72}, master(60, 40, 280, 640), "Display"),
    ]:
        source = SourceDescriptor()
        source.font, source.location, source.styleName = font, location, style
        doc.addSource(source)
    varfont, _, _ = build_varfont(doc)
    varfont.recalcTimestamp = False
    varfont.save(path)


def write_variable_expected(font_path, json_path):
    """fontTools varLib.instancer at each test location: the oracle."""
    from fontTools.varLib import instancer

    instances = []
    for location in VARIABLE_LOCATIONS:
        static = instancer.instantiateVariableFont(TTFont(font_path), dict(location), static=True)
        order = static.getGlyphOrder()
        instances.append({
            "location": location,
            "glyphs": [glyph_contours(static["glyf"][n], static["glyf"]) for n in order],
            "advances": [static["hmtx"][n][0] for n in order],
            "weightClass": static["OS/2"].usWeightClass,
            "xAvgCharWidth": static["OS/2"].xAvgCharWidth,
        })
    font = TTFont(font_path)
    expected = {
        "axes": [{"tag": a.axisTag, "minimum": a.minValue, "default": a.defaultValue, "maximum": a.maxValue}
                 for a in font["fvar"].axes],
        "tables": sorted(tag for tag in font.keys() if tag != "GlyphOrder"),
        "instances": instances,
    }
    json_path.write_text(json.dumps(expected, sort_keys=True) + "\n")


def build_collection(path, members):
    collection = TTCollection()
    collection.fonts = [TTFont(member) for member in members]
    for font in collection.fonts:
        font.recalcTimestamp = False
    collection.save(path)


def write_cmap4_expected(json_path):
    """A mapping with every kind of run fontTools' splitRange handles, and
    the format 4 subtable fontTools compiles for it, byte for byte."""
    from fontTools.ttLib.tables._c_m_a_p import cmap_format_4

    mapping = {}
    gid = 1
    for code in range(0x20, 0x7F):  # one long in-order run
        mapping[code] = gid
        gid += 1
    for code in range(0x100, 0x140):  # out of order throughout
        mapping[code] = gid + (7 * code) % 13
    gid += 20
    # In-order stretches of every length around the thresholds (4 at a run's
    # end, 8 in its middle), each broken by one out-of-order code point.
    for start, length in [(0x3000, 3), (0x3010, 4), (0x3020, 5), (0x3030, 8), (0x3040, 9), (0x3060, 30)]:
        for offset in range(length):
            mapping[start + offset] = gid
            gid += 1
        mapping[start + length] = gid + 50
        for offset in range(length):
            mapping[start + length + 1 + offset] = gid
            gid += 1
    mapping[0x4E00] = 5
    mapping[0xFFFD] = 6
    order = [".notdef"] + [f"g{i}" for i in range(1, max(mapping.values()) + 1)]
    font = TTFont()
    font.setGlyphOrder(order)
    subtable = cmap_format_4(4)
    subtable.platformID, subtable.platEncID, subtable.language = 3, 1, 0
    subtable.cmap = {code: order[g] for code, g in mapping.items()}
    json_path.write_text(json.dumps({
        "mapping": {str(code): g for code, g in sorted(mapping.items())},
        "format4": subtable.compile(font).hex(),
    }, sort_keys=True) + "\n")


def build_woff(path, member):
    font = TTFont(member)
    font.recalcTimestamp = False
    font.flavor = "woff"
    font.save(path)


def build_woff2(path):
    # fontTools needs the brotli module to write real WOFF2 and it is not
    # installed here. The engine rejects WOFF2 by its signature alone, so a
    # well-formed 48-byte WOFF2 header with zero tables is enough.
    header = struct.pack(">4sIIHHIIHHIIIII", b"wOF2", 0x00010000, 48, 0, 0, 12, 0, 1, 0, 0, 0, 0, 0, 0)
    assert len(header) == 48
    path.write_bytes(header)


def main():
    # Optional output directory, so a check can regenerate elsewhere and
    # compare with the committed files.
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else FIXTURES
    out.mkdir(parents=True, exist_ok=True)
    synthetic = out / "synthetic.ttf"
    build_synthetic(synthetic)
    write_expected(synthetic, out / "synthetic-expected.json")

    ops = out / "ops.ttf"
    build_ops(ops)
    write_ops_expected(ops, out / "ops-expected.json")
    build_restricted(out / "restricted.ttf")

    minimal = out / "minimal.ttf"
    minimal_ttf().save(minimal)
    cff = out / "cff.otf"
    build_cff(cff)
    write_cff_expected(cff, out / "cff-expected.json")
    variable = out / "variable.ttf"
    build_variable(variable)
    write_variable_expected(variable, out / "variable-expected.json")
    # A glyf member, which needs no conversion, and a CFF one, which does.
    build_collection(out / "collection.ttc", [minimal, cff])
    write_cmap4_expected(out / "cmap4-expected.json")
    build_woff(out / "reject-woff.woff", minimal)
    build_woff2(out / "reject-woff2.woff2")
    for path in sorted(out.iterdir()):
        print(f"{path.stat().st_size:7d}  {path.name}")


if __name__ == "__main__":
    sys.exit(main())
