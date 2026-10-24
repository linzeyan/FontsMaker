#!/usr/bin/env bash
# s2t phrase spike, end to end. Each step logs to $OUT/logs/NN-name.log and
# records its exit code; there is no `set -e`, a failed step is reported in
# the summary at the end instead of silently stopping the run.
#
# Usage: bash spikes/s2t-phrases/run.sh            # every step
#        bash spikes/s2t-phrases/run.sh 06 07      # selected steps (by number)
# Env:   SPIKE_OUT, SPIKE_CACHE, FONTSMAKER_FIXTURES, MAIN_TAG
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${SPIKE_OUT:-/Users/ricky/git/FontsMaker/artifacts/s2t-phrases}"
CACHE="${SPIKE_CACHE:-$HOME/Library/Caches/FontsMaker/spike-s2t-phrases}"
FIX="${FONTSMAKER_FIXTURES:-$HOME/Library/Caches/FontsMaker/fixtures}"
# Feature tag for the main variants; chosen from step 10's compatibility matrix.
MAIN_TAG="${MAIN_TAG:-rlig}"
W="$OUT/work"
LOGS="$OUT/logs"
SRC="$FIX/GuanKiapTsingKhai.ttf"
CLI="$ROOT/.build/release/fontsmaker"
PY=(python3 -I)
mkdir -p "$W" "$LOGS"

