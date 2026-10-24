"""Cross-checks the oracle before anything is measured against it.

Usage: python3 -I oracle_check.py <work>

1. text-dict configs vs stock ocd2 configs: must agree, or the oracle is not
   "OpenCC 1.4.2 s2t/s2tw";
2. OpenCC's own expected outputs vs the oracle (test cases);
3. the Python emulation in model.py (used to derive rules) vs the oracle: a
   difference would mean the rules encode the wrong matching semantics.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model  # noqa: E402

work = sys.argv[1]
odir = os.path.join(work, "oracle")
cdir = os.path.join(work, "corpora")
report = {"stock_vs_text": {}, "emulator_vs_oracle": {}, "testcases": {}}
ok = True
emulators = {cfg: model.opencc_from_dir(os.path.join(work, "opencc"), taiwan=(cfg == "s2tw")) for cfg in ("s2t", "s2tw")}

for corpus in sorted(f[: -len(".s.txt")] for f in os.listdir(cdir) if f.endswith(".s.txt")):
    inputs = model.read_lines(os.path.join(cdir, corpus + ".s.txt"))
    for cfg in ("s2t", "s2tw"):
        ours = model.read_lines(os.path.join(odir, f"{corpus}.{cfg}.txt"))
        stock = model.read_lines(os.path.join(odir, f"{corpus}.stock-{cfg}.txt"))
        diff = [i for i, (a, b) in enumerate(zip(ours, stock)) if a != b]
        report["stock_vs_text"][f"{corpus}.{cfg}"] = {"lines": len(ours), "differing": len(diff), "length_ok": len(ours) == len(stock) == len(inputs)}
        ok &= not diff and len(ours) == len(stock) == len(inputs)
        emu = [emulators[cfg].convert(line) for line in inputs]
        ediff = [i for i, (a, b) in enumerate(zip(emu, ours)) if a != b]
        report["emulator_vs_oracle"][f"{corpus}.{cfg}"] = {
            "differing": len(ediff),
            "examples": [{"input": inputs[i], "oracle": ours[i], "emulator": emu[i]} for i in ediff[:5]],
        }
        ok &= not ediff
        lengths = sum(1 for a, b in zip(inputs, ours) if len(a) != len(b))
        report["stock_vs_text"][f"{corpus}.{cfg}"]["length_changing_lines"] = lengths

for cfg in ("s2t", "s2tw"):
    ids = model.read_lines(os.path.join(cdir, f"testcases-{cfg}.ids.txt"))
    expected = model.read_lines(os.path.join(cdir, f"testcases-{cfg}.expected.txt"))
    got = model.read_lines(os.path.join(odir, f"testcases-{cfg}.{cfg}.txt"))
    bad = [{"id": i, "expected": e, "oracle": g} for i, e, g in zip(ids, expected, got) if e != g]
    report["testcases"][cfg] = {"cases": len(ids), "oracle_differs_from_expected": len(bad), "examples": bad}

report["ok"] = bool(ok)
model.dump_json(os.path.join(work, "oracle-check.json"), report)
print(json.dumps(report, ensure_ascii=False, indent=1))
sys.exit(0 if ok else 1)
