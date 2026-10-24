#!/usr/bin/env bash
# iOS end-to-end flows (plan, Phase 3b): S1-S3 and the combined preset in the
# iOS app on one simulator, through the Files picker and exporter and the
# share sheet (App/UITests/FlowTests.swift), with a screenshot per step; and
# the font catalog (Phase 4b), which downloads Literata (~1 MB) and 芫荽
# (~5 MB) over the network; 原俠正楷 with Literata's Latin letters (Phase 4d);
# the glyph editor (Phase 4f), which edits on iPad and only shows the
# glyphs on iPhone; risk review's 從另一套字型取代, a risky glyph of
# 原俠正楷 taken from 芫荽; and ①'s own fonts (4g): rename, delete, and
# removing a catalog download (Atkinson Hyperlegible Mono, ~54 KB).
#
#   scripts/ios-flows.sh <simulator udid> <label>
#
# ERASES the given simulator first, so the run starts from an empty library
# and an empty Files folder: use a simulator of your own. Then sets the system
# language to Traditional Chinese (Taiwan), seeds On My iPhone/iPad with the
# source fonts (GuanKiap, and Crimson Text's four styles for English) and an unsupported
# .woff, and runs the FontsMakerIOSFlows scheme.
# Writes to $OUT/flows-<label>/: the xcresult, logs, the app's preferences
# (persisted settings), the fonts and recipes the app exported to Files; and
# the screenshots to $OUT/shots/<label>/.
#
# Every step logs to its own file with its exit code; no `set -e`.
set -u

SIM=${1:?usage: scripts/ios-flows.sh <simulator udid> <label>}
LABEL=${2:?usage: scripts/ios-flows.sh <simulator udid> <label>}
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN="$(cd "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
OUT="${FONTSMAKER_ARTIFACTS:-$MAIN/artifacts/phase3b}"
FIXTURES="${FONTSMAKER_FIXTURES:-$HOME/Library/Caches/FontsMaker/fixtures}"
# FONTSMAKER_FLOWS_ONLY="test9cGlyphEditor ...": run just these flows (each
# must not depend on what an earlier flow left); the recipe check is not run.
ONLY="${FONTSMAKER_FLOWS_ONLY:-}"
RUN="$OUT/flows-$LABEL"
SHOTS="$OUT/shots/$LABEL"
rm -rf "$RUN" "$SHOTS"
mkdir -p "$RUN/exports" "$SHOTS"
cd "$REPO" || exit 1

names=()
codes=()
run() {
  local name=$1
  shift
  local log
  log="$RUN/$(printf '%02d' $((${#names[@]} + 1)))-$name.log"
  echo "\$ $*" >"$log"
  "$@" >>"$log" 2>&1
  local code=$?
  names+=("$name")
  codes+=("$code")
  printf '%-24s %s\n' "$name" "$([[ $code == 0 ]] && echo PASS || echo "FAIL (exit $code)  $log")"
  return $code
}

