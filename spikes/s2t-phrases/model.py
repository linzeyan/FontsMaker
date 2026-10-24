"""Shared model for the s2t phrase spike.

Three things live here because every step needs the same definition of them:
- OpenCC 1.4.2 matching semantics (mirrors src/MaxMatchSegmentation.cpp,
  Conversion.cpp, DictGroup.cpp at the pinned commit), used to derive rules and
  cross-checked against the real `opencc` binary, which stays the oracle;
- the font's character-level conversion, read from a built font's cmap;
- GSUB construction and merging into an existing table, the part a production
  Swift builder would have to reproduce.
"""

import bisect
import collections
import json
import os
import re

from fontTools.otlLib import builder as otl
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables import otTables as ot

# ---------------------------------------------------------------- OpenCC


def load_dict(path):
    """OpenCC text dictionary: key<TAB>value value ...; '#' starts a comment."""
    entries = {}
    with open(path, encoding="utf-8") as stream:
        for line in stream:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            key, values = line.split("\t")
            entries[key] = values.split(" ")
    return entries


class Matcher:
    """Longest-prefix lookup, OpenCC's Dict::MatchPrefix."""

    def __init__(self, entries):
        self.entries = entries
        self.lengths = sorted({len(k) for k in entries}, reverse=True)

    def match(self, text, start, end):
        for length in self.lengths:
            if start + length <= end:
                values = self.entries.get(text[start : start + length])
                if values is not None:
                    return length, values
        return None


def fmm(text, matchers):
    """Conversion::AppendConverted: forward maximum matching where the first
    matcher with any match wins (match_policy short_circuit) and the first
    value is used (DictEntry::GetDefault)."""
    out = []
    i, end = 0, len(text)
    while i < end:
        for matcher in matchers:
            hit = matcher.match(text, i, end)
            if hit:
                out.append(hit[1][0])
                i += hit[0]
                break
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


class OpenCC:
    """s2t / s2tw as configured in data/config at the pinned commit.

    `phrases` is the union group STPhrases + STPhrases_GeneratedFromRegionalPhrases:
    union picks the longest key over both, ties go to the first dict, which a
    merged dict with STPhrases entries taking precedence reproduces exactly."""

    def __init__(self, phrases, characters, tw_phrases=None, tw_characters=None, normalization=None):
        self.phrases = Matcher(phrases)
        self.characters = Matcher(characters)
        self.tw = [Matcher(tw_phrases), Matcher(tw_characters)] if tw_characters is not None else None
        self.normalization = Matcher(normalization) if normalization else None

    def segments(self, text):
        """MaxMatchSegmentation: a phrase match is its own segment; unmatched
        characters accumulate into one segment."""
        out, run = [], []
        i, end = 0, len(text)
        while i < end:
            hit = self.phrases.match(text, i, end)
            if hit:
                if run:
                    out.append("".join(run))
                    run = []
                out.append(text[i : i + hit[0]])
                i += hit[0]
            else:
                run.append(text[i])
                i += 1
        if run:
            out.append("".join(run))
        return out

    def convert_segment(self, segment):
        converted = fmm(segment, [self.phrases, self.characters])
        return fmm(converted, self.tw) if self.tw else converted

    def convert(self, text):
        if self.normalization:
            text = fmm(text, [self.normalization])
        # s2t.json has no segmentation (one segment); with a single conversion
        # step that equals segmenting first, so both configs share this path.
        return "".join(self.convert_segment(s) for s in self.segments(text))


def opencc_from_dir(directory, taiwan, generated_name="STPhrases_GeneratedFromRegionalPhrases.txt"):
    """Loads the dictionaries the oracle config uses from `directory`."""
    path = lambda name: os.path.join(directory, name)
    phrases = load_dict(path(generated_name))
    phrases.update(load_dict(path("STPhrases.txt")))  # STPhrases wins ties
    return OpenCC(
        phrases,
        load_dict(path("STCharacters.txt")),
        load_dict(path("TWVariantsPhrases.txt")) if taiwan else None,
        load_dict(path("TWVariants.txt")) if taiwan else None,
        load_dict(path("CJK_Compatibility_Ideographs.txt")),
    )


