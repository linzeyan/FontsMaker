#!/usr/bin/env bash
# Acceptance run for s2t `phrases` (technical design §5.4): build and test the
# package, build phrase fonts from GuanKiapTsingKhai with the release CLI,
# parse them with fontTools, shape OpenCC's own test cases and the spike's
# three natural corpora with HarfBuzz and CoreText against the opencc 1.4.2
# oracle, check pseudoVertical leaves no Han glyph upright, check builds are
# reproducible, and check every recipe without `phrases` still builds
# byte-identical fonts to $BASELINE (below). Also measures size and build time.
#
# Every step logs to $OUT/verify/NN-name.log. No `set -e`: a failing step is
# recorded and the run continues, so one summary shows everything. The
# summary is printed at the end and written to $OUT/verify/summary.txt.
#
# Tools: hb-shape (harfbuzz), opencc and opencc_dict 1.4.2 (Homebrew),
# python3 with fontTools, Xcode's swift/swiftc.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Artifacts go to the main checkout (gitignored), shared by all worktrees.
MAIN="$(cd "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
OUT="${FONTSMAKER_ARTIFACTS:-$MAIN/artifacts/s2t-phrases-prod}"
FIXTURES="${FONTSMAKER_FIXTURES:-$HOME/Library/Caches/FontsMaker/fixtures}"
OPENCC_COMMIT=025f371dc76b598d77384fbdab90c937471844d8
OPENCC="${FONTSMAKER_OPENCC:-$HOME/Library/Caches/FontsMaker/opencc-$OPENCC_COMMIT}"
# The spike's download cache (artifacts/s2t-phrases/downloads.tsv): same URLs
# and sha256 pins, so the natural corpora are byte for byte the spike's.
CORPORA="${FONTSMAKER_CORPORA:-$HOME/Library/Caches/FontsMaker/spike-s2t-phrases}"
# The commit that introduced fontTools' cmap format 4 segmentation (Phase
# 4a). Every build before it has other cmap bytes, so an older baseline
# fails on cmap alone; scripts/verify-phase4a.sh checked that the change
# leaves every other table of these recipes' outputs byte for byte the same.
BASELINE=7127bcb
# Kept between runs: a release build of main takes minutes.
BASELINE_DIR="$OUT/main-$BASELINE"
LOGS="$OUT/verify"
WORK="$LOGS/work"
SRC="$FIXTURES/GuanKiapTsingKhai.ttf"
BUNDLED="$REPO/Sources/FontsMakerKit/Resources/OpenCC"
CLI="$REPO/.build/release/fontsmaker"
BASELINE_CLI="$BASELINE_DIR/.build/release/fontsmaker"
PY=(python3 -I "$REPO/scripts/verify_s2t_phrases.py")
FONTS=(char-s char-tw phrases-s phrases-tw phrases-tw-pv)
RECIPES=()
BUILT=()
for name in "${FONTS[@]}"; do
  RECIPES+=("$WORK/recipes/$name.json")
  BUILT+=("$WORK/fonts/$name.ttf")
done
rm -rf "$LOGS"
mkdir -p "$LOGS" "$WORK"
cd "$REPO" || exit 1

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
    printf '%-24s PASS\n' "$number-$name"
  else
    printf '%-24s FAIL (exit %d)  %s\n' "$number-$name" "$code" "$log"
  fi
}

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

