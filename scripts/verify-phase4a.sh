#!/usr/bin/env bash
# Phase 4a acceptance run: import normalization (CFF, variable fonts and
# collections read as static TrueType) and the cmap format 4 encoder.
#
#   scripts/verify-phase4a.sh
#
# Oracles are fontTools: its own CFF → TrueType conversion (cu2qu) for CFF
# fonts and varLib.instancer for variable fonts; static .ttf releases of the
# same design are compared too, and where they differ by more than 1 unit the
# oracle must differ the same way (the font's own difference, not ours).
# Steps marked MEASURE record numbers without gating: the iOS Simulator
# digests, and comparisons whose differences are explained in the summary.
#
# Every step logs to $OUT/verify/NN-name.log. No `set -e`: a failing step is
# recorded and the run continues, so one summary shows everything. The
# summary is printed at the end and written to $OUT/verify/summary.txt.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Artifacts go to the main checkout (gitignored), shared by all worktrees.
MAIN="$(cd "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
OUT="${FONTSMAKER_ARTIFACTS:-$MAIN/artifacts/phase4a}"
LOGS="$OUT/verify"
WORK="$OUT/work"
FIX="${FONTSMAKER_FIXTURES:-$HOME/Library/Caches/FontsMaker/fixtures}"
PY=(python3 -I "$REPO/scripts/verify_normalize.py")
rm -rf "$LOGS" "$WORK"
mkdir -p "$LOGS" "$WORK/json" "$WORK/recipes" "$WORK/built" "$WORK/bin"
cd "$REPO" || exit 1

SIMULATOR="${FONTSMAKER_SIMULATOR:-$(xcrun simctl list devices available -j | python3 -I -c '
import json, sys
devices = [d for runtime, ds in json.load(sys.stdin)["devices"].items() if "iOS" in runtime for d in ds]
pick = [d for d in devices if d["name"].startswith("iPhone")]
print(pick[0]["udid"] if pick else "")
')}"

