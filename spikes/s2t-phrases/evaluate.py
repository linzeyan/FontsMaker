"""Accuracy against the oracle (question 3) and side effects on traditional
text (question 4), from the shaped glyphs written by shape.py.

Usage: python3 -I evaluate.py <work> <source.ttf> <out dir>

Agreement is per code point: the shaped glyph must equal the source font's
glyph of the character OpenCC outputs. Excluded (counted separately): spaces,
input characters the font has no glyph for, and output characters the font
cannot show (no font could match those). A sentence agrees when every one of
its counted code points does.
"""

import collections
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import derive  # noqa: E402
import model  # noqa: E402

work, source, out = sys.argv[1:4]
cdir = os.path.join(work, "corpora")
odir = os.path.join(work, "oracle")
os.makedirs(out, exist_ok=True)
src_cmap = model.best_cmap(source)
rev = model.reverse_cmap(src_cmap)
st_chars = model.load_dict(os.path.join(work, "opencc", "STCharacters.txt"))

GROUPS = [
    # (oracle, baseline, fonts); the first font is the character-level baseline
    ("s2tw", "char-tw", ["char-tw", "char-tw-R0", "char-tw-R1", "char-tw-R2", "char-tw-R3", "char-tw-NC", "char-tw-clones-R2"]),
    ("s2t", "char-s", ["char-s", "char-s-R1", "char-s-R2"]),
    ("s2t", None, ["gk-w"]),
    ("s2tw", None, ["gk-w", "gk-tw"]),
    ("stock-s2twp", None, ["gk-tw"]),
]
SHAPERS = ("hb", "ct")


def shaped_path(font, corpus, shaper):
    return os.path.join(work, "shaped", font, f"{corpus}.{shaper}.jsonl")


def load_shaped(font, corpus, shaper, gidmap):
    rows = []
    with open(shaped_path(font, corpus, shaper), encoding="utf-8") as stream:
        for line in stream:
            glyphs = json.loads(line)
            if gidmap is not None:
                glyphs = [[gidmap.get(str(g), -2) if g >= 0 else g, cl, ax, ay] for g, cl, ax, ay in glyphs]
            rows.append(glyphs)
    return rows


def per_cp(glyphs, n):
    """Glyphs of each code point. One glyph per code point (every font here
    in horizontal text) is aligned by order: a ligature + multiple
    substitution (GuanKiapTsingKhai -W) restores the glyph count but merges
    the clusters, which `merged_clusters` counts separately."""
    if len(glyphs) == n:
        return [(g,) for g, *_ in glyphs]
    slots = [[] for _ in range(n)]
    for g, cl, _, _ in glyphs:
        if 0 <= cl < n:
            slots[cl].append(g)
    return [tuple(s) for s in slots]


def merged_clusters(glyphs, n):
    """Code points that do not start a cluster of their own."""
    return n - len({cl for _, cl, _, _ in glyphs})


def chars_of(gid):
    if gid is None:
        return "∅"
    if gid == -1:
        return "<fallback>"
    if gid == -2:
        return "<unmapped>"
    cps = rev.get(gid)
    return "/".join(chr(c) for c in cps[:3]) if cps else f"#{gid}"


def font_cmap(font):
    path = os.path.join(work, "fonts", font + ".ttf")
    return model.best_cmap(path) if os.path.exists(path) else None


def gidmap_of(font):
    """Glyph ID → source glyph ID: prior-art fonts have their own glyph order,
    and alias glyphs (clones.py) draw another glyph. Variants share the map of
    the font they were built from."""
    for name in (font, re.sub(r"-(R\d|NC)$", "", font)):
        path = os.path.join(work, "fonts", name + ".gidmap.json")
        if os.path.exists(path):
            with open(path) as stream:
                return json.load(stream)
    return None


simplified = sorted(f[:-6] for f in os.listdir(cdir) if f.endswith(".s.txt"))
traditional = sorted(f[:-6] for f in os.listdir(cdir) if f.endswith(".t.txt"))
metrics = {}
cmaps = {}

