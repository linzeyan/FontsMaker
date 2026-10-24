"""Checks behind scripts/verify-s2t-phrases.sh. Run with `python3 -I`: the
corpora and dictionaries it reads are downloads.

  dicts BUNDLED DUMP PINNED SHARE
      The Homebrew opencc 1.4.2 data (dumped ocd2, stock configs) equals the
      bundled and pinned files, so stock `opencc` is an oracle for exactly
      the data the engine uses.
  corpora CACHE TESTCASES WORK
      work/corpora/*.txt, one line per sentence: OpenCC's s2t/s2tw test case
      inputs (with .expected/.ids), 呐喊 (simplified), SIGHAN 2005 PKU and MSR
      test sets. The natural corpora are the spike's (same pins, same splits).
  shape WORK CT_SHAPE FONT...
      work/shaped/<font>/<corpus>.<hb|ct>.jsonl: [[glyph, code point index], ...]
      per line, from hb-shape and CoreText with default features.
  accuracy WORK SOURCE
      Per code point, as in the spike: the shaped glyph must be the source
      font's glyph of the character OpenCC outputs. Spaces, input characters
      the font lacks and output characters it cannot show are excluded
      (counted). Pass: official s2tw cases all agree, s2t cases all but
      the 𣗊 case, every natural corpus 0 errors, both shapers.
  upright WORK SOURCE FONT
      Pseudo-vertical font: every Han character in the shaped corpora must
      be the turned outline of the source glyph OpenCC's character has.
  parse SOURCE FONT...
      fontTools decompiles every table; with phrases, the source lookups are
      unchanged behind extension lookups and rlig reaches the context lookup
      in every language system; without, GSUB is byte for byte the source's.
"""

import collections
import concurrent.futures
import json
import os
import re
import subprocess
import sys

SENTENCE_END = re.compile(r"(?<=[。！？!?；;])")
ALLOWED_S2T_FAILURES = {"BYVoid_OpenCC_PR_464_xi_vs_xi"}  # 𣗊 is not in GuanKiapTsingKhai
NATURAL = ("nahan", "pku", "msr")


def has_han(text):
    return any("㐀" <= c <= "鿿" or "\U00020000" <= c <= "\U0003ffff" for c in text)


def read_lines(path):
    with open(path, encoding="utf-8") as stream:
        return [line.rstrip("\n") for line in stream]


def write_lines(path, lines):
    with open(path, "w", encoding="utf-8", newline="\n") as stream:
        for line in lines:
            stream.write(line + "\n")


def load_dict(path):
    entries = {}
    with open(path, encoding="utf-8") as stream:
        for line in stream:
            if line.startswith("#") or not line.strip():
                continue
            key, value = line.rstrip("\n").split("\t", 1)
            entries[key] = value
    return entries


def best_cmap(font):
    """Code point → glyph ID (fontTools' cmap gives glyph names)."""
    return {code_point: font.getGlyphID(name) for code_point, name in font.getBestCmap().items()}


# ---------------------------------------------------------------- dicts


def cmd_dicts(bundled, dump, pinned, share):
    ok = True
    for name in ("STPhrases", "STPhrases_GeneratedFromRegionalPhrases", "STCharacters", "TWVariants", "TWVariantsPhrases"):
        a, b = load_dict(os.path.join(bundled, name + ".txt")), load_dict(os.path.join(dump, name + ".txt"))
        print(f"{'PASS' if a == b else 'FAIL'} {name}: bundled {len(a)} entries, Homebrew ocd2 {len(b)}")
        ok &= a == b
    a = load_dict(os.path.join(pinned, "CJK_Compatibility_Ideographs.txt"))
    b = load_dict(os.path.join(dump, "CJK_Compatibility_Ideographs.txt"))
    print(f"{'PASS' if a == b else 'FAIL'} CJK_Compatibility_Ideographs: pinned {len(a)}, Homebrew ocd2 {len(b)}")
    ok &= a == b
    for config in ("s2t.json", "s2tw.json"):
        with open(os.path.join(pinned, config), encoding="utf-8") as x, open(os.path.join(share, config), encoding="utf-8") as y:
            same = json.load(x) == json.load(y)
        print(f"{'PASS' if same else 'FAIL'} {config}: pinned config {'=' if same else '!='} Homebrew config")
        ok &= same
    return 0 if ok else 1