# Files' local storage (On My iPhone/iPad) is an app group container.
files_storage() {
  local dir
  for dir in ~/Library/Developer/CoreSimulator/Devices/"$SIM"/data/Containers/Shared/AppGroup/*/; do
    if [[ "$(plutil -extract MCMMetadataIdentifier raw "$dir.com.apple.mobile_container_manager.metadata.plist" 2>/dev/null)" \
      == group.com.apple.FileProvider.LocalStorage ]]; then
      echo "${dir}File Provider Storage"
      return 0
    fi
  done
  return 1
}

prepare() {
  xcrun simctl list devices | grep "$SIM" || return 1
  xcrun simctl shutdown "$SIM" 2>/dev/null
  xcrun simctl erase "$SIM" || return 1
  xcrun simctl boot "$SIM" && xcrun simctl bootstatus "$SIM" -b >/dev/null || return 1
  xcrun simctl spawn "$SIM" defaults write -g AppleLanguages -array zh-Hant-TW
  xcrun simctl spawn "$SIM" defaults write -g AppleLocale zh_TW
  # The language applies from the next boot.
  xcrun simctl shutdown "$SIM"
  xcrun simctl boot "$SIM" && xcrun simctl bootstatus "$SIM" -b >/dev/null || return 1
  xcrun simctl status_bar "$SIM" override --time 9:41 --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3
  # Files creates its local storage on first launch.
  xcrun simctl launch "$SIM" com.apple.DocumentsApp && sleep 5 && xcrun simctl terminate "$SIM" com.apple.DocumentsApp
  local storage
  storage=$(files_storage) || { echo "no Files local storage"; return 1; }
  cp "$FIXTURES/GuanKiapTsingKhai.ttf" "$FIXTURES"/CrimsonText-{Regular,Italic,Bold,BoldItalic}.ttf \
    Tests/FontsMakerKitTests/Fixtures/reject-woff.woff "$storage/" || return 1
  # Empty folders the combined flow exports into and shares into.
  mkdir "$storage/字型" "$storage/分享" || return 1
  ls -la "$storage"
}

flows() {
  local tmp code
  tmp=$(mktemp)
  local filter=() expected=13 flow
  for flow in $ONLY; do filter+=("-only-testing:FontsMakerIOSFlows/FlowTests/$flow"); done
  ((${#filter[@]} > 0)) && expected=${#filter[@]}
  xcodebuild -project App/FontsMaker.xcodeproj -derivedDataPath App/DerivedData -scheme FontsMakerIOSFlows \
    -destination "id=$SIM" -resultBundlePath "$RUN/flows.xcresult" -collect-test-diagnostics never \
    ${filter[@]+"${filter[@]}"} test >"$tmp" 2>&1
  code=$?
  cat "$tmp"
  # Every flow asked for, all run: a filter or a crash that runs fewer must not pass.
  if ! grep -qE "Executed $expected tests?, with 0 failures" "$tmp"; then
    echo "VERIFY: expected $expected flows to pass"
    code=1
  fi
  rm -f "$tmp"
  return $code
}

# Screenshots by their attachment names, without the unique suffix.
collect_shots() {
  xcrun xcresulttool export attachments --path "$RUN/flows.xcresult" --output-path "$RUN/attachments" || return 1
  python3 -I - "$RUN/attachments" "$SHOTS" <<'EOF'
import json, os, re, shutil, sys
source, target = sys.argv[1], sys.argv[2]
for test in json.load(open(os.path.join(source, "manifest.json"))):
    for attachment in test.get("attachments", []):
        name = attachment.get("suggestedHumanReadableName", "")
        stem, ext = os.path.splitext(attachment["exportedFileName"])
        if ext != ".png" or not name:
            continue
        clean = re.sub(r"_\d+_[0-9A-F-]{36}$", "", os.path.splitext(name)[0])
        shutil.copy(os.path.join(source, attachment["exportedFileName"]), os.path.join(target, clean + ".png"))
        print(clean)
EOF
  # The flows hold an iPad in landscape left; its screenshots come in the
  # portrait frame, turned a quarter clockwise. Those it takes after turning
  # the iPad to portrait (named so) are upright already.
  if xcrun simctl list devices | grep "$SIM" | grep -q iPad; then
    local shot
    for shot in "$SHOTS"/*.png; do
      [[ "$shot" == *-portrait-* ]] && continue
      sips -r 270 "$shot" >/dev/null || return 1
    done
  fi
}

# Each export carries its preset's steps: a flow that picked the wrong
# control still builds and exports, just not what it says. The s2t flow
# turns phrases off and on again; it must export them on.
check_recipes() {
  python3 -I - "$RUN/exports" <<'EOF'
import json, os, sys
expected = {
    "EbookKai-Medium": ["embolden"],
    "KaiVertical-Regular": ["pseudoVertical"],
    "TradKai-Regular": ["s2t+phrases"],
    "EbookKaiV-Medium": ["embolden", "pseudoVertical"],
    "CTEbook-Medium": ["embolden+widen", "tracking", "lineHeight"],
    "LEbook-ExtraBold": ["embolden"],
    "IEbook-Medium": ["embolden"],
    "MixedKai-Medium": ["replace", "embolden"],
    "CTEbook-Regular": ["embolden"],
    "CTEbook-Italic": ["embolden"],
    "CTEbook-Bold": ["embolden"],
    "CTEbook-BoldItalic": ["embolden"],
}
# The risk review flow (test9zRiskReplace) exports twice: before the decision,
# and after it with 鑭 from 芫荽 after embolden. iOS 26's Files keeps both
# ("… 2"); an exporter that replaces leaves only the second.
borrow_first, borrow_again = "BorrowKai-Medium", "BorrowKai-Medium 2"
if os.path.exists(os.path.join(sys.argv[1], borrow_again + ".json")):
    expected[borrow_first] = ["replace", "embolden"]
else:
    borrow_again = borrow_first
expected[borrow_again] = ["replace", "embolden", "replace"]
# The style set (test9b): RIBBI style names, one weight class up from each
# source, one family, each from its own Crimson Text file.
styles = {
    "CTEbook-Regular": ("Regular", 500, "CrimsonText-Regular.ttf"),
    "CTEbook-Italic": ("Italic", 500, "CrimsonText-Italic.ttf"),
    "CTEbook-Bold": ("Bold", 800, "CrimsonText-Bold.ttf"),
    "CTEbook-BoldItalic": ("Bold Italic", 800, "CrimsonText-BoldItalic.ttf"),
}
# The catalog flow chose Literata's Bold instance: only wght is off its default.
variations = {"LEbook-ExtraBold": {"wght": 700}}
# Downloads carry their license text (a stored upstream OFL.txt); imported files have none.
licensed = {"LEbook-ExtraBold", "IEbook-Medium"}
failed = False
for stem, ops in expected.items():
    path = os.path.join(sys.argv[1], stem + ".json")
    if not os.path.exists(path):
        print(f"FAIL {stem}: not exported")
        failed = True
        continue
    recipe = json.load(open(path))
    got = [step["op"] + ("+phrases" if step.get("phrases") else "") + ("+widen" if step.get("widen") else "") for step in recipe["steps"]]
    print(f"{'PASS' if got == ops else 'FAIL'} {stem}: steps {got}, expected {ops}")
    failed |= got != ops
    variation = recipe["source"].get("variation", {})
    if variation != variations.get(stem, {}):
        print(f"FAIL {stem}: source.variation {variation}, expected {variations.get(stem, {})}")
        failed = True
    if stem == borrow_again and got == ops:
        borrowed = recipe["steps"][2]
        want = (["鑭"], "unitsPerEm", 1, True)
        have = (borrowed.get("characters"), borrowed.get("match"), borrowed.get("size"),
                borrowed["font"]["file"].lower().startswith("iansui"))
        print(f"{'PASS' if have == want else 'FAIL'} {stem}: borrowed step {have}, expected {want}")
        failed |= have != want
    if stem in styles:
        output = recipe["output"]
        got_style = (output.get("styleName"), output.get("weightClass"), recipe["source"]["file"], output["familyName"])
        want = styles[stem] + ("CT Ebook",)
        print(f"{'PASS' if got_style == want else 'FAIL'} {stem}: style {got_style}, expected {want}")
        failed |= got_style != want
    license = os.path.join(sys.argv[1], stem + "-OFL.txt")
    has = os.path.exists(license) and "OPEN FONT LICENSE" in open(license, encoding="utf-8", errors="replace").read().upper()
    if has != (stem in licensed):
        print(f"FAIL {stem}: OFL text beside it {has}, expected {stem in licensed}")
        failed = True
    elif has:
        print(f"PASS {stem}: {stem}-OFL.txt holds the OFL")
sys.exit(1 if failed else 0)
EOF
}

# What the app wrote to Files, and its persisted settings.
collect_exports() {
  local storage data file
  storage=$(files_storage) || return 1
  for file in "$storage"/*.ttf "$storage"/*.json "$storage"/*.txt; do
    # The source fonts prepare() put there are not exports.
    case "$(basename "$file")" in GuanKiapTsingKhai.ttf | CrimsonText-*.ttf) continue ;; esac
    [[ -f "$file" ]] && cp "$file" "$RUN/exports/"
  done
  ls -la "$RUN/exports"
  shasum -a 256 "$RUN"/exports/*
  data=$(xcrun simctl get_app_container "$SIM" app.fontsmaker.FontsMaker data) || return 1
  plutil -p "$data/Library/Preferences/app.fontsmaker.FontsMaker.plist" | tee "$RUN/preferences.txt"
}

run prepare prepare || exit 1
run xcodegen xcodegen generate --spec App/project.yml || exit 1
run flows flows
run collect-shots collect_shots
run collect-exports collect_exports
if [[ -z "$ONLY" ]]; then
  run check-recipes check_recipes
else
  # The recipes come from the flows that export; a partial run has not all of them.
  echo "check-recipes            NOT RUN (only: $ONLY)"
fi
failed=0
for code in "${codes[@]}"; do ((code == 0)) || failed=$((failed + 1)); done
echo "$((${#names[@]} - failed))/${#names[@]} steps passed; logs in $RUN, shots in $SHOTS"
((failed == 0))
