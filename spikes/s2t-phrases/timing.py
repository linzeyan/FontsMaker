"""Question 5: shaping time with and without the phrase lookups.

Usage: python3 -I timing.py <work> <out dir> <font name>...

HarfBuzz: hb-shape over the long text with -n 1 and -n 21, best of 5 runs
each; (t21 − t1) / 20 is one shaping pass without process start and font
load, t1 − that pass is start + load. CoreText: ct_shape --time 5 (best pass).
Other processes on the machine can only make runs slower, so minima are used.
"""

import json
import os
import subprocess
import sys
import time

work, out = sys.argv[1:3]
names = sys.argv[3:]
text = os.path.join(work, "corpora", "long.timing.txt")
chars = sum(len(line.rstrip("\n")) for line in open(text, encoding="utf-8"))


def hb(font, n):
    best = float("inf")
    for _ in range(5):
        start = time.perf_counter()
        subprocess.run(["hb-shape", "--font-file", font, "--text-file", text, "--language=zh-Hans",
                        f"--num-iterations={n}", "--output-format=json", "--no-glyph-names"],
                       stdout=subprocess.DEVNULL, check=True)
        best = min(best, time.perf_counter() - start)
    return best


report = {"chars": chars, "fonts": {}}
for name in names:
    font = os.path.join(work, "fonts", name + ".ttf")
    t1 = hb(font, 1)
    t21 = hb(font, 21)
    per_pass = (t21 - t1) / 20
    ct = subprocess.run([os.path.join(work, "bin", "ct_shape"), font, text, "/dev/null", "--time", "5"],
                        capture_output=True, text=True, check=True)
    report["fonts"][name] = {
        "hb_run_1_s": round(t1, 4),
        "hb_run_21_s": round(t21, 4),
        "hb_per_pass_s": round(per_pass, 4),
        "hb_start_and_load_s": round(t1 - per_pass, 4),
        "hb_us_per_char": round(per_pass / chars * 1e6, 3),
        "ct_per_pass_s": float(ct.stdout.strip()),
    }
    print(name, json.dumps(report["fonts"][name]))

with open(os.path.join(out, "timing.json"), "w") as stream:
    json.dump(report, stream, indent=1)