# ---------------------------------------------------------------- corpora


def sentences(paragraphs):
    out = []
    for paragraph in paragraphs:
        paragraph = paragraph.strip()  # str.strip also drops U+3000 indents
        for piece in SENTENCE_END.split(paragraph):
            piece = piece.strip()
            if piece and has_han(piece):
                out.append(piece)
    return out


def cmd_corpora(cache, testcases, work):
    cdir = os.path.join(work, "corpora")
    os.makedirs(cdir, exist_ok=True)
    with open(testcases, encoding="utf-8") as stream:
        cases = json.loads(re.sub(r",(\s*[}\]])", r"\1", stream.read()))["cases"]  # JSON5 trailing commas
    sizes = {}
    for config in ("s2t", "s2tw"):
        selected = [c for c in cases if config in c.get("expected", {})]
        write_lines(os.path.join(cdir, f"testcases-{config}.txt"), [c["input"] for c in selected])
        write_lines(os.path.join(cdir, f"testcases-{config}.expected"), [c["expected"][config] for c in selected])
        write_lines(os.path.join(cdir, f"testcases-{config}.ids"), [c["id"] for c in selected])
        sizes[f"testcases-{config}"] = len(selected)
    with open(os.path.join(cache, "nahan-simplified", "nahan.txt"), encoding="utf-8") as stream:
        corpora = {"nahan": sentences(stream.read().split("\n"))}
    for name in ("pku", "msr"):
        path = os.path.join(cache, "sighan2005", "extracted", f"{name}_test.utf8")
        with open(path, encoding="utf-8-sig") as stream:
            corpora[name] = [line.strip() for line in stream if has_han(line)]
    for name, lines in corpora.items():
        write_lines(os.path.join(cdir, name + ".txt"), lines)
        sizes[name] = len(lines)
    print(json.dumps(sizes))
    # The spike's sentence counts: same pins and splitting give the same corpora.
    expected = {"testcases-s2t": 105, "testcases-s2tw": 65, "nahan": 3109, "pku": 1944, "msr": 3977}
    if sizes != expected:
        print(f"FAIL corpora differ from the spike's: {expected}")
        return 1
    return 0


# ---------------------------------------------------------------- shape


def corpus_names(work):
    return sorted(f[:-4] for f in os.listdir(os.path.join(work, "corpora")) if f.endswith(".txt"))


def cmd_shape(work, ct_shape, *fonts):
    jobs = []
    for font in fonts:
        path = os.path.join(work, "fonts", font + ".ttf")
        out = os.path.join(work, "shaped", font)
        os.makedirs(out, exist_ok=True)
        for corpus in corpus_names(work):
            text = os.path.join(work, "corpora", corpus + ".txt")
            jobs.append(("hb", path, text, os.path.join(out, f"{corpus}.hb.jsonl")))
            jobs.append(("ct", path, text, os.path.join(out, f"{corpus}.ct.jsonl")))

    def run(job):
        shaper, path, text, out = job
        if shaper == "ct":
            subprocess.run([ct_shape, path, text, out, "--lang", "zh-Hans"], check=True, capture_output=True)
            return
        # Simplified text tagged zh-Hans, as an EPUB would be; clusters are code point indices.
        result = subprocess.run(
            ["hb-shape", "--font-file", path, "--text-file", text, "--output-format=json", "--no-glyph-names",
             "--language=zh-Hans"],
            check=True, capture_output=True, text=True)
        with open(out, "w", encoding="utf-8") as stream:
            for line in result.stdout.splitlines():
                stream.write(json.dumps([[g["g"], g["cl"]] for g in json.loads(line)]) + "\n")

    failed = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        for job, future in [(job, pool.submit(run, job)) for job in jobs]:
            try:
                future.result()
            except subprocess.CalledProcessError as error:
                failed += 1
                print("FAIL", job[3], (error.stderr or b"")[-500:])
    print(f"{len(jobs) - failed}/{len(jobs)} shaping jobs ok")
    return 1 if failed else 0