# ------------------------------------------------------------ accuracy
for oracle, baseline, fonts in GROUPS:
    for corpus in simplified:
        inputs = model.read_lines(os.path.join(cdir, corpus + ".s.txt"))
        expected_text = model.read_lines(os.path.join(odir, f"{corpus}.{oracle}.txt"))
        for shaper in SHAPERS:
            base_rows = None
            if baseline and os.path.exists(shaped_path(baseline, corpus + ".s", shaper)):
                base_rows = load_shaped(baseline, corpus + ".s", shaper, gidmap_of(baseline))
            for font in fonts:
                if not os.path.exists(shaped_path(font, corpus + ".s", shaper)):
                    continue
                cmap = cmaps.setdefault(font, font_cmap(font))
                gidmap = gidmap_of(font)
                rows = load_shaped(font, corpus + ".s", shaper, gidmap)
                m = collections.Counter()
                patterns = collections.Counter()
                lines_out = []
                for i, (line, want) in enumerate(zip(inputs, expected_text)):
                    if len(line) != len(want):
                        m["length_changed_lines"] += 1
                        continue
                    got = per_cp(rows[i], len(line))
                    base = per_cp(base_rows[i], len(line)) if base_rows is not None else None
                    m["merged_clusters"] += merged_clusters(rows[i], len(line))
                    m["glyph_count_not_char_count_lines"] += len(rows[i]) != len(line)
                    line_ok = True
                    for j, (c, o) in enumerate(zip(line, want)):
                        if c.isspace():
                            continue
                        if ord(c) not in cmap:
                            m["input_not_in_font"] += 1
                            continue
                        exp = src_cmap.get(ord(o))
                        if exp is None:
                            m["oracle_char_not_in_font"] += 1
                            continue
                        m["chars"] += 1
                        convertible = c in st_chars
                        m["convertible_chars"] += convertible
                        ok = got[j] == (exp,)
                        base_ok = base[j] == (exp,) if base is not None else None
                        if base is not None and got[j] != base[j]:
                            m["differs_from_baseline"] += 1
                        if not ok:
                            line_ok = False
                            m["errors"] += 1
                            # Punctuation policy (GuanKiapTsingKhai -W turns “” into 「」)
                            # is not a conversion error; Han-only keeps the comparison fair.
                            m["han_errors"] += model.has_han(c)
                            status = "still" if base_ok is False else ("broken" if base_ok else "-")
                            m[f"errors_{status}"] += 1
                            g = got[j][0] if len(got[j]) == 1 else None
                            patterns[(c, o, chars_of(g))] += 1
                            ctx = line[max(0, j - 6) : j] + "[" + c + "]" + line[j + 1 : j + 7]
                            lines_out.append(
                                f"{i + 1}\t{j}\t{ctx}\t{c}\t{o}\t{'+'.join(chars_of(x) for x in got[j])}\t"
                                f"{'+'.join(chars_of(x) for x in base[j]) if base is not None else ''}\t{status}"
                            )
                        elif base_ok is False:
                            m["fixed_vs_baseline"] += 1
                    m["lines"] += 1
                    m["lines_ok"] += line_ok
                    # Advances: the substitutes are full-width like the glyphs they
                    # replace; any difference would move text on the page.
                    if base_rows is not None and len(rows[i]) == len(base_rows[i]):
                        m["advance_diffs"] += sum(
                            1 for a, b in zip(rows[i], base_rows[i]) if (a[2], a[3]) != (b[2], b[3])
                        )
                    elif base_rows is not None:
                        m["glyph_count_diffs"] += 1
                key = f"{oracle}|{corpus}|{font}|{shaper}"
                metrics[key] = dict(m)
                metrics[key]["top_errors"] = [
                    {"input": a, "oracle": b, "got": c, "count": n} for (a, b, c), n in patterns.most_common(15)
                ]
                path = os.path.join(out, "mismatches", f"{corpus}.{oracle}.{font}.{shaper}.tsv")
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w", encoding="utf-8") as stream:
                    stream.write("line\tcol\tcontext\tinput\topencc\tshaped\tchar-level font\tvs char-level\n")
                    stream.write("\n".join(lines_out) + ("\n" if lines_out else ""))

# ------------------------------------------------------------ simulator vs shapers
sim = {}
sim_examples = {}
for name, variants in (("char-tw", ("R0", "R1", "R2", "R3")), ("char-s", ("R1", "R2")), ("char-tw-clones", ("R2",))):
    for variant in variants:
        path = os.path.join(work, "rules", name, f"simulated-{variant}.json")
        if not os.path.exists(path):
            continue
        with open(path) as stream:
            predicted = json.load(stream)
        font = f"{name}-{variant}"
        for corpus, lines in predicted.items():
            stem = corpus[:-4]
            for shaper in SHAPERS:
                if not os.path.exists(shaped_path(font, stem, shaper)):
                    continue
                rows = load_shaped(font, stem, shaper, None)
                text = model.read_lines(os.path.join(cdir, corpus))
                # CoreText shows a missing character from a fallback font (-1);
                # HarfBuzz and the simulator use .notdef (0).
                differ = [i for i, (p, r) in enumerate(zip(lines, rows)) if [max(g, 0) for g, *_ in r] != p]
                sim[f"{font}|{stem}|{shaper}"] = len(differ)
                for i in differ[:3]:
                    # Shapers hide default-ignorables (U+200B) behind another glyph;
                    # the simulator reads the cmap. Listed so each case can be checked.
                    odd = sorted({f"U+{ord(ch):04X}" for ch in text[i] if not ch.isprintable()})
                    sim_examples.setdefault(f"{stem}|line {i + 1}", odd)
metrics["simulator_vs_shaper_differing_lines"] = sim
metrics["simulator_vs_shaper_examples"] = sim_examples