# ---------------------------------------------------------------- fonts


def best_cmap(path):
    font = TTFont(path, lazy=True)
    cmap = dict(font["cmap"].getBestCmap())
    order = font.getGlyphOrder()
    ids = {name: index for index, name in enumerate(order)}
    font.close()
    return {cp: ids[name] for cp, name in cmap.items()}


def reverse_cmap(cmap):
    out = collections.defaultdict(list)
    for cp, gid in sorted(cmap.items()):
        out[gid].append(cp)
    return out


# ---------------------------------------------------------------- rules


class Rule:
    __slots__ = ("key", "target", "glyphs", "subs", "kind")

    def __init__(self, key, target, glyphs, subs, kind):
        self.key = key  # simplified phrase (dictionary key)
        self.target = target  # OpenCC output for the phrase segment
        self.glyphs = glyphs  # input: post-cmap glyph IDs of the key
        self.subs = subs  # [(position, from glyph, to glyph)]
        self.kind = kind


def derive_rules(phrases, opencc, src_cmap, built_cmap, renders=None):
    """Classifies every phrase against the character-level font.

    Glyph space: the input is what the built font's cmap yields for the key
    (character-level result); the wanted glyph for an output character is the
    source font's glyph of that character (s2t never edits outlines, so glyph
    IDs are shared between source and built font). `renders` maps an alias
    glyph (a composite that only draws another glyph) to the glyph it draws,
    so an alias already showing the wanted shape needs no substitution."""
    renders = renders or {}
    stats = collections.Counter()
    rules = []
    for key in sorted(phrases):
        target = opencc.convert_segment(key)
        if len(target) != len(key):
            stats["length_changing"] += 1
            continue
        glyphs = [built_cmap.get(ord(c)) for c in key]
        if None in glyphs:
            stats["key_char_missing_from_font"] += 1
            continue
        wanted = [src_cmap.get(ord(c)) for c in target]
        differs = [i for i in range(len(key)) if wanted[i] != renders.get(glyphs[i], glyphs[i])]
        missing = [i for i in differs if wanted[i] is None]
        subs = [(i, glyphs[i], wanted[i]) for i in differs if wanted[i] is not None]
        if not differs:
            kind = "unchanged"
        elif not missing:
            kind = "changed"
        elif subs:
            kind = "partial"  # some positions fixable, some glyph missing
        else:
            kind = "dropped"  # every differing position lacks its glyph
        stats[kind] += 1
        rules.append(Rule(key, target, tuple(glyphs), subs, kind))
    return rules, stats


def dedupe_glyph_space(rules):
    """Different keys can share one glyph sequence (a simplified and a
    traditional character often map to the same glyph after s2t). The shaper
    cannot tell them apart: keep the first by key order, report the rest."""
    by_glyphs = {}
    conflicts = []
    for rule in rules:
        other = by_glyphs.get(rule.glyphs)
        if other is None:
            by_glyphs[rule.glyphs] = rule
        elif [(i, t) for i, _, t in other.subs] != [(i, t) for i, _, t in rule.subs]:
            conflicts.append((other, rule))
    return list(by_glyphs.values()), conflicts


def blocking_closure(active, candidates):
    """Identity rules needed so the shaper segments like OpenCC.

    A candidate U (no substitution) matters when, in some text, OpenCC would
    consume U and thereby stop an active rule X from matching: X is a proper
    prefix of U, or X starts inside U (overlapping U's tail or lying within).
    Blockers can themselves be pre-empted the same way, so iterate to a
    fixpoint. Returns (first-order set, closure)."""
    active = {r.glyphs for r in active}
    pool = {r.glyphs: r for r in candidates}
    chosen = set()
    first_order = None
    frontier = set(active)
    while True:
        seqs = active | chosen
        full = seqs
        prefixes = {s[:j] for s in seqs for j in range(1, len(s) + 1)}
        added = set()
        for glyphs in pool:
            if glyphs in chosen or glyphs in active:
                continue
            n = len(glyphs)
            hit = any(glyphs[:j] in full for j in range(2, n))
            for k in range(1, n):
                if hit:
                    break
                tail = glyphs[k:]
                if tail in prefixes:
                    hit = True
                elif any(glyphs[k : k + j] in full for j in range(2, n - k)):
                    hit = True
            if hit:
                added.add(glyphs)
        if first_order is None:
            first_order = set(added)
        if not added:
            break
        chosen |= added
    return [pool[g] for g in sorted(first_order)], [pool[g] for g in sorted(chosen)]