def load_shaped(work, font, corpus, shaper):
    with open(os.path.join(work, "shaped", font, f"{corpus}.{shaper}.jsonl"), encoding="utf-8") as stream:
        return [json.loads(line) for line in stream]


def per_code_point(glyphs, count):
    """Glyph of each code point: by order when there is one glyph per code
    point (always, for these fonts), else by cluster (then flagged)."""
    if len(glyphs) == count:
        return [g for g, _ in glyphs]
    slots = [None] * count
    for g, cluster in glyphs:
        if 0 <= cluster < count and slots[cluster] is None:
            slots[cluster] = g
    return slots


def expected_lines(work, corpus, config):
    if corpus.startswith("testcases-"):
        return read_lines(os.path.join(work, "corpora", corpus + ".expected"))
    return read_lines(os.path.join(work, "oracle", f"{corpus}.{config}.txt"))


# ---------------------------------------------------------------- accuracy


def compare(work, font, corpus, shaper, config, src_cmap, font_cmap):
    inputs = read_lines(os.path.join(work, "corpora", corpus + ".txt"))
    wanted = expected_lines(work, corpus, config)
    rows = load_shaped(work, font, corpus, shaper)
    m = collections.Counter()
    errors = []
    failing_lines = []
    for i, (line, want) in enumerate(zip(inputs, wanted)):
        if len(line) != len(want):
            m["length_changed_lines"] += 1
            continue
        got = per_code_point(rows[i], len(line))
        m["glyph_count_not_char_count_lines"] += len(rows[i]) != len(line)
        line_ok = True
        for j, (c, o) in enumerate(zip(line, want)):
            if c.isspace():
                continue
            if ord(c) not in font_cmap:
                m["input_not_in_font"] += 1
                continue
            expected = src_cmap.get(ord(o))
            if expected is None:
                m["output_not_in_font"] += 1
                continue
            m["chars"] += 1
            if got[j] != expected:
                line_ok = False
                m["errors"] += 1
                errors.append(f"{i + 1}\t{j}\t{line[max(0, j - 6):j]}[{c}]{line[j + 1:j + 7]}\t{c}\t{o}\t{got[j]}")
        m["lines"] += 1
        m["lines_ok"] += line_ok
        if not line_ok:
            failing_lines.append(i)
    return m, errors, failing_lines