# ------------------------------------------------------------ traditional side effects
side = {}
attributions = {}
for name, mode, variants in (("char-tw", "tw", ("R1", "R2")), ("char-s", "s", ("R2",)), ("char-tw-clones", "tw", ("R2",))):
    built = os.path.join(work, "fonts", name + ".ttf")
    if not os.path.exists(built):
        continue
    sets = derive.rule_sets(work, source, built, mode)[0]
    built_cmap = model.best_cmap(built)
    for corpus in traditional:
        lines = model.read_lines(os.path.join(cdir, corpus + ".t.txt"))
        for shaper in SHAPERS:
            if not os.path.exists(shaped_path(name, corpus + ".t", shaper)):
                continue
            base_rows = load_shaped(name, corpus + ".t", shaper, gidmap_of(name))
            for variant in variants:
                font = f"{name}-{variant}"
                if not os.path.exists(shaped_path(font, corpus + ".t", shaper)):
                    continue
                rules, order = sets[variant]
                by_first = collections.defaultdict(list)
                for r in sorted(rules, key=order):
                    by_first[r.glyphs[0]].append(r)
                rows = load_shaped(font, corpus + ".t", shaper, gidmap_of(font))
                c = collections.Counter()
                rows_out = []
                for i, line in enumerate(lines):
                    got = per_cp(rows[i], len(line))
                    base = per_cp(base_rows[i], len(line))
                    trace = []
                    model.simulate([built_cmap.get(ord(ch), 0) for ch in line], by_first, trace)
                    for j, ch in enumerate(line):
                        if ch.isspace() or ord(ch) not in built_cmap:
                            continue
                        c["chars"] += 1
                        own = src_cmap.get(ord(ch))
                        c["char_level_not_own_glyph"] += base[j] != (own,)
                        c["phrase_font_not_own_glyph"] += got[j] != (own,)
                        if got[j] != base[j]:
                            c["changed_by_rules"] += 1
                            restored = got[j] == (own,)
                            c["changed_to_own_glyph" if restored else "changed_away_from_own_glyph"] += 1
                            rule = next((r for s, r in trace if s <= j < s + len(r.glyphs)), None)
                            rows_out.append(
                                f"{i + 1}\t{j}\t{line[max(0, j - 6):j]}[{ch}]{line[j + 1:j + 7]}\t{ch}\t"
                                f"{'+'.join(chars_of(x) for x in base[j])}\t{'+'.join(chars_of(x) for x in got[j])}\t"
                                f"{'restores' if restored else 'changes'}\t{rule.key if rule else '?'}\t{rule.target if rule else '?'}"
                            )
                side[f"{corpus}|{font}|{shaper}"] = dict(c)
                path = os.path.join(out, "traditional", f"{corpus}.{font}.{shaper}.tsv")
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w", encoding="utf-8") as stream:
                    stream.write("line\tcol\tcontext\tchar\tchar-level font\tphrase font\teffect\trule key (simplified)\trule target\n")
                    stream.write("\n".join(rows_out) + ("\n" if rows_out else ""))
metrics["traditional"] = side

model.dump_json(os.path.join(out, "metrics.json"), metrics)

# ------------------------------------------------------------ readable table
with open(os.path.join(out, "accuracy.txt"), "w", encoding="utf-8") as t:
    t.write("oracle  corpus            font          shaper  chars   errors  err%    sentences ok     fixed  broken  adv-diff  excluded(in/out)  han-errors  merged-clusters\n")
    for key, m in metrics.items():
        if "|" not in key or key.count("|") != 3:
            continue
        oracle, corpus, font, shaper = key.split("|")
        chars = m.get("chars", 0)
        lines = m.get("lines", 0)
        t.write(
            f"{oracle:<7} {corpus:<17} {font:<13} {shaper:<6} {chars:>6} {m.get('errors', 0):>7} "
            f"{100 * m.get('errors', 0) / max(chars, 1):6.3f}  {m.get('lines_ok', 0):>6}/{lines:<6} "
            f"{100 * m.get('lines_ok', 0) / max(lines, 1):6.2f}%  {m.get('fixed_vs_baseline', 0):>5} "
            f"{m.get('errors_broken', 0):>6}  {m.get('advance_diffs', 0):>8}  "
            f"{m.get('input_not_in_font', 0)}/{m.get('oracle_char_not_in_font', 0)}  "
            f"{m.get('han_errors', 0)}  {m.get('merged_clusters', 0)}\n"
        )
    t.write("\nsimulator vs shaper, differing lines: " + json.dumps(sim) + "\n")
    t.write("simulator vs shaper, examples (non-printable code points on the line): "
            + json.dumps(sim_examples, ensure_ascii=False) + "\n")
    t.write("\ntraditional text: " + json.dumps(side, ensure_ascii=False, indent=1) + "\n")
print(open(os.path.join(out, "accuracy.txt"), encoding="utf-8").read())
