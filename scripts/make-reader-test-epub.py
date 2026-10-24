#!/usr/bin/env python3
"""Make the e-reader test documents for FontsMaker's fonts: EPUB 3 files and a
TXT to load on KOReader, Kobo, Kindle (Kindle Previewer) or Apple Books.

  python3 -I scripts/make-reader-test-epub.py --out DIR
      [--embed FONT.ttf]...                       one more EPUB per font, with
                                                  the font embedded (@font-face)
      [--check FONT.ttf]... --source SOURCE.ttf   shape the test lines with
                                                  CoreText and say which
                                                  expectation each font meets

Writes to DIR:
  fm-reader-test.epub          no font: choose the font in the reader (KOReader,
                               Kobo); every block uses the reader's font
  fm-reader-test-<font>.epub   the font embedded and set on body; Kindle shows it
                               as "Publisher Font"
  fm-reader-test.txt           the same text without markup
  expected.md                  each test line, what an s2t font must show with
                               and without phrase rules
  check.md                     with --check: per font, line and language tag,
                               which expectation the shaped glyphs match

The input is simplified Chinese. The expected output is computed with the
installed `opencc`: the phrases font must show `opencc -c s2tw` (the presets set
taiwanVariants; pass --config s2t otherwise), the character-level font must show
OpenCC's character table alone (STCharacters, then TWVariants), which is what
the cmap mapping does. Some lines read the same either way (心里长了草: the
phrase rules must not break it); expected.md marks the lines that tell the two
apart.

The test documents never print the expected Traditional text: in an s2t font a
shared code point such as 后 or 里 shows the converted glyph, so the "answer"
would be converted too. Compare the reader against expected.md.

--check needs macOS (CoreText) and swiftc: scripts/ct_shape.swift lays each line
out with default features, the way a reader app does. A font shows the expected
text when its glyphs for the input equal the source font's glyphs for the
expected text (s2t keeps glyph IDs; it only changes cmap and adds GSUB).
"""

import argparse
import hashlib
import html
import json
import os
import shutil
import subprocess
import sys
import tempfile
import uuid
import zipfile

# The sentences from the s2t phrases findings ("實機要測的"). Each one is a word
# that character-level conversion gets wrong, or (心里长了草) one the phrase
# rules could break without blocking rules.
PHRASES = [
    "这个国家的发展为后来里程碑",
    "皇后",
    "心里长了草",
    "头发",
    "公里",
    "宣布",
]
FULL_LINE = "、".join(PHRASES)

# A phrase cut by markup: the text is the same, the reader may shape the parts
# as separate runs. Each entry is (label, xhtml fragment); the plain text is the
# fragment without tags.
SPLIT = [
    ("plain span", "里<span>程碑</span>"),
    ("plain span", "皇<span>后</span>"),
    ("plain span", "头<span>发</span>"),
    ("styled span", '公<span class="u">里</span>'),
    ("styled span", '宣<span class="u">布</span>'),
    ("line break", "公<br/>里"),
]

# For page layout, justification and phrases inside running text; composed for
# this test, no third-party text.
PARAGRAPH = (
    "这个国家的发展为后来的改革立下了里程碑。小镇离省城不过三十公里，镇上的人都说，"
    "那位皇后年轻时最爱在河边梳头发，她的心里长了草，总想往外跑。后来，镇长宣布要在"
    "河上修一座桥，于是大家一起出钱出力，从春天忙到秋天，终于在第一场雪落下以前把桥"
    "修好了。通车那天，老人们穿上最好的衣服，孩子们在桥头放鞭炮，连隔壁村子的人也走"
    "了十几里路赶来看热闹。有人说这座桥是全镇的骄傲，也有人说它只是一座普通的石桥，"
    "但无论如何，从那以后，去省城的路程缩短了一半，镇上的生意也一天比一天好起来。"
)

