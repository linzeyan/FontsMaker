#!/usr/bin/env bash
# Build the e-reader test kit: the fonts of recipes/reader-test (each with its
# own family name, so a reader's font menu tells them apart) with the release
# CLI, the unmodified source as the baseline, and the test documents of
# scripts/make-reader-test-epub.py: one EPUB without a font, one per font
# (source included) with the font embedded, a TXT, expected.md, and the
# CoreText check of the s2t fonts.
#
# Copy $OUT/fonts and $OUT/docs to the device (KOReader: koreader/fonts; Kobo:
# /fonts; Kindle: the EPUBs through Send to Kindle or Kindle Previewer).
#
# Every step logs to $OUT/logs/NN-name.log. No `set -e`: a failing step is
# recorded and the run continues; the summary goes to $OUT/logs/summary.txt.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Artifacts go to the main checkout (gitignored), shared by all worktrees.
MAIN="$(cd "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
OUT="${FONTSMAKER_ARTIFACTS:-$MAIN/artifacts/device-readers}/kit"
FIXTURES="${FONTSMAKER_FIXTURES:-$HOME/Library/Caches/FontsMaker/fixtures}"
SOURCE=GuanKiapTsingKhai.ttf
LOGS="$OUT/logs"
WORK="$OUT/work"
rm -rf "$OUT"
mkdir -p "$LOGS" "$WORK" "$OUT/fonts" "$OUT/docs"
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

# Each recipe names its source relative to itself; the source comes from the
# fixtures and is pinned by the recipe's sha256.
build_fonts() {
  local status=0 recipe stem
  if [[ ! -f "$FIXTURES/$SOURCE" ]]; then
    echo "FAIL: $SOURCE not in $FIXTURES (scripts/fetch-fixtures.sh)"
    return 1
  fi
  cp "$FIXTURES/$SOURCE" "$WORK/$SOURCE"
  cp "$FIXTURES/$SOURCE" "$OUT/fonts/$SOURCE"
  for recipe in recipes/reader-test/*.json; do
    stem=$(basename "$recipe" .json)
    cp "$recipe" "$WORK/$stem.json"
    if .build/release/fontsmaker build "$WORK/$stem.json" --out-dir "$OUT/fonts"; then
      echo "PASS $stem"
    else
      echo "FAIL $stem"
      status=1
    fi
  done
  # The embolden step's risk report is not part of the kit.
  rm -f "$OUT"/fonts/*.csv "$OUT"/fonts/*.png
  shasum -a 256 "$OUT"/fonts/*.ttf
  return $status
}

docs() {
  # The source is embedded too: a reader that only shows publisher fonts
  # (Kindle) needs it as the baseline the bold font is judged against.
  local args=(--embed "$OUT/fonts/$SOURCE") font
  shopt -s nullglob
  for font in "$OUT"/fonts/FMTest*.ttf; do
    args+=(--embed "$font")
    case "$(basename "$font")" in
      FMTestPhrases-* | FMTestChar-*) args+=(--check "$font") ;;
    esac
  done
  shopt -u nullglob
  python3 -I scripts/make-reader-test-epub.py --out "$OUT/docs" --source "$OUT/fonts/$SOURCE" "${args[@]}"
}

run release-cli swift build -c release
run fonts build_fonts
run docs docs

{
  echo "Reader test kit  $(date '+%Y-%m-%d %H:%M:%S')"
  echo "worktree $REPO @ $(git -C "$REPO" rev-parse --short HEAD)"
  echo
  failed=0
  for i in "${!names[@]}"; do
    if ((codes[i] == 0)); then status=PASS; else status="FAIL (exit ${codes[i]})"; failed=$((failed + 1)); fi
    printf '%-24s %s\n' "${names[i]}" "$status"
  done
  echo
  echo "Fonts:"
  grep -h -E '^[0-9a-f]{64} ' "$LOGS"/*-fonts.log
  echo
  echo "$((${#names[@]} - failed))/${#names[@]} steps passed; logs in $LOGS"
} | tee "$LOGS/summary.txt"
grep -q 'steps passed' "$LOGS/summary.txt" && ! grep -qE '^[0-9]{2}-.* FAIL' "$LOGS/summary.txt"
