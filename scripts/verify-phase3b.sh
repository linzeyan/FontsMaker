#!/usr/bin/env bash
# Phase 3b acceptance run, the parts without a GUI: generate the Xcode
# project, build the app for macOS and the iOS Simulator, run the app's
# view-model tests on macOS and on the iOS Simulator and the package tests,
# build the release CLI, and rebuild every font the app exported, from the
# macOS VM (artifacts/phase3a/export) and from the iOS Simulator
# (artifacts/phase3b/export-ios), from its exported recipe with that CLI:
# the bytes must be identical.
#
# Every step logs to $OUT/verify/NN-name.log. No `set -e`: a failing step is
# recorded and the run continues, so one summary shows everything. The
# summary is printed at the end and written to $OUT/verify/summary.txt.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Artifacts go to the main checkout (gitignored), shared by all worktrees.
MAIN="$(cd "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
OUT="${FONTSMAKER_ARTIFACTS:-$MAIN/artifacts/phase3b}"
FIXTURES="${FONTSMAKER_FIXTURES:-$HOME/Library/Caches/FontsMaker/fixtures}"
# The macOS app's exports (all four presets, re-exported after the column
# spacing change) and the iOS app's (S1-S3 at least: what
# `scripts/ios-flows.sh <iPhone SE> iphone` left in flows-iphone/exports).
MAC_EXPORTS="$MAIN/artifacts/phase3a/export"
IOS_EXPORTS="$OUT/export-ios"
LOGS="$OUT/verify"
WORK="$LOGS/work"
DERIVED="$REPO/App/DerivedData"
rm -rf "$LOGS"
mkdir -p "$LOGS" "$WORK"
cd "$REPO" || exit 1

# An iPhone simulator for the app tests: $FONTSMAKER_SIMULATOR, else the
# first available iPhone SE (3rd generation), else the first iPhone.
SIMULATOR="${FONTSMAKER_SIMULATOR:-$(xcrun simctl list devices available -j | python3 -I -c '
import json, sys
devices = [d for runtime, ds in json.load(sys.stdin)["devices"].items() if "iOS" in runtime for d in ds]
pick = [d for d in devices if d["name"].startswith("iPhone SE (3rd")] or [d for d in devices if d["name"].startswith("iPhone")]
print(pick[0]["udid"] if pick else "")
')}"

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

app_tests_ios_simulator() {
  if [[ -z "$SIMULATOR" ]]; then
    echo "VERIFY: no iPhone simulator available"
    return 1
  fi
  echo "simulator: $(xcrun simctl list devices | grep "$SIMULATOR")"
  app_tests -scheme FontsMakerIOS -destination "id=$SIMULATOR"
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

# parity LABEL DIR MIN: each exported recipe names its source by file name,
# relative to the recipe; the source is taken from the fixtures and pinned by
# the recipe's sha256. Every font in DIR must have its recipe and vice versa.
parity() {
  local label=$1 exports=$2 min=$3
  local status=0 count=0 recipe stem font source dir built
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
    if [[ "$(sha "$font")" == "$(sha "${built[0]}")" ]]; then
      echo "PASS $label/$stem: app $(sha "$font") = CLI $(basename "${built[0]}")"
    else
      echo "FAIL $label/$stem: app $(sha "$font") != CLI $(sha "${built[0]}") ($(basename "${built[0]}"))"
      status=1
    fi
  done
  shopt -u nullglob
  echo "RESULT $label parity: $count exported fonts rebuilt by the release CLI"
  if ((count < min)); then
    echo "FAIL: expected at least $min exports in $exports"
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
run parity-macos parity macos "$MAC_EXPORTS" 4
run parity-ios parity ios "$IOS_EXPORTS" 3

{
  echo "Phase 3b verification  $(date '+%Y-%m-%d %H:%M:%S')"
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
  echo
  echo "Parity (app export vs release CLI):"
  grep -h -E '^(PASS|FAIL|RESULT)' "$LOGS"/*-parity-*.log
  echo
  echo "$((${#names[@]} - failed))/${#names[@]} steps passed; logs in $LOGS"
} | tee "$LOGS/summary.txt"
grep -q 'steps passed' "$LOGS/summary.txt" && ! grep -qE '^[0-9]{2}-.* FAIL' "$LOGS/summary.txt"