def simulate(glyphs, rules_by_first, trace=None):
    """What a shaper does with one context lookup (format 1): at each position
    try the first glyph's rules in order, apply the first full match and
    continue after the matched input sequence. `trace` collects (start, rule)."""
    out = list(glyphs)
    i, n = 0, len(glyphs)
    while i < n:
        for rule in rules_by_first.get(glyphs[i], ()):
            m = len(rule.glyphs)
            if i + m <= n and tuple(glyphs[i : i + m]) == rule.glyphs:
                for pos, _, to in rule.subs:
                    out[i + pos] = to
                if trace is not None:
                    trace.append((i, rule))
                i += m
                break
        else:
            i += 1
    return out


def index_rules(rules):
    by_first = collections.defaultdict(list)
    for rule in rules:
        by_first[rule.glyphs[0]].append(rule)
    return by_first


# ---------------------------------------------------------------- GSUB


def single_lookups(rules):
    """Nested single substitutions. One input glyph can need different
    outputs in different phrases (發 → 髮 in 头发, but 發 elsewhere), and a
    single-substitution lookup is a function, so pair k of a glyph goes into
    lookup k. The count is the largest number of distinct outputs any glyph has."""
    targets = collections.defaultdict(list)
    for rule in rules:
        for _, src, dst in rule.subs:
            if dst not in targets[src]:
                targets[src].append(dst)
    depth = max((len(v) for v in targets.values()), default=0)
    maps = [dict() for _ in range(depth)]
    slot = {}
    for src in sorted(targets):
        for k, dst in enumerate(sorted(targets[src])):
            maps[k][src] = dst
            slot[(src, dst)] = k
    return maps, slot


def build_context_subtables(rules, order, slot, first_single_index, glyph_order, budget=60000, chain=False):
    """Format 1 (glyph sequence) context subtables. All rules that share a first
    glyph go to one subtable in the given order, so 'first match wins' within
    a rule set is the whole story; subtables are cut at ~`budget` bytes so
    16-bit offsets inside each one stay valid.

    `order(rule)` sorts rules of one first glyph (e.g. longest first)."""
    by_first = collections.defaultdict(list)
    for rule in rules:
        by_first[rule.glyphs[0]].append(rule)
    chunks, current, size = [], [], 6
    for first in sorted(by_first):
        group = sorted(by_first[first], key=order)
        cost = 2 + 2 + 2 + sum(2 + 4 + 2 * (len(r.glyphs) - 1) + 4 * len(r.subs) + (4 if chain else 0) for r in group)
        if current and size + cost > budget:
            chunks.append(current)
            current, size = [], 6
        current.append((first, group))
        size += cost
    if current:
        chunks.append(current)

    subtables = []
    for chunk in chunks:
        st = ot.ChainContextSubst() if chain else ot.ContextSubst()
        st.Format = 1
        st.Coverage = otl.buildCoverage([glyph_order[f] for f, _ in chunk], {n: i for i, n in enumerate(glyph_order)})
        sets = []
        for first, group in chunk:
            rs = ot.ChainSubRuleSet() if chain else ot.SubRuleSet()
            items = []
            for rule in group:
                r = ot.ChainSubRule() if chain else ot.SubRule()
                if chain:
                    r.Backtrack, r.BacktrackGlyphCount = [], 0
                    r.LookAhead, r.LookAheadGlyphCount = [], 0
                    r.Input = [glyph_order[g] for g in rule.glyphs[1:]]
                    r.InputGlyphCount = len(rule.glyphs)
                else:
                    r.Input = [glyph_order[g] for g in rule.glyphs[1:]]
                    r.GlyphCount = len(rule.glyphs)
                records = []
                for pos, src, dst in rule.subs:
                    rec = ot.SubstLookupRecord()
                    rec.SequenceIndex = pos
                    rec.LookupListIndex = first_single_index + slot[(src, dst)]
                    records.append(rec)
                r.SubstLookupRecord = records
                r.SubstCount = len(records)
                items.append(r)
            if chain:
                rs.ChainSubRule, rs.ChainSubRuleCount = items, len(items)
            else:
                rs.SubRule, rs.SubRuleCount = items, len(items)
            sets.append(rs)
        if chain:
            st.ChainSubRuleSet, st.ChainSubRuleSetCount = sets, len(sets)
        else:
            st.SubRuleSet, st.SubRuleSetCount = sets, len(sets)
        subtables.append(st)
    return subtables


