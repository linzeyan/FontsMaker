"""Derives phrase rules for one character-level font and builds GSUB variants.

Usage: python3 -I derive.py <work> <source.ttf> <built.ttf> <tw|s> <name> <tag> <variant,...>

Variants (question 2, each measured rather than assumed to matter):
  R0  changed phrases only, dictionary (code point) order inside a rule set:
      a shorter phrase can win over a longer one starting at the same glyph
  R1  changed phrases, longest first
  R2  R1 + identity "blocking" rules for unchanged phrases that change the
      segmentation (fixpoint closure, see model.blocking_closure)
  R3  R1 + every unchanged phrase as an identity rule (full dictionary)
  NC  changed characters as single-glyph chain rules with the rest of the
      phrase as backtrack/lookahead: the phrase span is not consumed
Writes work/rules/<name>/ (TSVs, stats.json) and work/fonts/<name>-<variant>.ttf.
"""

import collections
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model  # noqa: E402
from fontTools.ttLib import TTFont  # noqa: E402


def rule_sets(work, source, built, mode):
    opencc = model.opencc_from_dir(os.path.join(work, "opencc"), taiwan=(mode == "tw"))
    phrases = dict(opencc.phrases.entries)
    src_cmap = model.best_cmap(source)
    built_cmap = model.best_cmap(built)
    rules, stats = model.derive_rules(phrases, opencc, src_cmap, built_cmap, load_gidmap(built))
    active = [r for r in rules if r.kind in ("changed", "partial")]
    passive = [r for r in rules if r.kind in ("unchanged", "dropped")]
    active_d, active_conflicts = model.dedupe_glyph_space(active)
    active_glyphs = {r.glyphs for r in active_d}
    # A passive key whose glyphs equal an active rule's is the same input to
    # the shaper: the active rule already consumes that span.
    passive_d, _ = model.dedupe_glyph_space([r for r in passive if r.glyphs not in active_glyphs])
    shadowed = sum(1 for r in passive if r.glyphs in active_glyphs)
    first, closure = model.blocking_closure(active_d, passive_d)
    sets = {
        "R0": (active_d, lambda r: r.key),
        "R1": (active_d, lambda r: (-len(r.glyphs), r.key)),
        "R2": (active_d + closure, lambda r: (-len(r.glyphs), r.key)),
        "R3": (active_d + passive_d, lambda r: (-len(r.glyphs), r.key)),
        "NC": (active_d, None),
    }
    info = {
        "phrases": len(phrases),
        "kinds": dict(stats),
        "active_after_glyph_dedupe": len(active_d),
        "active_glyph_conflicts": len(active_conflicts),
        "passive_after_glyph_dedupe": len(passive_d),
        "passive_shadowed_by_active_glyphs": shadowed,
        "blockers_first_order": len(first),
        "blockers_closure": len(closure),
        "max_targets_per_glyph": max(
            (len(v) for v in _targets(active_d).values()), default=0
        ),
    }
    return sets, info, rules, active_conflicts, closure, src_cmap, built_cmap


def load_gidmap(font_path):
    """Alias glyph → drawn glyph, written by clones.py next to the font."""
    path = font_path[: -len(".ttf")] + ".gidmap.json"
    if not os.path.exists(path):
        return None
    with open(path) as stream:
        return {int(k): v for k, v in json.load(stream).items() if int(k) != v}


def _targets(rules):
    t = collections.defaultdict(set)
    for r in rules:
        for _, a, b in r.subs:
            t[a].add(b)
    return t


def write_rules(path, rules, src_cmap):
    rev = model.reverse_cmap(src_cmap)
    with open(path, "w", encoding="utf-8") as out:
        out.write("key\topencc\tkind\tlength\tsubstitutions(position:glyph->glyph)\n")
        for r in rules:
            subs = " ".join(f"{p}:{a}->{b}({''.join(chr(c) for c in rev[b][:1])})" for p, a, b in r.subs)
            out.write(f"{r.key}\t{r.target}\t{r.kind}\t{len(r.key)}\t{subs}\n")


def build_variant(built, out_path, rules, order, tag, where=lambda s, l: True, noconsume=False):
    font = TTFont(built, recalcBBoxes=False, recalcTimestamp=False)
    before = len(font.reader["GSUB"])
    info = model.add_phrase_lookups(font, rules, tag=tag, where=where, order=order, noconsume=noconsume)
    font.save(out_path)
    font.close()
    report = model.gsub_report(out_path)
    info.update(
        {
            "gsub_bytes_before": before,
            "gsub_bytes_after": report["bytes"],
            "file_bytes_before": os.path.getsize(built),
            "file_bytes_after": os.path.getsize(out_path),
            "lookup_types_after": [l["type"] for l in report["lookups"]],
            "extension_lookups": sum(1 for l in report["lookups"] if l["type"] == 7),
        }
    )
    return info


def main():
    work, source, built, mode, name, tag, variants = sys.argv[1:8]
    sets, info, rules, conflicts, closure, src_cmap, built_cmap = rule_sets(work, source, built, mode)
    rdir = os.path.join(work, "rules", name)
    fdir = os.path.join(work, "fonts")
    os.makedirs(rdir, exist_ok=True)
    os.makedirs(fdir, exist_ok=True)
    write_rules(os.path.join(rdir, "all-phrases.tsv"), rules, src_cmap)
    write_rules(os.path.join(rdir, "active.tsv"), sets["R1"][0], src_cmap)
    write_rules(os.path.join(rdir, "blockers.tsv"), closure, src_cmap)
    with open(os.path.join(rdir, "glyph-conflicts.tsv"), "w", encoding="utf-8") as out:
        out.write("kept_key\tkept_target\tdropped_key\tdropped_target\n")
        for a, b in conflicts:
            out.write(f"{a.key}\t{a.target}\t{b.key}\t{b.target}\n")
    # Dropped-glyph detail: which traditional characters are missing.
    missing = collections.Counter()
    for r in rules:
        if r.kind in ("partial", "dropped"):
            for c in r.target:
                if ord(c) not in src_cmap:
                    missing[c] += 1
    info["missing_traditional_chars"] = dict(missing.most_common())
    info["variants"] = {}
    for variant in variants.split(","):
        rs, order = sets[variant]
        path = os.path.join(fdir, f"{name}-{variant}.ttf")
        info["variants"][variant] = build_variant(built, path, rs, order, tag, noconsume=(variant == "NC"))
        # Predicted shaping for the simulator cross-check.
        if variant != "NC":
            ordered = sorted(rs, key=order) if variant != "R0" else sorted(rs, key=lambda r: r.key)
            by_first = collections.defaultdict(list)
            for r in ordered:
                by_first[r.glyphs[0]].append(r)
            by_first = {k: sorted(v, key=order) for k, v in by_first.items()}
            with open(os.path.join(rdir, f"simulated-{variant}.json"), "w", encoding="utf-8") as out:
                sims = {}
                for corpus in sorted(os.listdir(os.path.join(work, "corpora"))):
                    if not corpus.endswith((".s.txt", ".t.txt")):
                        continue
                    lines = model.read_lines(os.path.join(work, "corpora", corpus))
                    sims[corpus] = [
                        model.simulate([built_cmap.get(ord(c), 0) for c in line], by_first) for line in lines
                    ]
                json.dump(sims, out)
        print(variant, json.dumps(info["variants"][variant]))
    model.dump_json(os.path.join(rdir, "stats.json"), info)
    print(json.dumps({k: v for k, v in info.items() if k not in ("variants", "missing_traditional_chars")}, ensure_ascii=False))


if __name__ == "__main__":
    main()
