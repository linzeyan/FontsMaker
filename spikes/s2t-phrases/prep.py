"""Prepares oracle configs and corpora.

Usage: python3 -I prep.py <cache dir> <work dir> <dumped ocd2 dir>

- work/opencc/: the pinned .txt dictionaries plus the regional-phrase dict
  dumped from the 1.4.2 build, and the pinned s2t/s2tw configs rewritten to
  `text` dictionaries, so the oracle and the rule generator read the same data.
- work/corpora/*.s.txt (simplified) and *.t.txt (traditional): one sentence
  per line; phrases never span 。！？； (checked), so splitting there cannot
  change any conversion.
"""

import json
import os
import re
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model  # noqa: E402

cache, work, dumped = sys.argv[1:4]
opencc_src = os.path.join(cache, "opencc-025f371")
odir = os.path.join(work, "opencc")
cdir = os.path.join(work, "corpora")
os.makedirs(odir, exist_ok=True)
os.makedirs(cdir, exist_ok=True)
report = {}

# ---- dictionaries and configs
pinned = [
    "STPhrases.txt",
    "STCharacters.txt",
    "TWVariants.txt",
    "TWVariantsPhrases.txt",
    "CJK_Compatibility_Ideographs.txt",
]
for name in pinned:
    shutil.copyfile(os.path.join(opencc_src, "data_dictionary_" + name), os.path.join(odir, name))
shutil.copyfile(
    os.path.join(dumped, "STPhrases_GeneratedFromRegionalPhrases.txt"),
    os.path.join(odir, "STPhrases_GeneratedFromRegionalPhrases.txt"),
)

# The Homebrew bottle must carry the same data as the pinned commit, or the
# stock `opencc` and our text-dict oracle would disagree for a dull reason.
same = {}
for name in pinned:
    stem = name[:-4]
    a = model.load_dict(os.path.join(odir, name))
    b = model.load_dict(os.path.join(dumped, stem + ".txt"))
    same[stem] = a == b
report["homebrew_dicts_equal_pinned"] = same
report["generated_regional_phrases"] = len(model.load_dict(os.path.join(odir, "STPhrases_GeneratedFromRegionalPhrases.txt")))


def textify(node):
    if isinstance(node, dict):
        out = {}
        for k, v in node.items():
            if k == "type" and v == "ocd2":
                out[k] = "text"
            elif k == "file" and isinstance(v, str) and v.endswith(".ocd2"):
                out[k] = v[:-5] + ".txt"
            else:
                out[k] = textify(v)
        return out
    if isinstance(node, list):
        return [textify(x) for x in node]
    return node


for config in ("s2t", "s2tw"):
    with open(os.path.join(opencc_src, f"data_config_{config}.json"), encoding="utf-8") as stream:
        upstream = json.load(stream)
    with open(os.path.join(odir, f"{config}.json"), "w", encoding="utf-8") as stream:
        json.dump(textify(upstream), stream, ensure_ascii=False, indent=2)

# ---- corpora
phrases = model.load_dict(os.path.join(odir, "STPhrases.txt"))
phrases.update(model.load_dict(os.path.join(odir, "STPhrases_GeneratedFromRegionalPhrases.txt")))
breakers = set("。！？!?；;\n")
report["phrase_keys_containing_sentence_breaks"] = sum(any(c in breakers for c in k) for k in phrases)


def sentences(paragraphs):
    out = []
    for paragraph in paragraphs:
        paragraph = paragraph.strip()  # str.strip also drops U+3000 indents
        for piece in model.SENTENCE_END.split(paragraph):
            piece = piece.strip()
            if piece and model.has_han(piece):
                out.append(piece)
    return out


corpora = {}
corpora["sentence.s"] = ["这个国家的发展为后来里程碑"]

raw = open(os.path.join(opencc_src, "test_testcases_testcases.json"), encoding="utf-8").read()
cases = json.loads(re.sub(r",(\s*[}\]])", r"\1", raw))["cases"]
for config in ("s2t", "s2tw"):
    selected = [c for c in cases if config in c.get("expected", {})]
    corpora[f"testcases-{config}.s"] = [c["input"] for c in selected]
    corpora[f"testcases-{config}.expected"] = [c["expected"][config] for c in selected]
    corpora[f"testcases-{config}.ids"] = [c["id"] for c in selected]
# Traditional side: the expected (.ans) outputs of every s2t/s2tw case.
seen = []
for c in cases:
    for config in ("s2t", "s2tw"):
        value = c.get("expected", {}).get(config)
        if value and value not in seen:
            seen.append(value)
corpora["testcases-ans.t"] = seen

with open(os.path.join(cache, "nahan-simplified", "nahan.txt"), encoding="utf-8") as stream:
    corpora["nahan.s"] = sentences(stream.read().split("\n"))

with open(os.path.join(cache, "gutenberg-27166", "pg27166.txt"), encoding="utf-8") as stream:
    text = stream.read()
body = text.split("*** START OF THE PROJECT GUTENBERG EBOOK", 1)[1].split("***", 1)[1]
body = body.split("*** END OF THE PROJECT GUTENBERG EBOOK", 1)[0]
corpora["nahan-gutenberg.t"] = sentences(body.split("\n"))

gsd = []
for part in ("train", "dev", "test"):
    path = os.path.join(cache, "ud-chinese-gsd", f"zh_gsd-ud-{part}.conllu")
    if os.path.exists(path):
        with open(path, encoding="utf-8") as stream:
            gsd += [line[len("# text = ") :].strip() for line in stream if line.startswith("# text = ")]
    else:
        report[f"missing_gsd_{part}"] = path
corpora["ud-gsd.t"] = [line for line in gsd if model.has_han(line)]

for name in ("pku", "msr"):
    path = os.path.join(cache, "sighan2005", "extracted", f"{name}_test.utf8")
    if os.path.exists(path):
        with open(path, encoding="utf-8-sig") as stream:
            corpora[f"{name}.s"] = [line.strip() for line in stream if model.has_han(line)]
    else:
        report[f"missing_{name}"] = path

sizes = {}
for name, lines in corpora.items():
    model.write_lines(os.path.join(cdir, name + ".txt"), lines)
    sizes[name] = {"lines": len(lines), "chars": sum(len(x) for x in lines)}
report["corpora"] = sizes

# Long text for timing: every simplified natural sentence once.
long_lines = []
for name in ("nahan.s", "pku.s", "msr.s"):
    long_lines += corpora.get(name, [])
model.write_lines(os.path.join(cdir, "long.timing.txt"), long_lines)
report["timing_text_chars"] = sum(len(x) for x in long_lines)

model.dump_json(os.path.join(work, "prep.json"), report)
print(json.dumps(report, ensure_ascii=False, indent=1))
