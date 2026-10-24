#!/usr/bin/env bash
# Acceptance run for s2t phrases in the app (plan, step 2) and the export
# check through CoreText shaping: generate the Xcode project, build the app
# for macOS and the iOS Simulator, run the app's tests on macOS and on an
# iPhone simulator and the package tests, build the release CLI, run the iOS
# flows on an iPhone and an iPad simulator (scripts/ios-flows.sh, which ERASES
# them), rebuild every font the flows exported from its exported recipe with
# that CLI (the bytes must be identical), the same for the macOS VM's exports
# in $OUT/export-macos, and run scripts/verify-s2t-phrases.sh.
#
#   FONTSMAKER_IPHONE_SIMULATOR=<udid> FONTSMAKER_IPAD_SIMULATOR=<udid> scripts/verify-app-phrases.sh
#
# Every step logs to $OUT/verify/NN-name.log. No `set -e`: a failing step is
# recorded and the run continues, so one summary shows everything. The
# summary is printed at the end and written to $OUT/verify/summary.txt.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Artifacts go to the main checkout (gitignored), shared by all worktrees.
MAIN="$(cd "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
OUT="${FONTSMAKER_ARTIFACTS:-$MAIN/artifacts/app-phrases}"
FIXTURES="${FONTSMAKER_FIXTURES:-$HOME/Library/Caches/FontsMaker/fixtures}"
IPHONE="${FONTSMAKER_IPHONE_SIMULATOR:-}"
IPAD="${FONTSMAKER_IPAD_SIMULATOR:-}"
# The macOS app's exports, saved in the VM and copied out (device-lab).
MAC_EXPORTS="$OUT/export-macos"
LOGS="$OUT/verify"
WORK="$LOGS/work"
DERIVED="$REPO/App/DerivedData"
rm -rf "$LOGS"
mkdir -p "$LOGS" "$WORK"
cd "$REPO" || exit 1
# ios-flows.sh and verify-s2t-phrases.sh write under this run's directory.
export FONTSMAKER_ARTIFACTS="$OUT"

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
    printf '%-32s PASS\n' "$number-$name"
  else
    printf '%-32s FAIL (exit %d)  %s\n' "$number-$name" "$code" "$log"
  fi
}

# The project is generated from App/project.yml; a committed copy would drift.
project_untracked() {
  local tracked
  tracked=$(git ls-files -- 'App/*.xcodeproj' 'App/**/*.xcodeproj/*')
  if [[ -n "$tracked" ]]; then
    echo "tracked Xcode project files:"
    echo "$tracked"
    return 1
  fi
  echo "no .xcodeproj under version control"
}

xcode() {
  xcodebuild -project App/FontsMaker.xcodeproj -derivedDataPath "$DERIVED" "$@"
}

# Fails when any test is skipped (a skipped test is not a passing test), when
# no Swift Testing summary says the run passed, and when the device benchmark
# or the UI flows ran: those belong to their own schemes only.
check_test_log() {
  local log=$1 code=0
  # appintentsmetadataprocessor reports its own "Metadata extraction skipped"
  # for every app without App Intents; that is not a test.
  if grep -iE 'skipped' "$log" | grep -qv 'appintentsmetadataprocessor'; then
    echo "VERIFY: skipped tests found"
    code=1
  fi
  if ! grep -qE 'Test run with [0-9]+ tests? in [0-9]+ suites? passed' "$log"; then
    echo "VERIFY: no passing Swift Testing summary line"
    code=1
  fi
  if grep -qE 'BuildBenchmark|FlowTests' "$log"; then
    echo "VERIFY: the benchmark or the UI flows ran in a normal test run"
    code=1
  fi
  return $code
}

app_tests() {
  local tmp code
  tmp=$(mktemp)
  xcode "$@" test >"$tmp" 2>&1
  code=$?
  cat "$tmp"
  check_test_log "$tmp" || code=1
  rm -f "$tmp"
  return $code
}