# Pseudo-vertical: brackets and quotes must turn into their vertical forms, the
# comma, full stop and enumeration comma sit centred (centered) or in the
# vertical position (verticalForms). Latin and digits stay sideways by design.
PUNCTUATION = [
    "「你好，」他说：『今天（星期一）天气很好。』",
    "真的吗？太好了！一、二、三。",
    "【书名】《呐喊》〈序〉——鲁迅……",
    "Kobo 2026，Kindle 3.0。",
]

CSS = """\
body { margin: 0 1em; line-height: 1.5; }
h1 { font-size: 1em; font-family: sans-serif; margin: 0.5em 0; }
p { margin: 0.2em 0; }
p.line { text-indent: 0; }
p.para { text-indent: 2em; text-align: justify; }
.label { font-family: sans-serif; font-size: 0.6em; }
.u { text-decoration: underline; }
/* T6: the column pitch is left to the reader's reading of the font's line
   metrics, which is what a pseudo-vertical font's line height is for. */
.pv p { line-height: normal; }
"""

# The fixed date and the identifier derived from the content keep the files
# byte-identical between runs, so a reader's cache can tell versions apart.
MODIFIED = "2026-01-01T00:00:00Z"
ZIP_TIME = (2026, 1, 1, 0, 0, 0)


def run_opencc(opencc, config, lines):
    result = subprocess.run(
        [opencc, "-c", config], input="\n".join(lines) + "\n", capture_output=True, text=True, check=True
    )
    out = result.stdout.split("\n")
    if out and out[-1] == "":
        out.pop()
    if len(out) != len(lines):
        sys.exit(f"opencc returned {len(out)} lines for {len(lines)}")
    return out


def opencc_data_dir(opencc):
    """The stock configs live next to the dictionaries: <prefix>/share/opencc."""
    binary = shutil.which(opencc)
    if not binary:
        sys.exit(f"{opencc} not found (Homebrew: brew install opencc)")
    prefix = os.path.dirname(os.path.dirname(os.path.realpath(binary)))
    data = os.path.join(prefix, "share", "opencc")
    if not os.path.isfile(os.path.join(data, "STCharacters.ocd2")):
        sys.exit(f"OpenCC dictionaries not found in {data}")
    return data


def char_level_config(data, taiwan_variants, directory):
    """OpenCC's character table alone: what an s2t font without phrase rules
    shows (its cmap maps each simplified character to the first candidate)."""
    st = os.path.join(data, "STCharacters.ocd2")
    chain = [f'{{"dict": {{"type": "ocd2", "file": "{st}"}}}}']
    if taiwan_variants:
        tw = os.path.join(data, "TWVariants.ocd2")
        chain.append(f'{{"dict": {{"type": "ocd2", "file": "{tw}"}}}}')
    path = os.path.join(directory, "char-level.json")
    with open(path, "w", encoding="utf-8") as stream:
        stream.write(
            '{"name": "character level", '
            f'"segmentation": {{"type": "mmseg", "dict": {{"type": "ocd2", "file": "{st}"}}}}, '
            f'"conversion_chain": [{", ".join(chain)}]}}\n'
        )
    return path


def strip_tags(fragment):
    out, inside = [], False
    for c in fragment:
        if c == "<":
            inside = True
        elif c == ">":
            inside = False
        elif not inside:
            out.append(c)
    return "".join(out)


def test_lines():
    """(id, label, simplified text) for every line expected.md and --check cover."""
    lines = [(f"P{i + 1}", "phrase", text) for i, text in enumerate(PHRASES)]
    lines.append(("P7", "all phrases", FULL_LINE))
    lines += [(f"S{i + 1}", label, strip_tags(fragment)) for i, (label, fragment) in enumerate(SPLIT)]
    lines.append(("L1", "paragraph", PARAGRAPH))
    lines += [(f"V{i + 1}", "punctuation", text) for i, text in enumerate(PUNCTUATION)]
    return lines


# ---------------------------------------------------------------- documents


