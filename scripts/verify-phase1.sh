#!/usr/bin/env bash
# Phase 1 acceptance run: build, unit + integration tests, iOS Simulator build
# of the engine, CLI round-trips of the synthetic and reference fonts checked
# by fontTools, determinism (sha256) and read/write timings.
#
# Every step logs to $OUT/logs/NN-name.log. No `set -e`: a failing step is
# recorded and the run continues, so one summary shows everything. The
# summary is printed at the end and written to $OUT/summary.txt.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Artifacts go to the main checkout (gitignored), shared by all worktrees.
MAIN="$(cd "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
OUT="${FONTSMAKER_ARTIFACTS:-$MAIN/artifacts/phase1}"
export FONTSMAKER_FIXTURES="${FONTSMAKER_FIXTURES:-$HOME/Library/Caches/FontsMaker/fixtures}"
LOGS="$OUT/logs"
FONTS="$OUT/fonts"
rm -rf "$LOGS" "$FONTS"
mkdir -p "$LOGS" "$FONTS"
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
    printf '%-40s PASS\n' "$number-$name"
  else
    printf '%-40s FAIL (exit %d)  %s\n' "$number-$name" "$code" "$log"
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

# Writing the same input twice must give identical bytes.
deterministic() {
  local source=$1 first=$2 second=$3
  "$CLI" roundtrip "$source" "$second" || return 1
  local a b
  a=$(shasum -a 256 "$first" | cut -d' ' -f1)
  b=$(shasum -a 256 "$second" | cut -d' ' -f1)
  echo "first  $a"
  echo "second $b"
  [[ -n "$a" && "$a" == "$b" ]]
}

vert_map() {
  local source=$1 json=$2
  "$CLI" vert-map "$source" >"$json" || return 1
  python3 -I scripts/verify_roundtrip.py vert "$source" "$json"
}

timings() {
  local tmp code
  tmp=$(mktemp)
  for source in "$@"; do
    for attempt in 1 2 3; do
      echo "== $(basename "$source") run $attempt"
      /usr/bin/time -l "$CLI" roundtrip "$source" "$FONTS/timing.ttf" >"$tmp" 2>&1
      code=$?
      grep -E 'glyphs=|maximum resident set size| real ' "$tmp" | sed "s|^glyphs=|$(basename "$source") glyphs=|"
      if ((code != 0)); then
        cat "$tmp"
        rm -f "$tmp"
        return "$code"
      fi
    done
  done
  rm -f "$tmp" "$FONTS/timing.ttf"
}

run fetch-fixtures bash scripts/fetch-fixtures.sh
run fixtures-reproducible fixtures_reproducible
run swift-build swift build
run swift-test swift_test
run release-build swift build -c release --product fontsmaker
run ios-simulator-build xcodebuild -scheme FontsMakerKit -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$REPO/.build/xcode-ios" build
CLI="$(swift build -c release --show-bin-path)/fontsmaker"

SYNTHETIC="$REPO/Tests/FontsMakerKitTests/Fixtures/synthetic.ttf"
GUAN="$FONTSMAKER_FIXTURES/GuanKiapTsingKhai.ttf"
LXGW="$FONTSMAKER_FIXTURES/LXGWWenKaiTC-Regular.ttf"

for entry in "synthetic|$SYNTHETIC" "guan|$GUAN" "lxgw|$LXGW"; do
  short=${entry%%|*}
  source=${entry#*|}
  run "inspect-$short" "$CLI" inspect "$source"
  run "roundtrip-$short" "$CLI" roundtrip "$source" "$FONTS/$short.ttf"
  run "sha256-twice-$short" deterministic "$source" "$FONTS/$short.ttf" "$FONTS/$short.again.ttf"
  run "fonttools-$short" python3 -I scripts/verify_roundtrip.py roundtrip "$source" "$FONTS/$short.ttf"
  run "decompose-$short" "$CLI" roundtrip --decompose "$source" "$FONTS/$short.decomposed.ttf"
  run "fonttools-decomposed-$short" python3 -I scripts/verify_roundtrip.py roundtrip --decomposed \
    "$source" "$FONTS/$short.decomposed.ttf"
  run "vert-map-$short" vert_map "$source" "$FONTS/$short.vert.json"
done

for entry in "synthetic|$SYNTHETIC" "lxgw|$LXGW"; do
  short=${entry%%|*}
  source=${entry#*|}
  run "strip-hinting-$short" "$CLI" roundtrip --strip-hinting "$source" "$FONTS/$short.stripped.ttf"
  run "fonttools-stripped-$short" python3 -I scripts/verify_roundtrip.py roundtrip --stripped \
    "$source" "$FONTS/$short.stripped.ttf"
done

run timings-release timings "$GUAN" "$LXGW"

{
  echo "Phase 1 verification  $(date '+%Y-%m-%d %H:%M:%S')"
  echo "worktree $REPO @ $(git -C "$REPO" rev-parse --short HEAD)"
  echo
  failed=0
  for i in "${!names[@]}"; do
    if ((codes[i] == 0)); then status=PASS; else status="FAIL (exit ${codes[i]})"; failed=$((failed + 1)); fi
    printf '%-40s %s\n' "${names[i]}" "$status"
  done
  echo
  echo "Timings (release CLI, read = file read + parse, write = serialize + file write):"
  grep -h 'glyphs=' "$LOGS"/*-timings-release.log
  echo
  echo "$((${#names[@]} - failed))/${#names[@]} steps passed; logs in $LOGS"
} | tee "$OUT/summary.txt"
grep -q 'steps passed' "$OUT/summary.txt" && ! grep -q 'FAIL' "$OUT/summary.txt"