names=()
codes=()
kinds=()
# run NAME COMMAND...: a gate. measure NAME COMMAND...: recorded, not gating.
step() {
  local kind=$1 name=$2
  shift 2
  local number
  number=$(printf '%02d' $((${#names[@]} + 1)))
  local log="$LOGS/$number-$name.log"
  echo "\$ $*" >"$log"
  "$@" >>"$log" 2>&1
  local code=$?
  names+=("$number-$name")
  codes+=("$code")
  kinds+=("$kind")
  local status
  if ((code == 0)); then status=PASS; elif [[ $kind == measure ]]; then status="MEASURE (exit $code)"; else
    status="FAIL (exit $code)"
  fi
  printf '%-36s %s\n' "$number-$name" "$status"
}
run() { step gate "$@"; }
measure() { step measure "$@"; }

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

# The commit this branch started from: its CLI is the "before" of the cmap
# encoder, built from a clean export so the checkout is never touched.
BASELINE="$(git -C "$REPO" merge-base main HEAD)"
BASELINE_DIR="$OUT/main-${BASELINE:0:7}"
BASELINE_CLI="$BASELINE_DIR/.build/release/fontsmaker"
build_baseline() {
  if [[ -x "$BASELINE_CLI" ]] && [[ "$(cat "$BASELINE_DIR/COMMIT" 2>/dev/null)" == "$BASELINE" ]]; then
    echo "reusing $BASELINE_CLI ($BASELINE)"
    return 0
  fi
  rm -rf "$BASELINE_DIR"
  mkdir -p "$BASELINE_DIR"
  git -C "$REPO" archive "$BASELINE" | tar -x -C "$BASELINE_DIR" || return 1
  (cd "$BASELINE_DIR" && swift build -c release --product fontsmaker) || return 1
  echo "$BASELINE" >"$BASELINE_DIR/COMMIT"
}

build_tools() {
  swift build -c release --product fontsmaker || return 1
  swiftc -O "$REPO/scripts/ct_shape.swift" -o "$WORK/bin/ct_shape" || return 1
  swiftc -O "$REPO/scripts/ct_vertical_ink.swift" -o "$WORK/bin/ct_vertical_ink"
}

# Vertical text: the converted font's ink sits where the source's does.
# One ct_vertical_ink process per font (they share a PostScript name).
vertical_ink() {
  local source=$1 ours=$2 name=$3
  "${PY[@]}" vertical-sample "$source" "$WORK/$name-vertical.txt" 100 || return 1
  "$WORK/bin/ct_vertical_ink" "$source" "$WORK/$name-vertical.txt" "$WORK/$name-vertical-source.jsonl" || return 1
  "$WORK/bin/ct_vertical_ink" "$ours" "$WORK/$name-vertical.txt" "$WORK/$name-vertical-ours.jsonl" || return 1
  "${PY[@]}" vertical-ink "$WORK/$name-vertical-source.jsonl" "$WORK/$name-vertical-ours.jsonl" \
    "$WORK/$name-vertical.txt"
}

# vmtx of a variable instance: tsb follows the outline so the vertical
# origin stays the default instance's, which is also what the instancer
# writes when the font has no VVAR.
vmtx_like_instancer() {
  local log=$1
  grep 'vmtx entries differing' "$log"
  grep -q 'vmtx entries differing from the reference: 0 of' "$log"
}

inspect_all() {
  local code=0 font
  for font in ZhudouSans-Regular.otf ZhudouSansVF.ttf Literata-VF.ttf Inter-VF.ttf GenSenRounded2TC-R.otf \
    GenSenRounded2-R.ttc; do
    echo "== $font"
    "$CLI" inspect "$FIX/$font" || code=1
  done
  # Collections list every member; the CFF font says it is converted.
  "$CLI" inspect "$FIX/GenSenRounded2-R.ttc" | grep -c '^  [0-3]' | grep -qx 4 || { echo "expected 4 faces"; code=1; }
  "$CLI" inspect "$FIX/GenSenRounded2TC-R.otf" | grep -q 'converted to static TrueType' || code=1
  return $code
}

# convert NAME SOURCE [roundtrip options...]: our conversion into $WORK.
convert() {
  local name=$1 source=$2
  shift 2
  "$CLI" roundtrip "$source" "$WORK/$name.ttf" "$@"
}

# compare NAME OURS REFERENCE [options]: verify_normalize compare, JSON kept.
compare() {
  local name=$1 ours=$2 reference=$3
  shift 3
  "${PY[@]}" compare "$ours" "$reference" --json "$WORK/json/$name.json" "$@"
}

# require LOG CHECK...: each named check of a compare log passed.
require() {
  local log=$1 code=0 check
  shift
  for check in "$@"; do
    if grep -q "^PASS  $check" "$log"; then echo "PASS  $check"; else
      echo "FAIL  $check: $(grep -E "^(PASS|FAIL)  $check" "$log")"
      code=1
    fi
  done
  return $code
}
lastlog() { ls "$LOGS"/*-"$1".log | tail -1; }

# Away from the default instance, CoreText blends on a 1/64 grid and
# fontTools in floating point, so integer rounding lands on different sides
# of a half (at wght 700, avar maps Literata to exactly 0.5 normalized).
# Both are compared with fontTools' exact float blend: ours may not be
# further from it than the instancer is.
no_worse_than_instancer() {
  python3 -I - "$WORK/json/$1.json" "$WORK/json/$2.json" <<'PY'
import json, sys
ours, oracle = (json.load(open(p)) for p in sys.argv[1:])
print(f"ours max {ours['max']:.3f} u (over 1 u: {ours['over1']}), "
      f"instancer max {oracle['max']:.3f} u (over 1 u: {oracle['over1']})")
sys.exit(0 if ours["max"] <= oracle["max"] + 0.01 else 1)
PY
}

timed_gensen() {
  /usr/bin/time -l "$CLI" roundtrip "$FIX/GenSenRounded2TC-R.otf" "$WORK/gensen-otf.ttf"
}

cmap_limits() {
  "${PY[@]}" cmap4 "$WORK/gensen-otf.ttf" | tee "$WORK/gensen-cmap4.txt"
  local ours fonttools old
  ours=$(sed -n 's/.*as stored in the font: \[\([0-9]*\)\].*/\1/p' "$WORK/gensen-cmap4.txt")
  fonttools=$(sed -n 's/.*fontTools format 4 encoding: \([0-9]*\) bytes.*/\1/p' "$WORK/gensen-cmap4.txt")
  old=$(sed -n 's/.*pre-Phase-4a encoding: \([0-9]*\) bytes.*/\1/p' "$WORK/gensen-cmap4.txt")
  echo "ours $ours, fontTools $fonttools, before Phase 4a $old"
  [[ -n "$ours" && "$ours" == "$fonttools" && "$old" -gt 65535 ]] || return 1
  # The encoder before Phase 4a, given the same font as glyf, refuses it.
  if "$BASELINE_CLI" roundtrip "$WORK/gensen-otf.ttf" "$WORK/gensen-baseline.ttf" >"$WORK/gensen-baseline.log" 2>&1; then
    echo "baseline CLI wrote the cmap; expected the 64 KiB refusal"
    return 1
  fi
  cat "$WORK/gensen-baseline.log"
  grep -q 'cmap format 4 subtable needs' "$WORK/gensen-baseline.log"
}

# CoreText loads the font and finds every character in it, without fallback.
coretext_loads() {
  local font=$1 sample=${2:-永東國酬愛鬱靈鷹體鬢、。「」} text="$WORK/ct-text.txt"
  local out="$WORK/ct-$(basename "$1").jsonl"
  printf '%s\n' "$sample" >"$text"
  "$WORK/bin/ct_shape" "$font" "$text" "$out" || return 1
  cat "$out"
  ! grep -q -- '\[-1,' "$out"
}

parse_all() {
  local code=0 font
  for font in "$@"; do "${PY[@]}" parse "$font" || code=1; done
  return $code
}

# Existing operations on converted sources: embolden 12, s2t with phrases,
# pseudo-vertical (the reader-test combination), from a CFF font, a
# variable instance and a collection member.
write_recipe() {
  local name=$1 file=$2 family=$3 extra=$4
  cat >"$WORK/recipes/$name.json" <<EOF
{
  "formatVersion": 1,
  "source": { "file": "$FIX/$file", "sha256": "$(sha "$FIX/$file")"$extra },
  "output": { "familyName": "$family" },
  "steps": [
    { "op": "embolden", "weight": 12 },
    { "op": "s2t", "mode": "single", "taiwanVariants": true, "phrases": true },
    { "op": "pseudoVertical", "punctuation": "centered" }
  ]
}
EOF
}
recipes() {
  write_recipe gensen-otf GenSenRounded2TC-R.otf "FMTest Rounded Bold V" ""
  write_recipe zhudou-vf ZhudouSansVF.ttf "FMTest Bean Bold V" ', "variation": { "wght": 500 }'
  write_recipe gensen-ttc GenSenRounded2-R.ttc "FMTest Rounded TC Bold V" ', "faceIndex": 1'
  local code=0 name built sample
  for name in gensen-otf zhudou-vf gensen-ttc; do
    echo "== $name"
    /usr/bin/time -l "$CLI" build "$WORK/recipes/$name.json" --out-dir "$WORK/built/$name" || { code=1; continue; }
    built=$(ls "$WORK/built/$name"/*.ttf)
    "${PY[@]}" parse "$built" || code=1
    sample=永東國酬愛鬱靈鷹體鬢、。「」
    [[ $name == zhudou-vf ]] && sample="、。「」！？（）ＡＢＣａｂｃ０１２"
    coretext_loads "$built" "$sample" || code=1
  done
  return $code
}

# Same input converted twice gives the same bytes (threads included).
reproducible() {
  local code=0 entry name source options a b
  for entry in "gensen-otf|$FIX/GenSenRounded2TC-R.otf|" "zhudou-vf400|$FIX/ZhudouSansVF.ttf|--variation wght=400" \
    "literata-700|$FIX/Literata-VF.ttf|--variation wght=700" "gensen-ttc1|$FIX/GenSenRounded2-R.ttc|--face 1"; do
    IFS='|' read -r name source options <<<"$entry"
    # shellcheck disable=SC2086
    "$CLI" roundtrip "$source" "$WORK/again-a-$name.ttf" $options || code=1
    # shellcheck disable=SC2086
    "$CLI" roundtrip "$source" "$WORK/again-b-$name.ttf" $options || code=1
    a=$(sha "$WORK/again-a-$name.ttf")
    b=$(sha "$WORK/again-b-$name.ttf")
    echo "$name $a $b"
    [[ "$a" == "$b" ]] || code=1
  done
  return $code
}

# Recipes built before this phase vs now: which tables changed. The cmap
# encoder is the only intended difference.
parity() {
  local code=0 recipe stem dir
  for recipe in "$REPO"/recipes/examples/*.json "$REPO"/recipes/reader-test/*.json; do
    stem=$(basename "$recipe" .json)
    dir="$WORK/parity/$stem"
    mkdir -p "$dir"
    sed "s|\"file\": \"GuanKiapTsingKhai.ttf\"|\"file\": \"$FIX/GuanKiapTsingKhai.ttf\"|" "$recipe" >"$dir/recipe.json"
    "$BASELINE_CLI" build "$dir/recipe.json" --out-dir "$dir/main" >"$dir/main.log" 2>&1 || { code=1; continue; }
    "$CLI" build "$dir/recipe.json" --out-dir "$dir/now" >"$dir/now.log" 2>&1 || { code=1; continue; }
    python3 -I - "$stem" "$dir/main"/*.ttf "$dir/now"/*.ttf <<'PY' || code=1
import struct, sys
stem, before, after = sys.argv[1:]
def tables(path):
    data = open(path, "rb").read()
    count = struct.unpack(">H", data[4:6])[0]
    out = {}
    for i in range(count):
        tag, _, offset, length = struct.unpack(">4sIII", data[12 + 16 * i:28 + 16 * i])
        body = data[offset:offset + length]
        if tag == b"head":
            body = body[:8] + body[12:]  # checkSumAdjustment follows every table
        out[tag.decode("latin-1")] = body
    return out
a, b = tables(before), tables(after)
changed = sorted(t for t in set(a) | set(b) if a.get(t) != b.get(t))
print(f"{stem}: tables changed {changed or 'none'}")
sys.exit(0 if set(changed) <= {"cmap"} else 1)
PY
  done
  return $code
}

# macOS vs iOS Simulator: the same conversions on both, digests compared.
# Measured, not gated: CoreText is a system library and may differ by OS.
digests() {
  local copy="$WORK/digest-package" code=0
  rm -rf "$copy" "$WORK/digest-out"
  mkdir -p "$copy" "$WORK/digest-out"
  cp -R "$REPO/Package.swift" "$REPO/Package.resolved" "$REPO/Sources" "$REPO/Tests" "$copy/" 2>/dev/null
  cat >"$copy/Tests/FontsMakerKitTests/DigestProbe.swift" <<EOF
import Foundation
import Testing

@testable import FontsMakerKit

struct DigestProbe {
    @Test func digests() throws {
        let cache = "$FIX"
        let cases: [(String, [UInt8], Int, [String: Double])] = [
            ("cff.otf", try Fixtures.bytes("cff.otf"), 0, [:]),
            ("variable.ttf@650,30", try Fixtures.bytes("variable.ttf"), 0, ["wght": 650, "opsz": 30]),
            ("collection.ttc#1", try Fixtures.bytes("collection.ttc"), 1, [:]),
            ("ZhudouSans-Regular.otf", [UInt8](try Data(contentsOf: URL(fileURLWithPath: cache + "/ZhudouSans-Regular.otf"))), 0, [:]),
            ("ZhudouSansVF.ttf@400", [UInt8](try Data(contentsOf: URL(fileURLWithPath: cache + "/ZhudouSansVF.ttf"))), 0, ["wght": 400]),
            ("Literata-VF.ttf@700", [UInt8](try Data(contentsOf: URL(fileURLWithPath: cache + "/Literata-VF.ttf"))), 0, ["wght": 700]),
            ("GenSenRounded2TC-R.otf", [UInt8](try Data(contentsOf: URL(fileURLWithPath: cache + "/GenSenRounded2TC-R.otf"))), 0, [:]),
        ]
        for (name, bytes, face, variation) in cases {
            let font = try Font(bytes: bytes, faceIndex: face, variation: variation)
            let bytes = try font.serialize(options: WriteOptions())
            print("DIGEST \(name) \(sha256Hex(bytes))")
            #if os(iOS)
                let platform = "ios"
            #else
                let platform = "macos"
            #endif
            try Data(bytes).write(to: URL(fileURLWithPath: "$WORK/digest-out/\(platform)-\(name).ttf"))
        }
    }
}
EOF
  echo "== macOS"
  (cd "$copy" && swift test --filter DigestProbe) >"$WORK/digest-macos.log" 2>&1 || code=1
  grep '^DIGEST' "$WORK/digest-macos.log" | sort >"$WORK/digest-macos.txt"
  cat "$WORK/digest-macos.txt"
  echo "== iOS Simulator $SIMULATOR"
  (cd "$copy" && xcodebuild test -scheme FontsMaker-Package -destination "platform=iOS Simulator,id=$SIMULATOR" \
    -derivedDataPath "$copy/DerivedData" -only-testing:FontsMakerKitTests/DigestProbe) >"$WORK/digest-ios.log" 2>&1 ||
    code=1
  grep -o 'DIGEST .*' "$WORK/digest-ios.log" | sort -u >"$WORK/digest-ios.txt"
  cat "$WORK/digest-ios.txt"
  [[ -s "$WORK/digest-macos.txt" && -s "$WORK/digest-ios.txt" ]] || { echo "missing digests"; return 1; }
  if diff "$WORK/digest-macos.txt" "$WORK/digest-ios.txt"; then echo "SAME on macOS and iOS Simulator"; else
    echo "DIFFERENT between macOS and iOS Simulator"
    code=1
  fi
  python3 -I - "$WORK/digest-out" <<'PY'
import glob, os, sys
from fontTools.ttLib import TTFont
for mac in sorted(glob.glob(os.path.join(sys.argv[1], "macos-*.ttf"))):
    ios = mac.replace("/macos-", "/ios-")
    if not os.path.exists(ios):
        continue
    a, b = TTFont(mac), TTFont(ios)
    tables = sorted(t for t in a.reader.keys() if t not in b.reader or a.reader[t] != b.reader[t])
    def points(font, name):
        coordinates, ends, flags = font["glyf"][name].getCoordinates(font["glyf"])
        return list(coordinates), list(ends), [f & 1 for f in flags]
    glyphs = [g for g, n in enumerate(a.getGlyphOrder()) if points(a, n) != points(b, n)]
    print(f"{os.path.basename(mac)[6:]}: tables differing {tables or 'none'}; glyphs differing {len(glyphs)} {glyphs[:12]}")
PY
  return $code
}

run fetch-fixtures bash scripts/fetch-fixtures.sh
run build-tools build_tools
CLI="$(swift build -c release --show-bin-path)/fontsmaker"
run build-baseline build_baseline
run package-tests make test-swift
run inspect inspect_all

# 煮豆黑體: one design as CFF, static TrueType and variable.
run zhudou-otf-convert convert zhudou-otf "$FIX/ZhudouSans-Regular.otf"
run zhudou-otf-oracle "${PY[@]}" otf2ttf "$FIX/ZhudouSans-Regular.otf" "$WORK/zhudou-otf-oracle.ttf"
run zhudou-otf-vs-fonttools compare zhudou-otf-vs-fonttools "$WORK/zhudou-otf.ttf" "$WORK/zhudou-otf-oracle.ttf"
measure zhudou-otf-vs-cff compare zhudou-otf-vs-cff "$WORK/zhudou-otf.ttf" "$FIX/ZhudouSans-Regular.otf"
measure fonttools-otf-vs-cff compare fonttools-otf-vs-cff "$WORK/zhudou-otf-oracle.ttf" "$FIX/ZhudouSans-Regular.otf"
run zhudou-otf-cff-outliers "${PY[@]}" outliers "$WORK/json/zhudou-otf-vs-cff.json" "$WORK/json/fonttools-otf-vs-cff.json"
measure zhudou-otf-vs-static compare zhudou-otf-vs-static "$WORK/zhudou-otf.ttf" "$FIX/ZhudouSans-Regular.ttf"
measure fonttools-otf-vs-static compare fonttools-otf-vs-static "$WORK/zhudou-otf-oracle.ttf" "$FIX/ZhudouSans-Regular.ttf"
run zhudou-otf-static-outliers "${PY[@]}" outliers "$WORK/json/zhudou-otf-vs-static.json" \
  "$WORK/json/fonttools-otf-vs-static.json"
run zhudou-otf-static-cmap-advance require "$(lastlog zhudou-otf-vs-static)" "cmap" "advance widths identical"

run zhudou-vf400-convert convert zhudou-vf400 "$FIX/ZhudouSansVF.ttf" --variation wght=400
run zhudou-vf400-oracle "${PY[@]}" instance "$FIX/ZhudouSansVF.ttf" "$WORK/zhudou-vf400-oracle.ttf" wght=400
run zhudou-vf400-vs-instancer compare zhudou-vf400-vs-instancer "$WORK/zhudou-vf400.ttf" "$WORK/zhudou-vf400-oracle.ttf"
measure zhudou-vf400-vs-static compare zhudou-vf400-vs-static "$WORK/zhudou-vf400.ttf" "$FIX/ZhudouSans-Regular.ttf"
measure instancer-vf400-vs-static compare instancer-vf400-vs-static "$WORK/zhudou-vf400-oracle.ttf" \
  "$FIX/ZhudouSans-Regular.ttf"
run zhudou-vf400-static-outliers "${PY[@]}" outliers "$WORK/json/zhudou-vf400-vs-static.json" \
  "$WORK/json/instancer-vf400-vs-static.json"
run zhudou-vf400-static-cmap-advance require "$(lastlog zhudou-vf400-vs-static)" "cmap" "advance widths identical"
run zhudou-vf700-convert convert zhudou-vf700 "$FIX/ZhudouSansVF.ttf" --variation wght=700
run zhudou-vf700-oracle "${PY[@]}" instance "$FIX/ZhudouSansVF.ttf" "$WORK/zhudou-vf700-oracle.ttf" wght=700
run zhudou-vf700-vs-instancer compare zhudou-vf700-vs-instancer "$WORK/zhudou-vf700.ttf" "$WORK/zhudou-vf700-oracle.ttf"
run zhudou-vf400-vmtx vmtx_like_instancer "$(lastlog zhudou-vf400-vs-instancer)"
run zhudou-vf700-vmtx vmtx_like_instancer "$(lastlog zhudou-vf700-vs-instancer)"

# Literata and Inter: opsz (CoreText sets it from the point size unless
# told), avar, MVAR. The default instance is read with no variation at all.
run literata-default-convert convert literata-default "$FIX/Literata-VF.ttf"
run literata-default-oracle "${PY[@]}" instance "$FIX/Literata-VF.ttf" "$WORK/literata-default-oracle.ttf" wght=400 opsz=12
run literata-default-vs-instancer compare literata-default-vs-instancer "$WORK/literata-default.ttf" \
  "$WORK/literata-default-oracle.ttf"
run literata-300-72-convert convert literata-300-72 "$FIX/Literata-VF.ttf" --variation wght=300,opsz=72
run literata-300-72-oracle "${PY[@]}" instance "$FIX/Literata-VF.ttf" "$WORK/literata-300-72-oracle.ttf" wght=300 opsz=72
measure literata-300-72-vs-instancer compare literata-300-72-vs-instancer "$WORK/literata-300-72.ttf" \
  "$WORK/literata-300-72-oracle.ttf"
measure literata-300-72-vs-exact compare literata-300-72-vs-exact "$WORK/literata-300-72.ttf" "$FIX/Literata-VF.ttf" \
  --location wght=300,opsz=72
measure instancer-300-72-vs-exact compare instancer-300-72-vs-exact "$WORK/literata-300-72-oracle.ttf" \
  "$FIX/Literata-VF.ttf" --location wght=300,opsz=72
run literata-300-72-no-worse no_worse_than_instancer literata-300-72-vs-exact instancer-300-72-vs-exact
run literata-700-convert convert literata-700 "$FIX/Literata-VF.ttf" --variation wght=700
run literata-700-oracle "${PY[@]}" instance "$FIX/Literata-VF.ttf" "$WORK/literata-700-oracle.ttf" wght=700 opsz=12
measure literata-700-vs-instancer compare literata-700-vs-instancer "$WORK/literata-700.ttf" "$WORK/literata-700-oracle.ttf"
measure literata-700-vs-exact compare literata-700-vs-exact "$WORK/literata-700.ttf" "$FIX/Literata-VF.ttf" \
  --location wght=700,opsz=12
measure instancer-700-vs-exact compare instancer-700-vs-exact "$WORK/literata-700-oracle.ttf" "$FIX/Literata-VF.ttf" \
  --location wght=700,opsz=12
run literata-700-no-worse no_worse_than_instancer literata-700-vs-exact instancer-700-vs-exact
run inter-600-convert convert inter-600 "$FIX/Inter-VF.ttf" --variation wght=600
run inter-600-oracle "${PY[@]}" instance "$FIX/Inter-VF.ttf" "$WORK/inter-600-oracle.ttf" wght=600 opsz=14
run inter-600-vs-instancer compare inter-600-vs-instancer "$WORK/inter-600.ttf" "$WORK/inter-600-oracle.ttf"

# 源泉圓體 TC: 37,634-glyph CFF whose BMP cmap no longer fits the old encoder.
run gensen-otf-convert timed_gensen
run gensen-otf-parse "${PY[@]}" parse "$WORK/gensen-otf.ttf"
run gensen-cmap-limits cmap_limits
run gensen-coretext coretext_loads "$WORK/gensen-otf.ttf"
run gensen-otf-oracle "${PY[@]}" otf2ttf "$FIX/GenSenRounded2TC-R.otf" "$WORK/gensen-otf-oracle.ttf"
run gensen-otf-points "${PY[@]}" points "$WORK/gensen-otf.ttf" "$WORK/gensen-otf-oracle.ttf"
run gensen-otf-vs-fonttools compare gensen-otf-vs-fonttools "$WORK/gensen-otf.ttf" "$WORK/gensen-otf-oracle.ttf" --every 20
run gensen-ttc1-convert convert gensen-ttc1 "$FIX/GenSenRounded2-R.ttc" --face 1
run gensen-ttc1-points "${PY[@]}" points "$WORK/gensen-ttc1.ttf" "$FIX/GenSenRounded2-R.ttc" --face 1
run gensen-ttc1-vs-member compare gensen-ttc1-vs-member "$WORK/gensen-ttc1.ttf" "$FIX/GenSenRounded2-R.ttc" --face 1 \
  --every 20
run gensen-ttc1-coretext coretext_loads "$WORK/gensen-ttc1.ttf"
run gensen-otf-vertical-ink vertical_ink "$FIX/GenSenRounded2TC-R.otf" "$WORK/gensen-otf.ttf" gensen-otf

run recipes recipes
run reproducible reproducible
measure parity-guankiap parity
measure ios-digests digests

failed=0
for index in "${!names[@]}"; do
  if ((codes[index] != 0)) && [[ ${kinds[$index]} != measure ]]; then failed=$((failed + 1)); fi
done
{
  echo "Phase 4a verify — $(date '+%Y-%m-%d %H:%M:%S')"
  echo "commit $(git -C "$REPO" rev-parse --short HEAD), baseline ${BASELINE:0:7}, simulator $SIMULATOR"
  for index in "${!names[@]}"; do
    code=${codes[$index]}
    if ((code == 0)); then status=PASS; elif [[ ${kinds[$index]} == measure ]]; then status="MEASURE (exit $code)"; else
      status="FAIL (exit $code)"
    fi
    printf '%-36s %s\n' "${names[$index]}" "$status"
  done
  echo
  echo "Outline comparisons:"
  grep -h '^\(PASS\|FAIL\)  outline distance' "$LOGS"/*.log | sort | uniq -c | sed 's/^/  /'
  for log in "$LOGS"/*-vs-*.log; do
    printf '  %-40s %s\n' "$(basename "$log" .log)" "$(grep -h 'outline distance' "$log" | sed 's/.*glyphs; //' | cut -c1-90)"
  done
  echo "GenSen conversion: $(grep -h 'real' "$(lastlog gensen-otf-convert)" | head -1)"
  echo "  $(grep -h 'maximum resident set size\|peak memory footprint' "$(lastlog gensen-otf-convert)" | tr -s ' ' | paste -sd ';' -)"
  echo "cmap: $(grep -h '^ours ' "$(lastlog gensen-cmap-limits)")"
  echo "Vertical ink (GenSen otf): $(grep -h 'ink in vertical' "$(lastlog gensen-otf-vertical-ink)")"
  echo "vmtx vs instancer: $(grep -h 'vmtx entries' "$(lastlog zhudou-vf400-vmtx)") (Zhudou @400);" \
    "$(grep -h 'vmtx entries' "$(lastlog zhudou-vf700-vmtx)") (@700)"
  echo "Parity with ${BASELINE:0:7}:"
  grep -h ': tables changed' "$(lastlog parity-guankiap)" | sed 's/^/  /'
  echo "iOS Simulator: $(grep -h '^SAME\|^DIFFERENT\|missing digests' "$(lastlog ios-digests)")"
  grep -h ': tables differing' "$(lastlog ios-digests)" | sed 's/^/  /'
  echo "Exact point comparison:"
  for log in "$LOGS"/*-points.log; do
    printf '  %-40s %s\n' "$(basename "$log" .log)" "$(grep -h 'point for point' "$log" | sed 's/^INFO  //')"
  done
  echo
  echo "$failed gate(s) failed"
} | tee "$LOGS/summary.txt"
exit $((failed > 0))