# Fails when any test is skipped: a skipped test is not a passing test.
swift_test() {
  local tmp code
  tmp=$(mktemp)
  swift test >"$tmp" 2>&1
  code=$?
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

# fetch_pinned DIR NAME SHA256 URL: downloads into its own cache directory once.
fetch_pinned() {
  local dir="$CORPORA/$1" name=$2 want=$3 url=$4
  mkdir -p "$dir"
  if [[ -f "$dir/$name" ]] && [[ "$(sha "$dir/$name")" == "$want" ]]; then
    echo "ok       $1/$name"
    return 0
  fi
  # The SIGHAN server drops long transfers: resume a partial file.
  curl -fsSL --retry 5 -C - -o "$dir/$name.part" "$url" || { echo "FAIL     $1/$name (download)"; return 1; }
  if [[ "$(sha "$dir/$name.part")" != "$want" ]]; then
    echo "FAIL     $1/$name (sha256 $(sha "$dir/$name.part") != $want)"
    rm -f "$dir/$name.part"
    return 1
  fi
  mv -f "$dir/$name.part" "$dir/$name"
  echo "fetched  $1/$name"
}

fetch() {
  local code=0 entry name want path
  bash "$REPO/scripts/fetch-fixtures.sh" || code=1
  bash "$REPO/scripts/fetch-opencc.sh" || code=1
  fetch_pinned nahan-simplified nahan.txt d102289ecdfba07ac453dd2b97af482860d8344d5440fc3e60d8691646fd2238 \
    "https://raw.githubusercontent.com/BlankRain/ebooks/master/%E5%91%90%E5%96%8A-%E9%B2%81%E8%BF%85-TXT%E5%B0%8F%E8%AF%B4%E5%A4%A9%E5%A0%82.txt" ||
    code=1
  fetch_pinned sighan2005 icwb2-data.zip 296c54adf4abc3702eca0cbce70b55fe22a344ea02d33175a4d1183e074072b4 \
    "http://sighan.cs.uchicago.edu/bakeoff2005/data/icwb2-data.zip" || code=1
  # The zip is untrusted: only the two test files, by exact name, into their own directory.
  for entry in "pku_test.utf8|48c2655b535ea33802c873373f3176e57d39ba1a45a4dbba164e9125d7ce149e" \
    "msr_test.utf8|8068b0c5a8f309e2ff2ba88dc26de7a8dac2f2684c9c7d8094337d9ce272f601"; do
    IFS='|' read -r name want <<<"$entry"
    path="$CORPORA/sighan2005/extracted/$name"
    if [[ ! -f "$path" ]] || [[ "$(sha "$path")" != "$want" ]]; then
      mkdir -p "$CORPORA/sighan2005/extracted"
      unzip -o -j -q "$CORPORA/sighan2005/icwb2-data.zip" "icwb2-data/testing/$name" -d "$CORPORA/sighan2005/extracted"
    fi
    if [[ "$(sha "$path")" == "$want" ]]; then echo "ok       sighan2005/extracted/$name"; else
      echo "FAIL     sighan2005/extracted/$name"
      code=1
    fi
  done
  return $code
}

# The oracle is stock opencc 1.4.2; its data must be the data the engine bundles.
opencc_data() {
  local share dump d code=0
  share="$(brew --prefix opencc)/share/opencc"
  dump="$WORK/opencc-dump"
  mkdir -p "$dump"
  opencc --version
  for d in STPhrases STPhrases_GeneratedFromRegionalPhrases STCharacters TWVariants TWVariantsPhrases \
    CJK_Compatibility_Ideographs; do
    opencc_dict -i "$share/$d.ocd2" -o "$dump/$d.txt" -f ocd2 -t text || code=1
  done
  "${PY[@]}" dicts "$BUNDLED" "$dump" "$OPENCC" "$share" || code=1
  # SOURCE.txt: the regional-phrase dictionary regenerated from the pinned commit.
  python3 -I "$REPO/scripts/opencc_regional_phrases.py" "$OPENCC" "$WORK/regional" \
    "$WORK/STPhrases_GeneratedFromRegionalPhrases.txt" || code=1
  if cmp "$WORK/STPhrases_GeneratedFromRegionalPhrases.txt" "$BUNDLED/STPhrases_GeneratedFromRegionalPhrases.txt"; then
    echo "PASS regenerated STPhrases_GeneratedFromRegionalPhrases.txt is byte-identical to the bundled file"
  else
    echo "FAIL regenerated STPhrases_GeneratedFromRegionalPhrases.txt differs from the bundled file"
    code=1
  fi
  return $code
}

corpora() {
  local share corpus config code=0
  share="$(brew --prefix opencc)/share/opencc"
  "${PY[@]}" corpora "$CORPORA" "$OPENCC/testcases.json" "$WORK" || return 1
  mkdir -p "$WORK/oracle"
  for corpus in testcases-s2t testcases-s2tw nahan pku msr; do
    for config in s2t s2tw; do
      opencc -c "$share/$config.json" -i "$WORK/corpora/$corpus.txt" -o "$WORK/oracle/$corpus.$config.txt" || code=1
    done
  done
  # The oracle itself passes the official cases (the spike's finding).
  for config in s2t s2tw; do
    if cmp "$WORK/oracle/testcases-$config.$config.txt" "$WORK/corpora/testcases-$config.expected"; then
      echo "PASS opencc $config reproduces every official $config case"
    else
      echo "FAIL opencc $config disagrees with the official $config cases"
      code=1
    fi
  done
  return $code
}

# recipe NAME STEPS: a GuanKiapTsingKhai recipe writing NAME.ttf.
recipe() {
  cat >"$WORK/recipes/$1.json" <<EOF
{"formatVersion": 1,
 "source": {"file": "GuanKiapTsingKhai.ttf", "sha256": "$(sha "$SRC")"},
 "output": {"familyName": "Phrase Check", "fileName": "$1.ttf"},
 "steps": $2}
EOF
}

build_fonts() {
  local name
  mkdir -p "$WORK/recipes" "$WORK/fonts"
  cp "$SRC" "$WORK/recipes/"
  recipe char-s '[{"op": "s2t", "mode": "single"}]'
  recipe char-tw '[{"op": "s2t", "mode": "single", "taiwanVariants": true}]'
  recipe phrases-s '[{"op": "s2t", "mode": "single", "phrases": true}]'
  recipe phrases-tw '[{"op": "s2t", "mode": "single", "taiwanVariants": true, "phrases": true}]'
  recipe phrases-tw-pv '[{"op": "s2t", "mode": "single", "taiwanVariants": true, "phrases": true},
    {"op": "pseudoVertical", "punctuation": "centered"}]'
  "$CLI" build "${RECIPES[@]}" --out-dir "$WORK/fonts"
  local code=$?
  for name in "${FONTS[@]}"; do
    [[ -f "$WORK/fonts/$name.ttf" ]] || { echo "FAIL missing $name.ttf"; code=1; }
  done
  return $code
}