# require_simulator UDID WHAT: the flows erase it, so it is never guessed.
require_simulator() {
  if [[ -z "$1" ]]; then
    echo "VERIFY: set FONTSMAKER_${2}_SIMULATOR to a simulator of your own (the flows erase it)"
    return 1
  fi
  xcrun simctl list devices | grep "$1" || { echo "VERIFY: simulator $1 not found"; return 1; }
}

app_tests_ios_simulator() {
  require_simulator "$IPHONE" IPHONE || return 1
  app_tests -scheme FontsMakerIOS -destination "id=$IPHONE"
}

flows() {
  require_simulator "$1" "$3" || return 1
  bash scripts/ios-flows.sh "$1" "$2"
}

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

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

# parity LABEL DIR MIN MIN_PHRASES: each exported recipe names its source by
# file name, relative to the recipe; the source is taken from the fixtures and
# pinned by the recipe's sha256. Every font in DIR must have its recipe and
# vice versa. Recipes with s2t phrases are marked, and at least MIN_PHRASES
# of them must be among the rebuilt.
parity() {
  local label=$1 exports=$2 min=$3 min_phrases=$4
  local status=0 count=0 phrased=0 recipe stem font source dir built tag
  if [[ ! -d "$exports" ]]; then
    echo "NOT RUN $label parity: no exports in $exports"
    return 1
  fi
  shopt -s nullglob
  for font in "$exports"/*.ttf; do
    if [[ ! -f "${font%.ttf}.json" ]]; then
      echo "FAIL $label/$(basename "$font"): font without its recipe"
      status=1
    fi
  done
  for recipe in "$exports"/*.json; do
    stem=$(basename "$recipe" .json)
    font="$exports/$stem.ttf"
    if [[ ! -f "$font" ]]; then
      echo "FAIL $label/$stem: recipe without the exported font $font"
      status=1
      continue
    fi
    source=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["source"]["file"])' "$recipe")
    tag=$(python3 -I -c '
import json, sys
steps = json.load(open(sys.argv[1]))["steps"]
print("[phrases]" if any(step.get("phrases") for step in steps) else "")' "$recipe")
    if [[ ! -f "$FIXTURES/$source" ]]; then
      echo "FAIL $label/$stem: source $source not in $FIXTURES"
      status=1
      continue
    fi
    dir="$WORK/$label/$stem"
    mkdir -p "$dir/out"
    cp "$recipe" "$dir/$stem.json"
    cp "$FIXTURES/$source" "$dir/$source"
    if ! .build/release/fontsmaker build "$dir/$stem.json" --out-dir "$dir/out"; then
      echo "FAIL $label/$stem: the CLI did not build the recipe"
      status=1
      continue
    fi
    built=("$dir"/out/*.ttf)
    if ((${#built[@]} != 1)); then
      echo "FAIL $label/$stem: expected one font from the CLI, got ${#built[@]}"
      status=1
      continue
    fi
    count=$((count + 1))
    [[ -n "$tag" ]] && phrased=$((phrased + 1))
    if [[ "$(sha "$font")" == "$(sha "${built[0]}")" ]]; then
      echo "PASS $label/$stem $tag: app $(sha "$font") = CLI $(basename "${built[0]}")"
    else
      echo "FAIL $label/$stem $tag: app $(sha "$font") != CLI $(sha "${built[0]}") ($(basename "${built[0]}"))"
      status=1
    fi
  done
  shopt -u nullglob
  echo "RESULT $label parity: $count exported fonts rebuilt by the release CLI, $phrased with phrases"
  if ((count < min || phrased < min_phrases)); then
    echo "FAIL: expected at least $min exports, $min_phrases with phrases, in $exports"
    status=1
  fi
  return $status
}

run project-untracked project_untracked
run xcodegen xcodegen generate --spec App/project.yml
run build-macos xcode -scheme FontsMaker -destination platform=macOS build
run build-ios-simulator xcode -scheme FontsMakerIOS -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
run app-tests app_tests -scheme FontsMaker -destination platform=macOS
run app-tests-ios-simulator app_tests_ios_simulator
run swift-test swift_test
run release-cli swift build -c release
run flows-iphone flows "$IPHONE" iphone IPHONE
run flows-ipad flows "$IPAD" ipad IPAD
# The four presets each; the 簡轉繁 export carries phrases.
run parity-iphone parity iphone "$OUT/flows-iphone/exports" 4 1
run parity-ipad parity ipad "$OUT/flows-ipad/exports" 4 1
run parity-macos parity macos "$MAC_EXPORTS" 1 1
# Its own directory: it clears its verify/ folder, which here is this run's.
S2T_OUT="$OUT/s2t-phrases"
run verify-s2t-phrases env FONTSMAKER_ARTIFACTS="$S2T_OUT" bash scripts/verify-s2t-phrases.sh

{
  echo "App phrases verification  $(date '+%Y-%m-%d %H:%M:%S')"
  echo "worktree $REPO @ $(git -C "$REPO" rev-parse --short HEAD)"
  echo
  failed=0
  for i in "${!names[@]}"; do
    if ((codes[i] == 0)); then status=PASS; else status="FAIL (exit ${codes[i]})"; failed=$((failed + 1)); fi
    printf '%-32s %s\n' "${names[i]}" "$status"
  done
  echo
  echo "Tests:"
  for log in "$LOGS"/*-app-tests.log "$LOGS"/*-app-tests-ios-simulator.log "$LOGS"/*-swift-test.log; do
    printf '%-28s %s\n' "$(basename "$log" .log)" "$(grep -h -E 'Test run with [0-9]+ tests?' "$log" | tail -1)"
  done
  for label in iphone ipad; do
    printf '%-28s %s\n' "flows-$label" "$(grep -h -E 'Executed [0-9]+ tests?, with [0-9]+ failures?' \
      "$OUT/flows-$label"/*-flows.log 2>/dev/null | tail -1)"
    grep -h -E '^(PASS|FAIL) ' "$OUT/flows-$label"/*-check-recipes.log 2>/dev/null | sed "s/^/  $label recipe: /"
  done
  echo
  echo "Parity (app export vs release CLI; [phrases] = the recipe's s2t has phrases):"
  grep -h -E '^(PASS|FAIL|RESULT|NOT RUN)' "$LOGS"/*-parity-*.log
  echo
  echo "scripts/verify-s2t-phrases.sh ($S2T_OUT/verify/summary.txt):"
  grep -h -E '^[0-9]{2}-|Test run with|steps passed' "$S2T_OUT/verify/summary.txt" | sed 's/^/  /'
  sed -n '/^Recipes without phrases/,/^$/p' "$S2T_OUT/verify/summary.txt" | sed 's/^/  /'
  echo "Screenshots:"
  shopt -s nullglob
  for dir in "$OUT"/shots/*/; do
    shots=("$dir"*.png)
    printf '  %-12s %d png\n' "$(basename "$dir")" "${#shots[@]}"
  done
  echo
  echo "Device benchmark:"
  # nullglob does not drop the literal BLOCKED.txt path, so test each file.
  benched=0
  for table in "$OUT"/bench/*/table.md "$OUT"/bench/BLOCKED.txt; do
    [[ -f $table ]] || continue
    benched=1
    echo "  $table"
    sed 's/^/    /' "$table"
  done
  ((benched)) || echo "  MISSING: neither $OUT/bench/<udid>/table.md nor $OUT/bench/BLOCKED.txt"
  shopt -u nullglob
  echo
  echo "$((${#names[@]} - failed))/${#names[@]} steps passed; logs in $LOGS"
} | tee "$LOGS/summary.txt"
grep -q 'steps passed' "$LOGS/summary.txt" && ! grep -qE '^[0-9]{2}-.* FAIL' "$LOGS/summary.txt"