def xhtml(title, body, lang):
    attributes = f' xml:lang="{lang}" lang="{lang}"' if lang else ""
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n<!DOCTYPE html>\n'
        f'<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"{attributes}>\n'
        f'<head><meta charset="utf-8"/><title>{html.escape(title)}</title>'
        '<link rel="stylesheet" type="text/css" href="style.css"/></head>\n'
        f"<body>\n{body}</body>\n</html>\n"
    )


def label(text):
    return f'<span class="label">{html.escape(text)}</span> '


def chapters():
    """(file, title, xhtml body, lang). Labels are ASCII so an s2t font cannot
    change them."""
    phrase_body = "".join(
        f'<p class="line">{label(f"P{i + 1}")}{html.escape(text)}</p>\n' for i, text in enumerate(PHRASES)
    )
    phrase_body += f'<p class="line">{label("P7")}{html.escape(FULL_LINE)}</p>\n'
    out = []
    for number, (lang, name) in enumerate([("zh-Hans", "zh-Hans"), ("zh-Hant", "zh-Hant"), (None, "no lang")], 1):
        title = f"T{number} phrases, {name}"
        out.append((f"t{number}.xhtml", title, f"<h1>{html.escape(title)}</h1>\n{phrase_body}", lang))
    split_body = "".join(
        f'<p class="line">{label(f"S{i + 1} {kind}")}{fragment}</p>\n' for i, (kind, fragment) in enumerate(SPLIT)
    )
    out.append(("t4.xhtml", "T4 phrases split by markup", f"<h1>T4 phrases split by markup</h1>\n{split_body}", "zh-Hans"))
    para_body = f'<p class="para">{html.escape(PARAGRAPH)}</p>\n' * 2
    out.append(("t5.xhtml", "T5 paragraph, justified", f"<h1>T5 paragraph, justified</h1>\n{para_body}", "zh-Hans"))
    punct_body = "".join(
        f'<p class="line">{label(f"V{i + 1}")}{html.escape(text)}</p>\n' for i, text in enumerate(PUNCTUATION)
    )
    punct_body += f'<p class="para">{html.escape(PARAGRAPH)}</p>\n'
    title = "T6 punctuation (pseudo-vertical)"
    out.append(("t6.xhtml", title, f'<h1>{title}</h1>\n<div class="pv">\n{punct_body}</div>\n', "zh-Hans"))
    return out


def nav(items):
    entries = "".join(f'<li><a href="{f}">{html.escape(t)}</a></li>\n' for f, t, _, _ in items)
    return xhtml("Contents", f'<nav epub:type="toc" id="toc"><h1>Contents</h1>\n<ol>\n{entries}</ol></nav>\n', None)


def opf(title, identifier, items, font_file):
    manifest = ['<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
                '<item id="css" href="style.css" media-type="text/css"/>']
    manifest += [f'<item id="{f[:-6]}" href="{f}" media-type="application/xhtml+xml"/>' for f, _, _, _ in items]
    if font_file:
        manifest.append(f'<item id="font" href="fonts/{font_file}" media-type="font/ttf"/>')
    spine = "".join(f'<itemref idref="{f[:-6]}"/>' for f, _, _, _ in items)
    # dc:language is required; "zh" names no script, so T3's unmarked text gets
    # no script from the package either.
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">\n'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        f'<dc:identifier id="uid">urn:uuid:{identifier}</dc:identifier>\n'
        f"<dc:title>{html.escape(title)}</dc:title>\n"
        "<dc:language>zh</dc:language>\n"
        "<dc:creator>FontsMaker</dc:creator>\n"
        f'<meta property="dcterms:modified">{MODIFIED}</meta>\n'
        "</metadata>\n"
        f"<manifest>\n{chr(10).join(manifest)}\n</manifest>\n"
        f"<spine>{spine}</spine>\n</package>\n"
    )


CONTAINER = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
    '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>\n'
    "</container>\n"
)