# Separate processes, so hash-seeded iteration order cannot hide.
determinism() {
  local name code=0
  mkdir -p "$WORK/fonts-again"
  "$CLI" build "${RECIPES[@]}" --out-dir "$WORK/fonts-again" >/dev/null || return 1
  for name in "${FONTS[@]}"; do
    if [[ "$(sha "$WORK/fonts/$name.ttf")" == "$(sha "$WORK/fonts-again/$name.ttf")" ]]; then
      echo "PASS $name: built twice, sha256 $(sha "$WORK/fonts/$name.ttf")"
    else
      echo "FAIL $name: two builds differ"
      code=1
    fi
  done
  return $code
}

ct_tool() {
  mkdir -p "$WORK/bin"
  swiftc -O "$REPO/scripts/ct_shape.swift" -o "$WORK/bin/ct_shape"
}

baseline_cli() {
  local commit
  commit=$(git -C "$REPO" rev-parse "$BASELINE") || return 1
  if [[ -x "$BASELINE_CLI" ]] && [[ "$(cat "$BASELINE_DIR/COMMIT" 2>/dev/null)" == "$commit" ]]; then
    echo "reusing $BASELINE_CLI ($commit)"
    return 0
  fi
  rm -rf "$BASELINE_DIR"
  mkdir -p "$BASELINE_DIR"
  git -C "$REPO" archive "$commit" | tar -x -C "$BASELINE_DIR" || return 1
  (cd "$BASELINE_DIR" && swift build -c release) || return 1
  echo "$commit" >"$BASELINE_DIR/COMMIT"
}