def cmd_accuracy(work, source):
    from fontTools.ttLib import TTFont

    src_cmap = best_cmap(TTFont(source))
    out = os.path.join(work, "accuracy")
    os.makedirs(out, exist_ok=True)
    results = {}
    cmaps = {}
    ok = True
    table = ["config  corpus          font        shaper  chars   errors  sentences ok      excluded(in/out)"]
    for config, baseline, font in (("s2t", "char-s", "phrases-s"), ("s2tw", "char-tw", "phrases-tw")):
        corpora = [f"testcases-{config}", *NATURAL]
        for corpus in corpora:
            for shaper in ("hb", "ct"):
                for name in (baseline, font):
                    if name not in cmaps:
                        cmaps[name] = best_cmap(TTFont(os.path.join(work, "fonts", name + ".ttf")))
                    font_cmap = cmaps[name]
                    m, errors, failing = compare(work, name, corpus, shaper, config, src_cmap, font_cmap)
                    key = f"{config}|{corpus}|{name}|{shaper}"
                    results[key] = dict(m)
                    with open(os.path.join(out, f"{corpus}.{name}.{shaper}.tsv"), "w", encoding="utf-8") as stream:
                        stream.write("line\tcol\tcontext\tinput\topencc\tshaped glyph\n" + "".join(e + "\n" for e in errors))
                    pct = 100 * m["lines_ok"] / m["lines"] if m["lines"] else 0
                    table.append(
                        f"{config:<7} {corpus:<15} {name:<11} {shaper:<6} {m['chars']:>6} {m['errors']:>7}  "
                        f"{m['lines_ok']:>5}/{m['lines']:<5} {pct:6.2f}%  {m['input_not_in_font']}/{m['output_not_in_font']}")
                    if name != font:
                        continue
                    if corpus.startswith("testcases-"):
                        ids = read_lines(os.path.join(work, "corpora", corpus + ".ids"))
                        failed_ids = sorted(ids[i] for i in failing)
                        results[key]["failing_cases"] = failed_ids
                        allowed = ALLOWED_S2T_FAILURES if config == "s2t" else set()
                        if not set(failed_ids) <= allowed:
                            ok = False
                            table.append(f"FAIL {key}: unexpected failing cases {sorted(set(failed_ids) - allowed)}")
                    elif m["errors"] or m["length_changed_lines"] or m["glyph_count_not_char_count_lines"]:
                        ok = False
                        table.append(f"FAIL {key}: {m['errors']} errors (see accuracy/{corpus}.{name}.{shaper}.tsv)")
    with open(os.path.join(out, "accuracy.json"), "w", encoding="utf-8") as stream:
        json.dump(results, stream, ensure_ascii=False, indent=1, sort_keys=True)
    print("\n".join(table))
    print("RESULT accuracy:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


# ---------------------------------------------------------------- upright


def cmd_upright(work, source, font):
    from fontTools.ttLib import TTFont

    src = TTFont(source)
    built = TTFont(os.path.join(work, "fonts", font + ".ttf"))
    A, D = src["OS/2"].sTypoAscender, src["OS/2"].sTypoDescender
    src_order, built_order = src.getGlyphOrder(), built.getGlyphOrder()
    src_cmap = best_cmap(src)
    built_cmap = best_cmap(built)
    cache = {}

    def coords(tt, order, gid):
        key = (id(tt), gid)
        if key not in cache:
            cache[key] = [tuple(p) for p in tt["glyf"][order[gid]].getCoordinates(tt["glyf"])[0]]
        return cache[key]

    def turned(gid):
        # The engine's quarter turn (design §5.3): x' = A − y, y' = x + ⌊(A + D − adv)/2⌋.
        adv = src["hmtx"][src_order[gid]][0] or (A - D)
        shift = (A + D - adv) // 2
        return [(A - y, x + shift) for x, y in coords(src, src_order, gid)]

    counts = collections.Counter()
    examples = collections.defaultdict(list)
    glyphs = collections.defaultdict(set)
    for corpus in ["testcases-s2tw", *NATURAL]:
        inputs = read_lines(os.path.join(work, "corpora", corpus + ".txt"))
        wanted = expected_lines(work, corpus, "s2tw")
        for shaper in ("hb", "ct"):
            rows = load_shaped(work, font, corpus, shaper)
            for i, (line, want) in enumerate(zip(inputs, wanted)):
                if len(line) != len(want):
                    continue
                got = per_code_point(rows[i], len(line))
                for j, (c, o) in enumerate(zip(line, want)):
                    if not has_han(c) or ord(c) not in built_cmap or ord(o) not in src_cmap or got[j] is None:
                        continue
                    g, source_gid = got[j], src_cmap[ord(o)]
                    if g < 0:
                        kind = "fallback"
                    elif coords(built, built_order, g) == turned(source_gid):
                        kind = "turned"
                    elif coords(built, built_order, g) == coords(src, src_order, source_gid):
                        kind = "upright"
                    else:
                        kind = "other"
                    counts[f"{shaper}:{kind}"] += 1
                    glyphs[kind].add(g)
                    if kind != "turned" and len(examples[kind]) < 10:
                        examples[kind].append(f"{corpus}:{i + 1}:{j} {c}→{o} glyph {g}")
    report = {
        "positions": dict(counts),
        "distinct_glyphs": {k: len(v) for k, v in glyphs.items()},
        "examples": examples,
    }
    print(json.dumps(report, ensure_ascii=False, indent=1))
    bad = sum(n for k, n in counts.items() if not k.endswith(":turned"))
    ok = bad == 0 and counts["hb:turned"] > 0 and counts["ct:turned"] > 0
    print(f"RESULT upright: {'PASS' if ok else 'FAIL'}: {counts['hb:turned']} (HarfBuzz) and {counts['ct:turned']} "
          f"(CoreText) Han positions turned and correct, {bad} upright or wrong")
    return 0 if ok else 1


# ---------------------------------------------------------------- parse


def cmd_parse(source, *fonts):
    from fontTools.misc.testTools import getXML
    from fontTools.ttLib import TTFont

    def open_by_id(path):
        # Glyphs named by ID: pseudoVertical's clones switch post to format 3
        # (no names), and the lookups must be compared glyph ID for glyph ID.
        font = TTFont(path, lazy=False)
        font.setGlyphOrder([f"gid{i}" for i in range(font["maxp"].numGlyphs)])
        font.ensureDecompiled(recurse=True)  # every table and every glyph: a full parse
        return font

    src = open_by_id(source)
    src_gsub = src["GSUB"].table
    src_raw = src.reader["GSUB"]

    def unwrapped(lookup):
        return [st.ExtSubTable if lookup.LookupType == 7 else st for st in lookup.SubTable]

    ok = True
    for path in fonts:
        font = open_by_id(path)
        name = os.path.basename(path)
        raw = font.reader["GSUB"]
        if not name.startswith("phrases"):
            same = raw == src_raw
            print(f"{'PASS' if same else 'FAIL'} {name}: {len(font.keys())} tables decompiled; GSUB "
                  f"{'byte-identical to the source' if same else 'differs from the source'}")
            ok &= same
            continue
        gsub = font["GSUB"].table
        problems = []
        base = len(src_gsub.LookupList.Lookup)
        lookups = gsub.LookupList.Lookup
        for index, old in enumerate(src_gsub.LookupList.Lookup):
            new = lookups[index]
            if new.LookupType != 7 or new.LookupFlag != old.LookupFlag:
                problems.append(f"lookup {index} not an extension lookup with the old flag")
            if [getXML(st.toXML, font) for st in unwrapped(new)] != [getXML(st.toXML, src) for st in unwrapped(old)]:
                problems.append(f"lookup {index} changed")
        added = [(lk.LookupType, {st.ExtSubTable.LookupType for st in lk.SubTable}) for lk in lookups[base:]]
        if not added or added[0] != (7, {5}) or any(a != (7, {1}) for a in added[1:]):
            problems.append(f"added lookups {added}")
        records = gsub.FeatureList.FeatureRecord
        langsys = 0
        for sr in gsub.ScriptList.ScriptRecord:
            systems = ([sr.Script.DefaultLangSys] if sr.Script.DefaultLangSys else []) + [
                lr.LangSys for lr in sr.Script.LangSysRecord]
            for ls in systems:
                langsys += 1
                rlig = [i for i in ls.FeatureIndex if records[i].FeatureTag == "rlig"]
                if not rlig or base not in records[rlig[0]].Feature.LookupListIndex:
                    problems.append(f"script {sr.ScriptTag}: rlig does not reach lookup {base}")
        for record in src_gsub.FeatureList.FeatureRecord:
            match = [r for r in records if r.FeatureTag == record.FeatureTag
                     and r.Feature.LookupListIndex[:len(record.Feature.LookupListIndex)] == record.Feature.LookupListIndex]
            if not match:
                problems.append(f"feature {record.FeatureTag} lost its lookups")
        context = sum(len(lk.SubTable) for lk in lookups[base:base + 1])
        print(f"{'PASS' if not problems else 'FAIL'} {name}: {len(font.keys())} tables decompiled; GSUB {len(raw)} bytes, "
              f"{base} source lookups unchanged behind extensions, {len(added)} added ({context} context subtables, "
              f"{len(added) - 1} single), rlig in {langsys} language systems")
        for problem in problems[:20]:
            print("   ", problem)
        ok &= not problems
    print("RESULT parse:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    commands = {"dicts": cmd_dicts, "corpora": cmd_corpora, "shape": cmd_shape, "accuracy": cmd_accuracy,
                "upright": cmd_upright, "parse": cmd_parse}
    sys.exit(commands[sys.argv[1]](*sys.argv[2:]))