def build_noconsume_subtables(rules, slot, first_single_index, glyph_order, budget=60000):
    """The tempting alternative: one chain rule per changed character, the rest
    of the phrase as backtrack/lookahead. The shaper then moves on after that
    single glyph, so the phrase span is not consumed (refinement baseline)."""
    entries = []
    for rule in rules:
        for pos, src, dst in rule.subs:
            entries.append((rule, pos, src, dst))
    by_input = collections.defaultdict(list)
    for e in entries:
        by_input[e[2]].append(e)
    chunks, current, size = [], [], 6
    for g in sorted(by_input):
        group = sorted(by_input[g], key=lambda e: (-len(e[0].glyphs), e[0].key))
        cost = 6 + sum(2 + 8 + 2 * len(e[0].glyphs) + 4 for e in group)
        if current and size + cost > budget:
            chunks.append(current)
            current, size = [], 6
        current.append((g, group))
        size += cost
    if current:
        chunks.append(current)
    subtables = []
    gmap = {n: i for i, n in enumerate(glyph_order)}
    for chunk in chunks:
        st = ot.ChainContextSubst()
        st.Format = 1
        st.Coverage = otl.buildCoverage([glyph_order[g] for g, _ in chunk], gmap)
        sets = []
        for _, group in chunk:
            rs = ot.ChainSubRuleSet()
            items = []
            for rule, pos, src, dst in group:
                r = ot.ChainSubRule()
                # Backtrack is stored closest-first.
                r.Backtrack = [glyph_order[x] for x in reversed(rule.glyphs[:pos])]
                r.BacktrackGlyphCount = pos
                r.Input, r.InputGlyphCount = [], 1
                r.LookAhead = [glyph_order[x] for x in rule.glyphs[pos + 1 :]]
                r.LookAheadGlyphCount = len(r.LookAhead)
                rec = ot.SubstLookupRecord()
                rec.SequenceIndex = 0
                rec.LookupListIndex = first_single_index + slot[(src, dst)]
                r.SubstLookupRecord, r.SubstCount = [rec], 1
                items.append(r)
            rs.ChainSubRule, rs.ChainSubRuleCount = items, len(items)
            sets.append(rs)
        st.ChainSubRuleSet, st.ChainSubRuleSetCount = sets, len(sets)
        subtables.append(st)
    return subtables


def make_lookup(lookup_type, subtables):
    lookup = ot.Lookup()
    lookup.LookupType = lookup_type
    lookup.LookupFlag = 0
    lookup.SubTable = subtables
    lookup.SubTableCount = len(subtables)
    return lookup