# Every shipped recipe without `phrases` must give main's bytes: the presets
# name a placeholder source, so they are pointed at GuanKiapTsingKhai.
# Recipes with `phrases` (main cannot build them) are told apart by content.
parity() {
  local recipe stem dir built main status=0 count=0 code
  for recipe in "$REPO"/recipes/examples/*.json "$REPO"/App/Resources/Presets/*.json; do
    stem="$(basename "$(dirname "$recipe")")-$(basename "$recipe" .json)"
    dir="$WORK/parity/$stem"
    mkdir -p "$dir/branch" "$dir/main"
    cp "$SRC" "$dir/"
    python3 -I - "$recipe" "$dir/recipe.json" "$(sha "$SRC")" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    recipe = json.load(stream)
if any(step.get("phrases") for step in recipe["steps"]):
    sys.exit(3)
recipe["source"] = {"file": "GuanKiapTsingKhai.ttf", "sha256": sys.argv[3]}
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(recipe, stream, ensure_ascii=False)
PY
    code=$?
    if ((code == 3)); then
      echo "PHRASES $stem: uses phrases, not compared with main"
      continue
    elif ((code != 0)); then
      echo "FAIL $stem: could not read the recipe"
      status=1
      continue
    fi
    if ! "$CLI" build "$dir/recipe.json" --out-dir "$dir/branch" >"$dir/branch.log" 2>&1 ||
      ! "$BASELINE_CLI" build "$dir/recipe.json" --out-dir "$dir/main" >"$dir/main.log" 2>&1; then
      echo "FAIL $stem: a build failed (logs in $dir)"
      status=1
      continue
    fi
    built=("$dir"/branch/*.ttf)
    main=("$dir"/main/*.ttf)
    count=$((count + 1))
    if [[ "$(sha "${built[0]}")" == "$(sha "${main[0]}")" ]]; then
      echo "PASS $stem: $(basename "${built[0]}") sha256 $(sha "${built[0]}") = main $BASELINE"
    else
      echo "FAIL $stem: $(sha "${built[0]}") != main $(sha "${main[0]}")"
      status=1
    fi
  done
  echo "RESULT parity: $count recipes without phrases compared with main $BASELINE"
  # The 簡轉繁 preset turns phrases on since the app's phrases toggle (plan
  # step 2): 5 example recipes and the other 3 presets.
  ((count == 8)) || { echo "FAIL: expected 5 example recipes and 3 presets without phrases"; status=1; }
  return $status
}

# Sizes, and the fastest of three CLI builds per recipe (another agent may be
# building on this machine, so these are indications, not benchmarks).
cost() {
  local name i out best seconds code=0
  local TIMEFORMAT=%R
  for name in char-s phrases-s char-tw phrases-tw phrases-tw-pv; do
    printf 'size  %-14s %10d bytes\n' "$name" "$(stat -f %z "$WORK/fonts/$name.ttf")"
  done
  mkdir -p "$WORK/timing"
  for name in char-tw phrases-tw char-s phrases-s; do
    best=""
    for i in 1 2 3; do
      out=$({ time "$CLI" build "$WORK/recipes/$name.json" --out-dir "$WORK/timing" >/dev/null 2>&1 || echo FAILED; } 2>&1)
      [[ "$out" == *FAILED* ]] && { echo "FAIL $name build"; code=1; continue; }
      seconds=${out##*$'\n'}
      if [[ -z "$best" ]] || awk "BEGIN { exit !($seconds < $best) }"; then best=$seconds; fi
    done
    printf 'time  %-14s %6s s (fastest of 3)\n' "$name" "$best"
  done
  return $code
}

run swift-build swift build
run swift-test swift_test
run release-cli swift build -c release
run fetch fetch
run opencc-data opencc_data
run corpora corpora
run build-fonts build_fonts
run determinism determinism
run fonttools-parse "${PY[@]}" parse "$SRC" "${BUILT[@]}"
run ct-shape-tool ct_tool
run shape "${PY[@]}" shape "$WORK" "$WORK/bin/ct_shape" "${FONTS[@]}"
run accuracy "${PY[@]}" accuracy "$WORK" "$SRC"
run pv-upright "${PY[@]}" upright "$WORK" "$SRC" phrases-tw-pv
run baseline-cli baseline_cli
run parity parity
run cost cost

{
  echo "s2t phrases verification  $(date '+%Y-%m-%d %H:%M:%S')"
  echo "worktree $REPO @ $(git -C "$REPO" rev-parse --short HEAD)"
  echo
  failed=0
  for i in "${!names[@]}"; do
    if ((codes[i] == 0)); then status=PASS; else status="FAIL (exit ${codes[i]})"; failed=$((failed + 1)); fi
    printf '%-24s %s\n' "${names[i]}" "$status"
  done
  echo
  echo "Tests:"
  grep -h -E 'Test run with [0-9]+ tests?' "$LOGS"/*-swift-test.log
  echo
  echo "OpenCC data:"
  grep -h -E '^(PASS|FAIL)' "$LOGS"/*-opencc-data.log "$LOGS"/*-corpora.log
  echo
  echo "Build report (phrases-tw):"
  grep -h -A3 'phrases-tw.json$' "$LOGS"/*-build-fonts.log | grep -E '^ +(s2t|phrases) ' | cut -c1-400
  echo
  echo "fontTools parse:"
  grep -h -E '^(PASS|FAIL|RESULT)' "$LOGS"/*-fonttools-parse.log
  echo
  echo "Accuracy (per code point; sentences ok; excluded = input / OpenCC output not in the font):"
  grep -h -E '^(config|s2t|FAIL|RESULT)' "$LOGS"/*-accuracy.log
  echo
  echo "Pseudo-vertical:"
  grep -h -E '^RESULT' "$LOGS"/*-pv-upright.log
  echo
  echo "Determinism:"
  grep -h -E '^(PASS|FAIL)' "$LOGS"/*-determinism.log
  echo
  echo "Recipes without phrases vs main $BASELINE:"
  grep -h -E '^(PASS|FAIL|PHRASES|RESULT)' "$LOGS"/*-parity.log
  echo
  echo "Cost:"
  grep -h -E '^(size|time|FAIL)' "$LOGS"/*-cost.log
  echo
  echo "$((${#names[@]} - failed))/${#names[@]} steps passed; logs in $LOGS"
} | tee "$LOGS/summary.txt"
grep -q 'steps passed' "$LOGS/summary.txt" && ! grep -qE '^[0-9]{2}-.* FAIL' "$LOGS/summary.txt"