declare -a RESULTS=()
selected() {
  [[ ${#SELECTED[@]} -eq 0 ]] && return 0
  local s
  for s in "${SELECTED[@]}"; do [[ "$s" == "$1" ]] && return 0; done
  return 1
}
# run_step <NN> <name> <function>: output to its own log, exit code kept.
run_step() {
  local id="$1" name="$2" fn="$3" log="$LOGS/$1-$2.log" start end code
  selected "$id" || return 0
  start=$(date +%s)
  "$fn" >"$log" 2>&1
  code=$?
  end=$(date +%s)
  RESULTS+=("$id	$name	$code	$((end - start))s	$log")
  printf '%s %-16s exit=%s (%ss)\n' "$id" "$name" "$code" "$((end - start))"
}

# ---------------------------------------------------------------- steps

s_fetch() { bash "$HERE/fetch.sh"; }

s_build_cli() { (cd "$ROOT" && swift build -c release); }

s_dump_opencc() {
  # The regional-phrase dictionary is generated at OpenCC build time (data/
  # CMakeLists.txt); dumping the 1.4.2 bottle's copy gives the exact entries
  # stock s2t/s2tw use. The other dumps prove the bottle matches the pin.
  local share dump d code=0
  share="$(brew --prefix opencc)/share/opencc"
  dump="$W/opencc-dump"
  mkdir -p "$dump"
  opencc --version | head -3
  for d in STPhrases STPhrases_GeneratedFromRegionalPhrases STCharacters TWVariants TWVariantsPhrases \
    CJK_Compatibility_Ideographs; do
    rm -f "$dump/$d.txt"
    opencc_dict -i "$share/$d.ocd2" -o "$dump/$d.txt" -f ocd2 -t text || code=1
  done
  wc -l "$dump"/*.txt
  return $code
}

s_prep() { "${PY[@]}" "$HERE/prep.py" "$CACHE" "$W" "$W/opencc-dump"; }

s_oracle() {
  # Oracle = the real opencc binary: (a) our text-dict configs, (b) the stock
  # ocd2 configs, for every simplified corpus; s2twp only for prior art (-TW).
  local f base code=0 stock
  stock="$(brew --prefix opencc)/share/opencc"
  mkdir -p "$W/oracle"
  for f in "$W"/corpora/*.s.txt; do
    base="$(basename "$f" .s.txt)"
    opencc -c "$W/opencc/s2t.json" --path "$W/opencc/" -i "$f" -o "$W/oracle/$base.s2t.txt" || code=1
    opencc -c "$W/opencc/s2tw.json" --path "$W/opencc/" -i "$f" -o "$W/oracle/$base.s2tw.txt" || code=1
    opencc -c "$stock/s2t.json" -i "$f" -o "$W/oracle/$base.stock-s2t.txt" || code=1
    opencc -c "$stock/s2tw.json" -i "$f" -o "$W/oracle/$base.stock-s2tw.txt" || code=1
    opencc -c "$stock/s2twp.json" -i "$f" -o "$W/oracle/$base.stock-s2twp.txt" || code=1
  done
  "${PY[@]}" "$HERE/oracle_check.py" "$W" || code=1
  return $code
}

s_base_fonts() {
  # Real recipes, same shape as recipes/examples, source pinned by sha256.
  local r="$W/recipes" sha code=0
  mkdir -p "$r" "$W/fonts"
  sha="$(shasum -a 256 "$SRC" | cut -d' ' -f1)"
  write_recipe() { # name family steps-json
    cat >"$r/$1.json" <<EOF
{
  "formatVersion": 1,
  "source": { "file": "$SRC", "sha256": "$sha" },
  "output": { "familyName": "$2", "fileName": "$1.ttf" },
  "steps": $3
}
EOF
  }
  write_recipe char-tw "Spike Char TW" '[{ "op": "s2t", "mode": "single", "taiwanVariants": true }]'
  write_recipe char-s "Spike Char S" '[{ "op": "s2t", "mode": "single", "taiwanVariants": false }]'
  write_recipe char-tw-pv "Spike Char TW PV" \
    '[{ "op": "s2t", "mode": "single", "taiwanVariants": true }, { "op": "pseudoVertical", "punctuation": "centered" }]'
  "$CLI" build "$r/char-tw.json" "$r/char-s.json" "$r/char-tw-pv.json" --out-dir "$W/fonts" || code=1
  ls -l "$W/fonts"
  return $code
}

s_derive_tw() { "${PY[@]}" "$HERE/derive.py" "$W" "$SRC" "$W/fonts/char-tw.ttf" tw char-tw "$MAIN_TAG" R0,R1,R2,R3,NC; }
s_derive_s() { "${PY[@]}" "$HERE/derive.py" "$W" "$SRC" "$W/fonts/char-s.ttf" s char-s "$MAIN_TAG" R1,R2; }

s_compat() { "${PY[@]}" "$HERE/compat.py" "$W" "$SRC" "$OUT/compat"; }

s_ct_build() {
  mkdir -p "$W/bin"
  swiftc -O "$HERE/ct_shape.swift" -o "$W/bin/ct_shape"
}

s_clones() {
  # Alias glyphs for remapped code points, then the same R2 rules in that glyph space.
  "${PY[@]}" "$HERE/clones.py" "$SRC" "$W/fonts/char-tw.ttf" "$W/fonts/char-tw-clones.ttf" \
    "$W/fonts/char-tw-resaved.ttf" &&
    "${PY[@]}" "$HERE/derive.py" "$W" "$SRC" "$W/fonts/char-tw-clones.ttf" tw char-tw-clones "$MAIN_TAG" R2
}

s_prior_art() {
  "${PY[@]}" "$HERE/prior_art.py" "$W" "$SRC" "$OUT/prior-art" \
    "gk-w=$CACHE/guankiap-w/GuanKiapTsingKhai-W.ttf" "gk-tw=$CACHE/guankiap-tw/GuanKiapTsingKhai-TW.ttf"
}

EVAL_FONTS=(char-tw char-tw-R0 char-tw-R1 char-tw-R2 char-tw-R3 char-tw-NC char-s char-s-R1 char-s-R2
  char-tw-clones char-tw-clones-R2 gk-w gk-tw)
s_shape() { "${PY[@]}" "$HERE/shape.py" "$W" "${EVAL_FONTS[@]}"; }

s_evaluate() { "${PY[@]}" "$HERE/evaluate.py" "$W" "$SRC" "$OUT/eval"; }

s_pv() { "${PY[@]}" "$HERE/pv.py" "$W" "$SRC" "$OUT/pv"; }

s_timing() { "${PY[@]}" "$HERE/timing.py" "$W" "$OUT" char-tw char-tw-R1 char-tw-R2 char-tw-clones-R2 gk-w; }

s_summary() { "${PY[@]}" "$HERE/summary.py" "$W" "$OUT"; }

# ---------------------------------------------------------------- main

SELECTED=("$@")
# A full run starts from empty logs, so a log can't outlive a renamed step.
[[ ${#SELECTED[@]} -eq 0 ]] && rm -f "$LOGS"/*.log
run_step 01 fetch s_fetch
run_step 02 build-cli s_build_cli
run_step 03 dump-opencc s_dump_opencc
run_step 04 prep s_prep
run_step 05 oracle s_oracle
run_step 06 base-fonts s_base_fonts
run_step 07 derive-tw s_derive_tw
run_step 08 derive-s s_derive_s
run_step 09 ct-build s_ct_build
run_step 10 compat s_compat
run_step 11 clones s_clones
run_step 12 prior-art s_prior_art
run_step 13 shape s_shape
run_step 14 evaluate s_evaluate
run_step 15 pv s_pv
run_step 16 timing s_timing
run_step 17 summary s_summary

echo
echo "step	name	exit	time	log"
for line in "${RESULTS[@]}"; do echo "$line"; done
failed=0
for line in "${RESULTS[@]}"; do
  [[ "$(echo "$line" | cut -f3)" != 0 ]] && failed=1
done
exit $failed
