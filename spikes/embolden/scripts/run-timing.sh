#!/usr/bin/env bash
# Phase 0 engine timing (extract + stroke + union only, no metrics).
# Steps run sequentially so timing runs never compete with each other; run it
# on an otherwise idle machine. No `set -e`: each step records its exit code.
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(dirname "$HERE")"
FIX="$HOME/Library/Caches/FontsMaker/fixtures"
OUT="${OUT:-$HOME/git/FontsMaker/artifacts/phase0}"
BIN="$PKG/.build/release/embolden-spike"
SRC="$FIX/GuanKiapTsingKhai.ttf"
LXR="$FIX/LXGWWenKaiTC-Regular.ttf"
mkdir -p "$OUT/logs" "$OUT/csv"
STATUS="$OUT/logs/timing-status.txt"
: >"$STATUS"

step() {
  local name="$1"; shift
  local t0=$SECONDS
  "$@" >"$OUT/logs/$name.log" 2>&1
  local code=$?
  printf '%-36s exit=%-3s %4ss\n' "$name" "$code" "$((SECONDS - t0))" | tee -a "$STATUS"
}

for f in "$SRC" "$LXR"; do
  [ -f "$f" ] || { echo "missing fixture $f — run scripts/fetch-fixtures.sh" | tee -a "$STATUS"; exit 1; }
done

step 01-build swift build -c release --package-path "$PKG"
step 02-machine bash -c 'sysctl machdep.cpu.brand_string hw.ncpu hw.perflevel0.name hw.perflevel0.physicalcpu hw.perflevel1.name hw.perflevel1.physicalcpu hw.memsize; sw_vers; swift --version'
# Load average before/after: other builds on the machine inflate every number.
step 03-load-before uptime

for v in "miter 4 miter4" "round 4 round"; do
  set -- $v
  # .userInteractive lands on the top-tier cores; .background on the lower tier.
  step "20-timing-guan-$3-single-P" "$BIN" timing --font "$SRC" --join "$1" --miter-limit "$2" --mode single --out "$OUT/csv/timing-guan-$3-single.csv"
  step "21-timing-guan-$3-single-E" "$BIN" timing --font "$SRC" --join "$1" --miter-limit "$2" --mode background --stride 5
  step "22-timing-guan-$3-parallel" "$BIN" timing --font "$SRC" --join "$1" --miter-limit "$2" --mode parallel --repeat 3
done
step 23-timing-guan-miter4-2threads "$BIN" timing --font "$SRC" --join miter --miter-limit 4 --mode parallel --threads 2 --repeat 1
step 24-timing-guan-miter4-6threads "$BIN" timing --font "$SRC" --join miter --miter-limit 4 --mode parallel --threads 6 --repeat 1

for v in "miter 4 miter4" "round 4 round"; do
  set -- $v
  step "31-timing-lxgw-$3-single-P" "$BIN" timing --font "$LXR" --join "$1" --miter-limit "$2" --mode single --out "$OUT/csv/timing-lxgw-$3-single.csv"
  step "32-timing-lxgw-$3-parallel" "$BIN" timing --font "$LXR" --join "$1" --miter-limit "$2" --mode parallel --repeat 3
done

step 39-load-after uptime

echo "---- summary ($STATUS)"
cat "$STATUS"