def merge_feature(gsub, tag, lookup_indices, where):
    """Registers `lookup_indices` under `tag` in the LangSys tables chosen by
    `where(script_tag, lang_tag)` (lang_tag None = default LangSys).

    A LangSys that already has a feature with this tag gets the lookups
    appended to that feature (HarfBuzz uses only the first feature of a tag in
    a LangSys); every other selected LangSys references one new FeatureRecord.
    FeatureList is kept sorted by tag and every LangSys index is remapped."""
    records = gsub.FeatureList.FeatureRecord
    langsys = []
    for sr in gsub.ScriptList.ScriptRecord:
        if sr.Script.DefaultLangSys is not None:
            langsys.append((sr.ScriptTag, None, sr.Script.DefaultLangSys))
        for lr in sr.Script.LangSysRecord:
            langsys.append((sr.ScriptTag, lr.LangSysTag, lr.LangSys))
    new_record = None
    extended = set()
    for script, lang, ls in langsys:
        if not where(script, lang):
            continue
        existing = [i for i in ls.FeatureIndex if records[i].FeatureTag == tag]
        if existing:
            if existing[0] not in extended:
                records[existing[0]].Feature.LookupListIndex.extend(lookup_indices)
                records[existing[0]].Feature.LookupCount = len(records[existing[0]].Feature.LookupListIndex)
                extended.add(existing[0])
            continue
        if new_record is None:
            new_record = ot.FeatureRecord()
            new_record.FeatureTag = tag
            new_record.Feature = ot.Feature()
            new_record.Feature.FeatureParams = None
            new_record.Feature.LookupListIndex = list(lookup_indices)
            new_record.Feature.LookupCount = len(lookup_indices)
            records.append(new_record)
            new_index = len(records) - 1
        ls.FeatureIndex.append(new_index)
        ls.FeatureCount = len(ls.FeatureIndex)
    # Sort FeatureList by tag (stable) and remap.
    order = sorted(range(len(records)), key=lambda i: records[i].FeatureTag)
    remap = {old: new for new, old in enumerate(order)}
    gsub.FeatureList.FeatureRecord = [records[i] for i in order]
    gsub.FeatureList.FeatureCount = len(order)
    for _, _, ls in langsys:
        ls.FeatureIndex = sorted(remap[i] for i in ls.FeatureIndex)
        if ls.ReqFeatureIndex != 0xFFFF:
            ls.ReqFeatureIndex = remap[ls.ReqFeatureIndex]


def add_phrase_lookups(font, rules, tag="rlig", where=lambda s, l: True, order=None, noconsume=False):
    """Appends the phrase lookups to the font's GSUB (creating none: the source
    fonts here all have one) and registers the context lookup under `tag`.
    Returns a dict describing the structure."""
    gsub = font["GSUB"].table
    glyph_order = font.getGlyphOrder()
    base = len(gsub.LookupList.Lookup)
    maps, slot = single_lookups(rules)
    first_single = base + 1
    if noconsume:
        subtables = build_noconsume_subtables(rules, slot, first_single, glyph_order)
        context = make_lookup(6, subtables)
    else:
        order = order or (lambda r: (-len(r.glyphs), r.key))
        subtables = build_context_subtables(rules, order, slot, first_single, glyph_order)
        context = make_lookup(5, subtables)
    singles = []
    for mapping in maps:
        singles.append(
            make_lookup(1, [otl.buildSingleSubstSubtable({glyph_order[a]: glyph_order[b] for a, b in mapping.items()})])
        )
    gsub.LookupList.Lookup.extend([context] + singles)
    gsub.LookupList.LookupCount = len(gsub.LookupList.Lookup)
    merge_feature(gsub, tag, [base], where)
    return {
        "context_lookup_index": base,
        "context_subtables": len(subtables),
        "single_lookups": len(maps),
        "single_pairs": sum(len(m) for m in maps),
        "rules": len(rules),
        "substitutions": sum(len(r.subs) for r in rules),
    }


def gsub_report(path):
    """Structure of a compiled GSUB, from the binary (extension use etc.)."""
    font = TTFont(path, lazy=False)
    raw = font.reader["GSUB"]
    gsub = font["GSUB"].table
    lookups = []
    for i, lookup in enumerate(gsub.LookupList.Lookup):
        lookups.append({"index": i, "type": lookup.LookupType, "subtables": lookup.SubTableCount})
    font.close()
    return {"bytes": len(raw), "lookups": lookups}


# ---------------------------------------------------------------- corpora

SENTENCE_END = re.compile(r"(?<=[。！？!?；;])")


def has_han(text):
    return any("㐀" <= c <= "鿿" or "\U00020000" <= c <= "\U0003ffff" for c in text)


def write_lines(path, lines):
    with open(path, "w", encoding="utf-8", newline="\n") as stream:
        for line in lines:
            stream.write(line + "\n")


def read_lines(path):
    with open(path, encoding="utf-8") as stream:
        return [line.rstrip("\n") for line in stream]


def dump_json(path, value):
    with open(path, "w", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=1, sort_keys=True)
