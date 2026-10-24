"""Regenerates OpenCC's STPhrases_GeneratedFromRegionalPhrases.txt.

Usage: python3 -I opencc_regional_phrases.py SOURCES WORK OUTPUT

OpenCC does not ship this dictionary in its repository: data/CMakeLists.txt
builds it, and s2t/s2tw use it next to STPhrases. This follows that rule at
the commit the bundled dictionaries come from (025f371), step by step:

1. TSCharactersExt.txt = the mapping after every "# @tofu-risk:" line of
   TSCharacters.txt, minus the key itself (scripts/extract_tofu_risk.py);
2. CJK_Compatibility_Ideographs, TSCharacters, TSCharactersExt and TSPhrases
   compiled to .ocd2 with opencc_dict, t2s.json next to them;
3. the keys of HKPhrases.txt, then TWPhrases.txt, converted to simplified with
   `opencc -c t2s.json --include-tofu-risk-dictionaries`; projections shorter
   than three characters are skipped, a projection shared by different keys is
   an error, each projection maps to its first key, sorted by projection
   (scripts/generate_st_phrases_from_regional_phrases.py without --append-to).

SOURCES holds the pinned upstream files under their own names; the upstream
scripts are re-implemented here rather than run, so nothing downloaded is
executed. `opencc` and `opencc_dict` are the Homebrew 1.4.2 tools. The output
is byte-for-byte what the upstream generator writes.
"""

import os
import shutil
import subprocess
import sys

TOFU_RISK_PREFIX = "# @tofu-risk:"
OUTPUT_NAME = "STPhrases_GeneratedFromRegionalPhrases.txt"


def entries(path):
    """common.Dict().iter: skip comments and blank lines, split at the first tab."""
    with open(path, encoding="utf-8") as stream:
        for line in stream:
            if line.startswith("#") or not line.strip():
                continue
            key, value = line.rstrip("\r\n").split("\t", 1)
            yield key, value.split(" ")


def extract_tofu_risk(source, target):
    with open(source, encoding="utf-8") as stream:
        lines = stream.readlines()
    extracted = []
    for index, line in enumerate(lines):
        if not line.startswith(TOFU_RISK_PREFIX):
            continue
        if index + 1 >= len(lines):
            sys.exit(f"missing mapping after {TOFU_RISK_PREFIX} at line {index + 1}")
        mapping = lines[index + 1]
        if not mapping.strip() or mapping.startswith("#"):
            sys.exit(f"expected mapping after {TOFU_RISK_PREFIX} at line {index + 1}")
        key, values_text = mapping.rstrip("\n").split("\t", 1)
        values = values_text.split()
        if values and values[0] == key:
            values = values[1:]
        if not values:
            sys.exit(f"expected extension mapping after {TOFU_RISK_PREFIX} at line {index + 1}")
        extracted.append(f"{key}\t{' '.join(values)}\n")
    with open(target, "w", encoding="utf-8", newline="\n") as stream:
        stream.writelines(extracted)


def run(command, **kwargs):
    result = subprocess.run(command, capture_output=True, encoding="utf-8", **kwargs)
    if result.returncode != 0:
        sys.exit(f"{' '.join(command)} failed ({result.returncode}): {result.stderr}")
    return result.stdout


def main():
    sources, work, output = sys.argv[1:4]
    os.makedirs(work, exist_ok=True)
    extract_tofu_risk(os.path.join(sources, "TSCharacters.txt"), os.path.join(work, "TSCharactersExt.txt"))
    for name in ("CJK_Compatibility_Ideographs", "TSCharacters", "TSPhrases"):
        shutil.copyfile(os.path.join(sources, name + ".txt"), os.path.join(work, name + ".txt"))
    for name in ("CJK_Compatibility_Ideographs", "TSCharacters", "TSCharactersExt", "TSPhrases"):
        run(["opencc_dict", "--input", os.path.join(work, name + ".txt"), "--output",
             os.path.join(work, name + ".ocd2"), "--from", "text", "--to", "ocd2"])
    # OpenCC looks for dictionaries in the config's directory first, so these
    # .ocd2 files are used, not the copies installed with the tool.
    shutil.copyfile(os.path.join(sources, "t2s.json"), os.path.join(work, "t2s.json"))

    collisions = {}
    inputs = ["HKPhrases.txt", "TWPhrases.txt"]
    for name in inputs:
        keys = [key for key, _ in entries(os.path.join(sources, name))]
        converted = run(
            ["opencc", "-c", os.path.join(work, "t2s.json"), "--path", work, "--include-tofu-risk-dictionaries"],
            input="\n".join(keys) + "\n",
        ).splitlines()
        if len(converted) != len(keys):
            sys.exit(f"{name}: converted {len(converted)} keys, expected {len(keys)}")
        for projection, key in zip(converted, keys):
            # Upstream: short regional keys could split longer simplified words
            # before STPhrases gets a chance to match them.
            if len(projection) < 3:
                continue
            collisions.setdefault(projection, []).append(key)
    conflicts = {key: values for key, values in collisions.items() if len(set(values)) > 1}
    if conflicts:
        sys.exit("conflicting regional phrase projections: "
                 + "; ".join(f"{k}: {' '.join(v)}" for k, v in sorted(conflicts.items())))

    with open(output, "w", encoding="utf-8", newline="\n") as stream:
        stream.write("# Open Chinese Convert (OpenCC) Dictionary\n")
        stream.write(f"# File: {OUTPUT_NAME}\n")
        stream.write("# Format: key\tvalue(s) (values separated by spaces)\n")
        stream.write("# License: Apache-2.0 (see LICENSE)\n")
        stream.write("# Source: generated from " + ", ".join(inputs) + " keys via t2s.json\n")
        stream.write("# Used in configs: s2hkp.json, s2twp.json\n")
        stream.write("#\n")
        stream.write("# This generated ST phrase dictionary preserves Simplified-input spans\n")
        stream.write("# before applying regional phrase vocabulary.\n")
        stream.write("\n")
        for projection in sorted(collisions):
            stream.write(f"{projection}\t{collisions[projection][0]}\n")
    print(f"{OUTPUT_NAME}: {len(collisions)} entries -> {output}")


if __name__ == "__main__":
    main()
