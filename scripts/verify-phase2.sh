#!/usr/bin/env bash
# Phase 2 acceptance run (plan.md): build and tests (macOS + iOS Simulator);
# every example recipe through the release CLI, twice, for byte determinism;
# fontTools and CoreText checks of every output; the BailuKai-like recipe
# against BailuKai Medium; s2t against GuanKiapTsingKhai-T; pseudo-vertical
# (outlines and line metrics) against GuanKiapTsingKhai-90; rotated-view contact sheets; the full-build
# time of the combined recipe.
#
# Every step logs to $OUT/logs/NN-name.log. No `set -e`: a failing step is
# recorded and the run continues, so one summary shows everything. The
# summary is printed at the end and written to $OUT/summary.txt.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Artifacts go to the main checkout (gitignored), shared by all worktrees.
MAIN="$(cd "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
OUT="${FONTSMAKER_ARTIFACTS:-$MAIN/artifacts/phase2}"
export FONTSMAKER_FIXTURES="${FONTSMAKER_FIXTURES:-$HOME/Library/Caches/FontsMaker/fixtures}"
LOGS="$OUT/logs"
FONTS="$OUT/fonts"
WORK="$OUT/work"
LISTS="$OUT/lists"
SHEETS="$OUT/sheets"
BIN="$OUT/bin"
rm -rf "$LOGS" "$FONTS" "$WORK" "$LISTS" "$SHEETS" "$BIN"
mkdir -p "$LOGS" "$FONTS/again" "$FONTS/compare" "$WORK/compare" "$LISTS" "$SHEETS" "$BIN"
cd "$REPO" || exit 1

GUAN="$FONTSMAKER_FIXTURES/GuanKiapTsingKhai.ttf"
GUAN90="$FONTSMAKER_FIXTURES/GuanKiapTsingKhai-90.ttf"
GUANT="$FONTSMAKER_FIXTURES/GuanKiapTsingKhai-T.ttf"
BAILU="$FONTSMAKER_FIXTURES/BailuKai-Medium.ttf"
BAILU90="$FONTSMAKER_FIXTURES/BailuKai-Medium-90.ttf"
LXGW_MEDIUM="$FONTSMAKER_FIXTURES/LXGWWenKaiTC-Medium.ttf"
GUAN_SHA=758632243c499e431fd0c847f5e8c431acf59a9b41a26237a819466139994d38
OPENCC=Sources/FontsMakerKit/Resources/OpenCC
# Outputs of recipes/examples, named by their recipes.
BAILU_LIKE=ExampleKai-Medium
COMBINED=ExampleTradKaiV-Medium
COMBINED_RECIPE=guankiap-embolden-s2t-pseudo-vertical.json
# Characters BailuKai replaced by hand with LXGW WenKai Medium (Phase 0).
HAND_FIXED="傳導帳熱繁聯育鬢"
REPRESENTATIVE="永國的書讀體藝靈鷹鬱齉龘驫爨籲囊響鑿蠻廳鸞我說愛風心水AaGgQ&@0。「」"
# Reserved Font Names the GuanKiapTsingKhai README declares outside the font file.
FORBIDDEN=(--forbid 原俠 --forbid 原侠 --forbid GuanKiap --forbid TsingKhai)