def write_epub(path, title, font_path):
    items = chapters()
    css = CSS
    font_file = None
    font_bytes = b""
    if font_path:
        font_file = os.path.basename(font_path)
        with open(font_path, "rb") as stream:
            font_bytes = stream.read()
        family = os.path.splitext(font_file)[0]
        # The book's own family name, so the reader's menu entry for the
        # installed font and the embedded copy are never confused.
        css = (
            f'@font-face {{ font-family: "{family} embedded"; src: url("fonts/{font_file}"); }}\n'
            f'body {{ font-family: "{family} embedded", serif; }}\n' + css
        )
    files = [(f, xhtml(t, b, lang)) for f, t, b, lang in items]
    digest = hashlib.sha256((title + css + "".join(x for _, x in files)).encode() + font_bytes).hexdigest()
    identifier = uuid.uuid5(uuid.NAMESPACE_URL, "fontsmaker-reader-test:" + digest)

    def add(archive, name, data, compress=zipfile.ZIP_DEFLATED):
        info = zipfile.ZipInfo(name, ZIP_TIME)
        info.compress_type = compress
        info.external_attr = 0o644 << 16
        archive.writestr(info, data)

    with zipfile.ZipFile(path, "w") as archive:
        # OCF: mimetype first, stored, no extra field.
        add(archive, "mimetype", "application/epub+zip", zipfile.ZIP_STORED)
        add(archive, "META-INF/container.xml", CONTAINER)
        add(archive, "OEBPS/content.opf", opf(title, identifier, items, font_file))
        add(archive, "OEBPS/nav.xhtml", nav(items))
        add(archive, "OEBPS/style.css", css)
        for name, data in files:
            add(archive, f"OEBPS/{name}", data)
        if font_file:
            add(archive, f"OEBPS/fonts/{font_file}", font_bytes)


def write_txt(path):
    # A TXT has no language tags or markup: one copy of the phrases, no T4.
    parts = ["T1 phrases"]
    parts += [f"P{i + 1} {text}" for i, text in enumerate(PHRASES)]
    parts += [f"P7 {FULL_LINE}", "", "T5 paragraph", PARAGRAPH, "", "T6 punctuation"]
    parts += [f"V{i + 1} {text}" for i, text in enumerate(PUNCTUATION)]
    with open(path, "w", encoding="utf-8", newline="\n") as stream:
        stream.write("\n".join(parts) + "\n")


def write_expected(path, lines, phrases, chars, config):
    rows = [
        "# Expected output",
        "",
        f"Input: simplified Chinese. `phrases` = `opencc -c {config}` (what an s2t font with phrase",
        "rules must show); `char` = OpenCC's character table alone (an s2t font without phrase",
        "rules, i.e. the cmap mapping). `differs` = the line tells the two fonts apart. A",
        "pseudo-vertical or bold font without s2t shows the input unchanged.",
        "",
        "| id | kind | input | phrases | char | differs |",
        "|---|---|---|---|---|---|",
    ]
    for (line_id, kind, text), p, c in zip(lines, phrases, chars):
        rows.append(f"| {line_id} | {kind} | {text} | {p} | {c} | {'yes' if p != c else 'no'} |")
    rows += ["", "Characters that differ (input → phrases / char):", ""]
    for (line_id, _, text), p, c in zip(lines, phrases, chars):
        diffs = [f"{i + 1}:{a}→{b}/{d}" for i, (a, b, d) in enumerate(zip(text, p, c)) if b != d]
        if diffs:
            rows.append(f"- {line_id}: " + ", ".join(diffs))
    with open(path, "w", encoding="utf-8", newline="\n") as stream:
        stream.write("\n".join(rows) + "\n")


# ---------------------------------------------------------------- check


def compile_ct_shape(directory):
    source = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ct_shape.swift")
    binary = os.path.join(directory, "ct_shape")
    subprocess.run(["swiftc", "-O", "-o", binary, source], check=True)
    return binary


