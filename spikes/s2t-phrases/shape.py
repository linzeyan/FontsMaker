"""Shapes every corpus with every font under evaluation, with HarfBuzz
(hb-shape) and CoreText (ct_shape), defaults only: no features are forced on,
because the question is what readers do by default.

Usage: python3 -I shape.py <work> <font name>...   (fonts from work/fonts/<name>.ttf)
Output: work/shaped/<font>/<corpus>.<hb|ct>.jsonl, one [[gid, cp index, ax, ay], ...] per line.
"""

import concurrent.futures
import json
import os
import subprocess
import sys

work = sys.argv[1]
names = sys.argv[2:]
cdir = os.path.join(work, "corpora")
ct = os.path.join(work, "bin", "ct_shape")
corpora = sorted(f[:-4] for f in os.listdir(cdir) if f.endswith((".s.txt", ".t.txt")))


def hb_job(font, corpus, out):
    # Simplified text is tagged zh-Hans, traditional zh-Hant, as an EPUB would be.
    lang = "zh-Hans" if corpus.endswith(".s") else "zh-Hant"
    result = subprocess.run(
        ["hb-shape", "--font-file", font, "--text-file", os.path.join(cdir, corpus + ".txt"),
         "--output-format=json", "--no-glyph-names", f"--language={lang}"],
        capture_output=True, text=True, check=True,
    )
    with open(out, "w", encoding="utf-8") as stream:
        for line in result.stdout.splitlines():
            stream.write(json.dumps([[g["g"], g["cl"], g["ax"], g["ay"]] for g in json.loads(line)]) + "\n")


def ct_job(font, corpus, out):
    subprocess.run([ct, font, os.path.join(cdir, corpus + ".txt"), out], capture_output=True, text=True, check=True)


jobs = []
for name in names:
    font = os.path.join(work, "fonts", name + ".ttf")
    odir = os.path.join(work, "shaped", name)
    os.makedirs(odir, exist_ok=True)
    for corpus in corpora:
        jobs.append((hb_job, font, corpus, os.path.join(odir, f"{corpus}.hb.jsonl")))
        jobs.append((ct_job, font, corpus, os.path.join(odir, f"{corpus}.ct.jsonl")))

failed = 0
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    futures = {pool.submit(fn, font, corpus, out): out for fn, font, corpus, out in jobs}
    for future in concurrent.futures.as_completed(futures):
        try:
            future.result()
        except subprocess.CalledProcessError as error:
            failed += 1
            print("FAIL", futures[future], error.stderr[-500:])
print(f"{len(jobs) - failed}/{len(jobs)} shaping jobs ok")
sys.exit(1 if failed else 0)