names=()
codes=()
# run NAME COMMAND...: log the command's output and record its exit code.
run() {
  local name=$1
  shift
  local number
  number=$(printf '%02d' $((${#names[@]} + 1)))
  local log="$LOGS/$number-$name.log"
  echo "\$ $*" >"$log"
  "$@" >>"$log" 2>&1
  local code=$?
  names+=("$number-$name")
  codes+=("$code")
  if ((code == 0)); then
    printf '%-44s PASS\n' "$number-$name"
  else
    printf '%-44s FAIL (exit %d)  %s\n' "$number-$name" "$code" "$log"
  fi
}

fixtures_reproducible() {
  local tmp
  tmp=$(mktemp -d)
  python3 -I scripts/make-test-fonts.py "$tmp" || return 1
  diff -r Tests/FontsMakerKitTests/Fixtures "$tmp" && echo "committed fixtures equal a fresh generation"
  local code=$?
  rm -rf "$tmp"
  return $code
}

# Fails when any test is skipped: a skipped test is not a passing test.
swift_test() {
  local tmp
  tmp=$(mktemp)
  swift test >"$tmp" 2>&1
  local code=$?
  cat "$tmp"
  if grep -qiE 'skipped' "$tmp"; then
    echo "VERIFY: skipped tests found"
    code=1
  fi
  if ! grep -qE 'Test run with [0-9]+ tests? in [0-9]+ suites? passed' "$tmp"; then
    echo "VERIFY: no passing Swift Testing summary line"
    code=1
  fi
  rm -f "$tmp"
  return $code
}

# Bundle.module resources must be inside the iOS framework bundle too.
ios_build() {
  xcodebuild -scheme FontsMakerKit -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$REPO/.build/xcode-ios" build || return 1
  local bundle="$REPO/.build/xcode-ios/Build/Products/Debug-iphonesimulator/FontsMaker_FontsMakerKit.bundle"
  echo "resource bundle: $bundle"
  [[ -d "$bundle" ]] || return 1
  local file
  for file in OpenCC/STCharacters.txt OpenCC/TWVariants.txt OpenCC/LICENSE Unicode/VerticalOrientation.txt \
    Unicode/LICENSE.txt; do
    if [[ -f "$bundle/$file" ]]; then echo "ok  $file"; else echo "missing $file"; return 1; fi
  done
}

# Second run into another directory: the same files, every byte equal
# (fonts, risk CSVs and risk sheet PNGs).
same_bytes() {
  local status=0 file name a b first=() second=()
  for file in "$FONTS"/*.*; do first+=("$(basename "$file")"); done
  for file in "$FONTS"/again/*.*; do second+=("$(basename "$file")"); done
  if [[ "${first[*]}" != "${second[*]}" ]]; then
    echo "the two runs wrote different files: ${first[*]} / ${second[*]}"
    status=1
  fi
  for file in "$FONTS"/*.*; do
    name=$(basename "$file")
    a=$(shasum -a 256 "$file" | cut -d' ' -f1)
    b=$(shasum -a 256 "$FONTS/again/$name" 2>/dev/null | cut -d' ' -f1)
    echo "$a  $b  $name"
    [[ -n "$a" && "$a" == "$b" ]] || status=1
  done
  return $status
}

# Unknown license: refused without --i-have-rights, built with it.
license_gate_cli() {
  local dir="$WORK/license"
  mkdir -p "$dir"
  cp Tests/FontsMakerKitTests/Fixtures/minimal.ttf "$dir/minimal.ttf"
  local sha
  sha=$(shasum -a 256 "$dir/minimal.ttf" | cut -d' ' -f1)
  printf '{"formatVersion": 1, "source": {"file": "minimal.ttf", "sha256": "%s"}, "output": {"familyName": "Gate Test"}}\n' \
    "$sha" >"$dir/gate.json"
  if "$CLI" build "$dir/gate.json" --out-dir "$dir"; then echo "built without --i-have-rights"; return 1; fi
  "$CLI" build "$dir/gate.json" --out-dir "$dir" --i-have-rights || return 1
  [[ -f "$dir/GateTest-Regular.ttf" ]]
}

# A comparison recipe: same source, one step list, a fixed output file name.
compare_recipe() {
  local name=$1 steps=$2
  cat >"$WORK/compare/$name.json" <<EOF
{"formatVersion": 1,
 "source": {"file": "../GuanKiapTsingKhai.ttf", "sha256": "$GUAN_SHA"},
 "output": {"familyName": "Compare $name", "fileName": "$name.ttf"},
 "steps": $steps}
EOF
}

# The CSV lists every emboldened glyph; the PNG pages hold grades A and B,
# 120 glyphs a page (EmboldenReport.riskSheet's default).
risk_outputs() {
  local stem status=0
  for stem in "$@"; do
    python3 -I - "$FONTS" "$stem" <<'EOF' || status=1
import csv, math, os, sys
fonts, stem = sys.argv[1:3]
rows = list(csv.DictReader(open(os.path.join(fonts, f"{stem}.embolden.csv"), encoding="utf-8")))
review = sum(1 for r in rows if r["grade"] in ("A", "B"))
pages = sorted(f for f in os.listdir(fonts) if f.startswith(f"{stem}.risk-p") and f.endswith(".png"))
expected = [f"{stem}.risk-p{n}.png" for n in range(1, math.ceil(review / 120) + 1)]
ok = bool(rows) and pages == expected
print(f"{'PASS' if ok else 'FAIL'}  {stem}: {len(rows)} CSV rows, {review} glyphs graded A/B, pages {pages}")
sys.exit(0 if ok else 1)
EOF
  done
  return $status
}

vertical_compare() {
  local label=$1 ours=$2
  "$TOOLS" iou "$ours" "$GUAN90" "$WORK/iou-$label.tsv" || return 1
  python3 -I scripts/verify_phase2r.py vertical "$GUAN" "$ours" "$GUAN90" \
    --orientation Sources/FontsMakerKit/Resources/Unicode/VerticalOrientation.txt --iou "$WORK/iou-$label.tsv" \
    --label "$label"
}

# Design §5.3 欄距: turned, the line height is the column pitch, so every
# pseudo-vertical output must carry GuanKiapTsingKhai-90's line metrics.
# Typo metrics are compared too: they place the rotation centre and must not move.
line_metrics() {
  python3 -I - "$GUAN" "$GUAN90" "$@" <<'EOF'
import os, sys
from fontTools.ttLib import TTFont
FIELDS = [("hhea", "ascent"), ("hhea", "descent"), ("hhea", "lineGap"), ("OS/2", "usWinAscent"),
          ("OS/2", "usWinDescent"), ("OS/2", "sTypoAscender"), ("OS/2", "sTypoDescender"), ("OS/2", "sTypoLineGap")]
def metrics(path):
    font = TTFont(path, lazy=True)
    return {f"{table}.{field}": getattr(font[table], field) for table, field in FIELDS}
source, reference = metrics(sys.argv[1]), metrics(sys.argv[2])
print(f"INFO  source GuanKiapTsingKhai: {source}")
print(f"INFO  reference GuanKiapTsingKhai-90: {reference}")
failed = 0
for path in sys.argv[3:]:
    ours = metrics(path)
    diff = {key: (value, reference[key]) for key, value in ours.items() if value != reference[key]}
    failed += bool(diff)
    detail = f"  (ours, reference) {diff}" if diff else f"  {ours}"
    print(f"{'FAIL' if diff else 'PASS'}  {os.path.basename(path)} line metrics equal GuanKiapTsingKhai-90{detail}")
print(f"RESULT line metrics: {len(sys.argv) - 3 - failed}/{len(sys.argv) - 3} pseudo-vertical outputs equal "
      f"GuanKiapTsingKhai-90 (hhea {reference['hhea.ascent']}/{reference['hhea.descent']}/{reference['hhea.lineGap']}, "
      f"win {reference['OS/2.usWinAscent']}/{reference['OS/2.usWinDescent']}; source hhea descent "
      f"{source['hhea.descent']}, usWinDescent {source['OS/2.usWinDescent']})")
sys.exit(1 if failed or len(sys.argv) < 4 else 0)
EOF
}

final_checks() {
  "$SPIKE" final --final "$FONTS/$BAILU_LIKE.ttf" --src "$GUAN" --ref "$BAILU" --weight 12 \
    --out "$WORK/final.csv" || return 1
  python3 -I scripts/embolden_final_summary.py "$WORK/final.csv" "$FONTS/$BAILU_LIKE.embolden.csv" \
    "$LISTS/bailu-injected-from-lxgw.tsv" "$LISTS"
}

# Wall time of `fontsmaker build` on the combined recipe, three runs; the
# machine may be shared, so the load is logged too.
timing() {
  local attempt code
  echo "load before: $(uptime)"
  for attempt in 1 2 3; do
    rm -rf "$WORK/timing"
    /usr/bin/time -p "$CLI" build "$WORK/$COMBINED_RECIPE" --out-dir "$WORK/timing" >"$WORK/timing.out" 2>"$WORK/timing.err"
    code=$?
    if ((code != 0)); then
      cat "$WORK/timing.out" "$WORK/timing.err"
      return "$code"
    fi
    echo "RESULT timing $COMBINED_RECIPE run $attempt: $(awk '/^(real|user|sys)/ { printf "%s %ss ", $1, $2 }' "$WORK/timing.err")"
  done
  echo "load after: $(uptime)"
}

run fetch-fixtures bash scripts/fetch-fixtures.sh
run fixtures-reproducible fixtures_reproducible
run swift-build swift build
run swift-test swift_test
run release-build swift build -c release --product fontsmaker
run ios-simulator-build ios_build
run tools-build swiftc -O -o "$BIN/phase2r_tools" scripts/phase2r_tools.swift
run spike-build swift build -c release --package-path spikes/embolden
CLI="$(swift build -c release --show-bin-path)/fontsmaker"
TOOLS="$BIN/phase2r_tools"
SPIKE="$REPO/spikes/embolden/.build/release/embolden-spike"

# The example recipes name their source relative to themselves, so they run
# from a directory that holds a link to the cached font.
ln -s "$GUAN" "$WORK/GuanKiapTsingKhai.ttf"
cp recipes/examples/*.json "$WORK/"
EXAMPLES=("$WORK"/guankiap-*.json)

compare_recipe s2t-single '[{"op": "s2t", "mode": "single"}]'
compare_recipe s2t-single-tw '[{"op": "s2t", "mode": "single", "taiwanVariants": true}]'
compare_recipe s2t-skip '[{"op": "s2t", "mode": "skipAmbiguous"}]'
compare_recipe s2t-skip-tw '[{"op": "s2t", "mode": "skipAmbiguous", "taiwanVariants": true}]'
compare_recipe pv-vertical-forms '[{"op": "pseudoVertical", "punctuation": "verticalForms"}]'
# synthetic.ttf has composites and hinting tables, which GuanKiapTsingKhai lacks.
cp Tests/FontsMakerKitTests/Fixtures/synthetic.ttf "$WORK/compare/synthetic.ttf"
cat >"$WORK/compare/synthetic-embolden.json" <<EOF
{"formatVersion": 1,
 "source": {"file": "synthetic.ttf", "sha256": "$(shasum -a 256 "$WORK/compare/synthetic.ttf" | cut -d' ' -f1)"},
 "output": {"familyName": "Compare Embolden", "fileName": "synthetic-embolden.ttf"},
 "steps": [{"op": "embolden", "weight": 12}]}
EOF

run injected-list python3 -I spikes/embolden/scripts/probe_injected.py "$BAILU" "$LXGW_MEDIUM" \
  "$LISTS/bailu-injected-from-lxgw.tsv"
# As if an earlier build had more A/B glyphs: risk-report-and-sheets fails
# unless the build removes this page.
touch "$FONTS/$BAILU_LIKE.risk-p99.png"
run build-examples "$CLI" build "${EXAMPLES[@]}" --out-dir "$FONTS"
run build-examples-again "$CLI" build "${EXAMPLES[@]}" --out-dir "$FONTS/again"
run same-sha256-twice same_bytes
run risk-report-and-sheets risk_outputs "$BAILU_LIKE" "$COMBINED"
run license-gate-cli license_gate_cli
run build-comparisons "$CLI" build "$WORK"/compare/*.json --out-dir "$FONTS/compare"

for font in "$FONTS"/*.ttf; do
  stem=$(basename "$font" .ttf)
  weight=400
  [[ $stem == *-Medium ]] && weight=500
  run "fonttools-$stem" python3 -I scripts/verify_phase2r.py check "$font" --source "$GUAN"
  run "names-$stem" python3 -I scripts/verify_phase2r.py names "$font" --source "$GUAN" "${FORBIDDEN[@]}" \
    --weight-class "$weight"
done
for name in s2t-single s2t-skip pv-vertical-forms synthetic-embolden; do
  src="$GUAN"
  [[ $name == synthetic-* ]] && src="$WORK/compare/synthetic.ttf"
  run "fonttools-$name" python3 -I scripts/verify_phase2r.py check "$FONTS/compare/$name.ttf" --source "$src"
done
run embolden-only-$BAILU_LIKE python3 -I scripts/verify_embolden.py "$GUAN" "$FONTS/$BAILU_LIKE.ttf" --renamed
run embolden-only-synthetic python3 -I scripts/verify_embolden.py "$WORK/compare/synthetic.ttf" \
  "$FONTS/compare/synthetic-embolden.ttf" --renamed
run coretext-load "$TOOLS" load "$FONTS"/*.ttf "$FONTS"/compare/*.ttf

# The BailuKai-like recipe against BailuKai Medium (plan.md Phase 2 acceptance).
run final-font-checks final_checks
run sheet-hand-fixed "$SPIKE" final-sheet --final "$FONTS/$BAILU_LIKE.ttf" --src "$GUAN" --ref "$BAILU" \
  --chars "$HAND_FIXED" --ref-label "BailuKai (= LXGW WenKai TC Medium copy)" \
  --title "The 8 glyphs BailuKai replaced by hand: source | our build | BailuKai" --out "$SHEETS/hand-fixed"
run sheet-representative "$SPIKE" final-sheet --final "$FONTS/$BAILU_LIKE.ttf" --src "$GUAN" --ref "$BAILU" \
  --chars "$REPRESENTATIVE" --groups 4 --cell 150 \
  --title "Representative glyphs: source | our build | BailuKai Medium" --out "$SHEETS/representative"
run sheet-crossings "$SPIKE" crossing-zoom --final "$FONTS/$BAILU_LIKE.ttf" --list "$LISTS/crossings.tsv" \
  --groups 6 --cell 260 --title "Residual crossings after cu2qu + rounding (evenly spaced sample)" \
  --out "$SHEETS/residual-crossings"

# CoreText shapes a simplified sentence with the traditional glyphs of the source.
SIMPLIFIED="汉字简化后，头发与发展都变了。为什么这样？"
run s2t-layout-single "$TOOLS" layout-compare "$FONTS/compare/s2t-single.ttf" "$SIMPLIFIED" "$GUAN" \
  "漢字簡化後，頭發與發展都變了。爲什麼這樣？"
run s2t-layout-tw "$TOOLS" layout-compare "$FONTS/ExampleTradKai-Regular.ttf" "$SIMPLIFIED" "$GUAN" \
  "漢字簡化後，頭發與發展都變了。為什麼這樣？"
run s2t-layout-skip "$TOOLS" layout-compare "$FONTS/compare/s2t-skip.ttf" "$SIMPLIFIED" "$GUAN" \
  "漢字簡化后，頭发與发展都變了。爲什麼這樣？"
for name in s2t-single s2t-single-tw s2t-skip s2t-skip-tw; do
  run "$name-vs-T" python3 -I scripts/verify_phase2r.py s2t "$GUAN" "$FONTS/compare/$name.ttf" "$GUANT" \
    --opencc "$OPENCC" --label "$name"
done

run vertical-centered-vs-90 vertical_compare centered "$FONTS/ExampleKaiV-Regular.ttf"
run vertical-verticalForms-vs-90 vertical_compare verticalForms "$FONTS/compare/pv-vertical-forms.ttf"
run centre-guankiap-90 python3 -I scripts/verify_phase2r.py centre "$GUAN" "$GUAN90"
run centre-bailukai-90 python3 -I scripts/verify_phase2r.py centre "$BAILU" "$BAILU90"
run line-metrics-vs-90 line_metrics "$FONTS/ExampleKaiV-Regular.ttf" "$FONTS/ExampleTradKaiV.ttf" \
  "$FONTS/$COMBINED.ttf" "$FONTS/compare/pv-vertical-forms.ttf"

cat >"$WORK/sample-traditional.txt" <<'EOF'
「天地玄黃，宇宙洪荒。」她說：『日月盈昃（辰宿列張）……』寒來暑往——秋收冬藏；閏餘成歲！律呂調陽？雲騰致雨、露結為霜。カタカナ・ラーメン。FontsMaker 0.1 sets Latin: Kai, 2026.
EOF
cat >"$WORK/sample-simplified.txt" <<'EOF'
「天地玄黄，宇宙洪荒。」她说：『日月盈昃（辰宿列张）……』寒来暑往——秋收冬藏；闰余成岁！律吕调阳？云腾致雨、露结为霜。カタカナ・ラーメン。FontsMaker 0.1 sets Latin: Kai, 2026.
EOF
run contact-sheet-vertical "$TOOLS" sheet "$SHEETS/contact-sheet-vertical.png" "$WORK/sample-traditional.txt" \
  "ours centered=$FONTS/ExampleKaiV-Regular.ttf" "ours verticalForms=$FONTS/compare/pv-vertical-forms.ttf" \
  "GuanKiapTsingKhai-90=$GUAN90" "BailuKai-Medium-90=$BAILU90"
run contact-sheet-combined "$TOOLS" sheet "$SHEETS/contact-sheet-combined.png" "$WORK/sample-traditional.txt" \
  "ours embolden+s2t+vertical=$FONTS/$COMBINED.ttf" "BailuKai-Medium-90=$BAILU90" "GuanKiapTsingKhai-90=$GUAN90"
run contact-sheet-s2t-vertical "$TOOLS" sheet "$SHEETS/contact-sheet-s2t-vertical.png" "$WORK/sample-simplified.txt" \
  "ours s2t+vertical=$FONTS/ExampleTradKaiV.ttf" "ours embolden+s2t+vertical=$FONTS/$COMBINED.ttf" \
  "GuanKiapTsingKhai-90=$GUAN90" "BailuKai-Medium-90=$BAILU90"

run timing timing

{
  echo "Phase 2 verification  $(date '+%Y-%m-%d %H:%M:%S')"
  echo "worktree $REPO @ $(git -C "$REPO" rev-parse --short HEAD)"
  echo
  failed=0
  for i in "${!names[@]}"; do
    if ((codes[i] == 0)); then status=PASS; else status="FAIL (exit ${codes[i]})"; failed=$((failed + 1)); fi
    printf '%-44s %s\n' "${names[i]}" "$status"
  done
  echo
  echo "Build summaries of the example recipes:"
  grep -h -E '^  (embolden|s2t|pseudoVertical|rename) ' "$LOGS"/*-build-examples.log
  echo
  echo "BailuKai-like recipe vs BailuKai Medium:"
  grep -h -E '^(PASS|FAIL|INFO)' "$LOGS"/*-final-font-checks.log
  grep -h -E '^(PASS|FAIL)' "$LOGS"/*-risk-report-and-sheets.log
  echo
  echo "Measurements:"
  grep -h '^RESULT' "$LOGS"/*.log
  echo
  echo "Outputs: $FONTS; sheets: $SHEETS"
  echo "$((${#names[@]} - failed))/${#names[@]} steps passed; logs in $LOGS"
} | tee "$OUT/summary.txt"
grep -q 'steps passed' "$OUT/summary.txt" && ! grep -qE '^[0-9]{2}-.* FAIL' "$OUT/summary.txt"