def shape(ct_shape, font, texts, lang, directory):
    source = os.path.join(directory, "in.txt")
    target = os.path.join(directory, "out.jsonl")
    with open(source, "w", encoding="utf-8", newline="\n") as stream:
        stream.write("\n".join(texts) + "\n")
    command = [ct_shape, font, source, target] + (["--lang", lang] if lang else [])
    subprocess.run(command, check=True)
    with open(target, encoding="utf-8") as stream:
        return [[glyph for glyph, _ in json.loads(line)] for line in stream if line.strip()]


def write_check(path, lines, phrases, chars, fonts, source, directory):
    ct_shape = compile_ct_shape(directory)
    texts = [text for _, _, text in lines]
    # The source font has no rules that change Han characters, so its glyphs
    # for the expected text are the glyphs the expected characters have.
    want_phrases = shape(ct_shape, source, phrases, None, directory)
    want_chars = shape(ct_shape, source, chars, None, directory)
    rows = [
        "# CoreText check",
        "",
        "Per font and language tag: which expectation the shaped glyphs of each line match",
        "(`phrases`, `char`, `both` when the two expectations are the same text, `NEITHER`).",
        f"Source font: {os.path.basename(source)}.",
        "",
    ]
    failures = 0
    for font in fonts:
        rows += [f"## {os.path.basename(font)}", "", "| id | no lang | zh-Hans | zh-Hant |", "|---|---|---|---|"]
        results = {}
        for lang in (None, "zh-Hans", "zh-Hant"):
            got = shape(ct_shape, font, texts, lang, directory)
            for index, glyphs in enumerate(got):
                p, c = glyphs == want_phrases[index], glyphs == want_chars[index]
                verdict = "both" if p and c else "phrases" if p else "char" if c else "NEITHER"
                failures += verdict == "NEITHER"
                results.setdefault(index, []).append(verdict)
        for index, (line_id, _, _) in enumerate(lines):
            rows.append(f"| {line_id} | " + " | ".join(results[index]) + " |")
        rows.append("")
    with open(path, "w", encoding="utf-8", newline="\n") as stream:
        stream.write("\n".join(rows) + "\n")
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", required=True, help="output directory (created if missing)")
    parser.add_argument("--embed", action="append", default=[], metavar="FONT", help="embed this font in one more EPUB")
    parser.add_argument("--check", action="append", default=[], metavar="FONT", help="shape the test lines with this font")
    parser.add_argument("--source", help="the unmodified source font (required by --check)")
    parser.add_argument("--opencc", default="opencc", help="the opencc command (default: opencc)")
    parser.add_argument("--config", default="s2tw", choices=["s2tw", "s2t"],
                        help="s2tw when the recipe sets taiwanVariants (the presets do), else s2t")
    args = parser.parse_args()
    if args.check and not args.source:
        parser.error("--check needs --source")

    os.makedirs(args.out, exist_ok=True)
    lines = test_lines()
    texts = [text for _, _, text in lines]
    with tempfile.TemporaryDirectory() as scratch:
        data = opencc_data_dir(args.opencc)
        phrases = run_opencc(args.opencc, args.config, texts)
        chars = run_opencc(args.opencc, char_level_config(data, args.config == "s2tw", scratch), texts)
        write_expected(os.path.join(args.out, "expected.md"), lines, phrases, chars, args.config)

        write_epub(os.path.join(args.out, "fm-reader-test.epub"), "FM reader test (reader font)", None)
        for font in args.embed:
            stem = os.path.splitext(os.path.basename(font))[0]
            write_epub(os.path.join(args.out, f"fm-reader-test-{stem}.epub"), f"FM reader test ({stem})", font)
        write_txt(os.path.join(args.out, "fm-reader-test.txt"))

        failures = 0
        if args.check:
            failures = write_check(os.path.join(args.out, "check.md"), lines, phrases, chars,
                                   args.check, args.source, scratch)
    for name in sorted(os.listdir(args.out)):
        print(os.path.join(args.out, name))
    if failures:
        print(f"check: {failures} line(s) match neither expectation; see check.md", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
