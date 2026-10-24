#!/usr/bin/env bash
# Phase 3a acceptance run, the parts without a GUI: generate the Xcode
# project, build the app for macOS and the iOS Simulator, run the app's
# view-model tests and the package tests, build the release CLI, and rebuild
# every font the app exported (copied from the VM into $OUT/export) from its
# exported recipe with that CLI: the bytes must be identical.
#
# Every step logs to $OUT/verify/NN-name.log. No `set -e`: a failing step is
# recorded and the run continues, so one summary shows everything. The
# summary is printed at the end and written to $OUT/verify/summary.txt.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Artifacts go to the main checkout (gitignored), shared by all worktrees.
MAIN="$(cd "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
OUT="${FONTSMAKER_ARTIFACTS:-$MAIN/artifacts/phase3a}"
FIXTURES="${FONTSMAKER_FIXTURES:-$HOME/Library/Caches/FontsMaker/fixtures}"
# Fonts and recipes the app exported in the VM (S1-S3 at least).
EXPORTS="$OUT/export"
MIN_EXPORTS="${PHASE3A_MIN_EXPORTS:-3}"
LOGS="$OUT/verify"
WORK="$LOGS/work"
DERIVED="$REPO/App/DerivedData"
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

# Fails when any test is skipped: a skipped test is not a passing test.
app_tests() {
  local tmp code
  tmp=$(mktemp)
  xcode -scheme FontsMaker -destination platform=macOS test >"$tmp" 2>&1
  code=$?
  cat "$tmp"
  # appintentsmetadataprocessor reports its own "Metadata extraction skipped"
  # for every app without App Intents; that is not a test.
  if grep -iE 'skipped' "$tmp" | grep -qv 'appintentsmetadataprocessor'; then
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

# Each exported recipe names its source by file name, relative to the recipe;
# the source is taken from the fixtures and pinned by the recipe's sha256.
parity() {
  local status=0 count=0 recipe stem font source dir built
  shopt -s nullglob
  for recipe in "$EXPORTS"/*.json; do
    stem=$(basename "$recipe" .json)
    font="$EXPORTS/$stem.ttf"
    if [[ ! -f "$font" ]]; then
      echo "FAIL $stem: recipe without the exported font $font"
      status=1
      continue
    fi
    source=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["source"]["file"])' "$recipe")
    if [[ ! -f "$FIXTURES/$source" ]]; then
      echo "FAIL $stem: source $source not in $FIXTURES"
      status=1
      continue
    fi
    dir="$WORK/$stem"
    mkdir -p "$dir/out"
    cp "$recipe" "$dir/$stem.json"
    cp "$FIXTURES/$source" "$dir/$source"
    if ! .build/release/fontsmaker build "$dir/$stem.json" --out-dir "$dir/out"; then
      echo "FAIL $stem: the CLI did not build the recipe"
      status=1
      continue
    fi
    built=("$dir"/out/*.ttf)
    if ((${#built[@]} != 1)); then
      echo "FAIL $stem: expected one font from the CLI, got ${#built[@]}"
      status=1
      continue
    fi
    count=$((count + 1))
    if [[ "$(sha "$font")" == "$(sha "${built[0]}")" ]]; then
      echo "PASS $stem: app $(sha "$font") = CLI $(basename "${built[0]}")"
    else
      echo "FAIL $stem: app $(sha "$font") != CLI $(sha "${built[0]}") ($(basename "${built[0]}"))"
      status=1
    fi
  done
  shopt -u nullglob
  echo "RESULT parity: $count exported fonts rebuilt by the release CLI"
  if ((count < MIN_EXPORTS)); then
    echo "FAIL: expected at least $MIN_EXPORTS exports in $EXPORTS"
    status=1
  fi
  return $status
}

run project-untracked project_untracked
run xcodegen xcodegen generate --spec App/project.yml
run build-macos xcode -scheme FontsMaker -destination platform=macOS build
run build-ios-simulator xcode -scheme FontsMakerIOS -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
run app-tests app_tests
run swift-test swift_test
run release-cli swift build -c release
run parity parity

{
  echo "Phase 3a verification  $(date '+%Y-%m-%d %H:%M:%S')"
  echo "worktree $REPO @ $(git -C "$REPO" rev-parse --short HEAD)"
  echo
  failed=0
  for i in "${!names[@]}"; do
    if ((codes[i] == 0)); then status=PASS; else status="FAIL (exit ${codes[i]})"; failed=$((failed + 1)); fi
    printf '%-32s %s\n' "${names[i]}" "$status"
  done
  echo
  echo "Tests:"
  grep -h -E 'Test run with [0-9]+ tests?' "$LOGS"/*-app-tests.log "$LOGS"/*-swift-test.log
  echo
  echo "Parity (app export vs release CLI):"
  grep -h -E '^(PASS|FAIL|RESULT)' "$LOGS"/*-parity.log
  echo
  echo "$((${#names[@]} - failed))/${#names[@]} steps passed; logs in $LOGS"
} | tee "$LOGS/summary.txt"
grep -q 'steps passed' "$LOGS/summary.txt" && ! grep -qE '^[0-9]{2}-.* FAIL' "$LOGS/summary.txt"
