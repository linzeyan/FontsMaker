#!/usr/bin/env bash
# Device benchmark (plan, Phase 3b): full builds of the four bundled presets
# on a real iPhone, Release build, three runs each; and the derivation of the
# s2t preset's phrase rules the live preview waits for (s2t-converter). One
# test process per preset, so the kernel's lifetime peak footprint belongs to
# that preset.
# Writes the raw xcodebuild logs, the BENCH lines and table.md to $OUT.
#
#   DEVELOPMENT_TEAM=<team id> scripts/ios-bench.sh <device udid>
#
# The team goes on the xcodebuild command line only, never into the project.
# ALLOW_PROVISIONING=1 adds -allowProvisioningUpdates, which lets Xcode
# register the device with the team and refresh its profile. A simulator UDID
# runs the same harness without signing; its numbers are the Mac's, not a
# device benchmark, and the table says so.
#
# Every step logs to $OUT/NN-name.log with its exit code; no `set -e`.
set -u

UDID=${1:?usage: DEVELOPMENT_TEAM=<team> scripts/ios-bench.sh <device-udid>}
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN="$(cd "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
# One directory per device: the run starts by clearing $OUT, and another
# phone's results or notes must survive it.
OUT="${FONTSMAKER_BENCH_OUT:-$MAIN/artifacts/phase3b/bench/$UDID}"
# Its own DerivedData when another xcodebuild is using the project's.
DERIVED="${FONTSMAKER_DERIVED:-$REPO/App/DerivedData}"
PRESETS=(ebookBold:ebook-bold pseudoVertical:pseudo-vertical s2t:s2t boldPseudoVertical:bold-pseudo-vertical
  s2tConverter:s2t-converter)
rm -rf "$OUT"
mkdir -p "$OUT"
cd "$REPO" || exit 1

names=()
codes=()
run() {
  local name=$1
  shift
  local log
  log="$OUT/$(printf '%02d' $((${#names[@]} + 1)))-$name.log"
  echo "\$ $*" >"$log"
  "$@" >>"$log" 2>&1
  local code=$?
  names+=("$name")
  codes+=("$code")
  printf '%-28s %s\n' "$name" "$([[ $code == 0 ]] && echo PASS || echo "FAIL (exit $code)  $log")"
  return $code
}

simulator=0
if xcrun simctl list devices | grep -q "$UDID"; then simulator=1; fi

# Device facts for the table; a locked phone or Developer Mode off stops here.
device_facts() {
  if ((simulator)); then
    xcrun simctl list devices | grep "$UDID"
    return 0
  fi
  local json="$OUT/devices.json"
  xcrun devicectl list devices --json-output "$json" >/dev/null || return 1
  python3 -I - "$json" "$UDID" <<'EOF'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
device = next((d for d in devices if d.get("hardwareProperties", {}).get("udid") == sys.argv[2]), None)
if device is None:
    sys.exit(f"device {sys.argv[2]} not found")
hw, props = device["hardwareProperties"], device["deviceProperties"]
print(f"device: {hw.get('marketingName')} ({hw.get('productType')}), iOS {props.get('osVersionNumber')} ({props.get('osBuildUpdate')})")
mode = props.get("developerModeStatus")
print(f"developer mode: {mode}")
if mode != "enabled":
    sys.exit("Developer Mode is off: Settings > Privacy & Security > Developer Mode, then restart the phone.")
EOF
  local state
  state=$(xcrun devicectl device info lockState --device "$UDID" 2>&1)
  echo "$state"
  if ! grep -qiE 'passcodeRequired: *false|unlocked' <<<"$state"; then
    echo "The phone is locked: unlock it and set Auto-Lock to Never for the run."
    return 1
  fi
}

xcode() {
  xcodebuild -project App/FontsMaker.xcodeproj -derivedDataPath "$DERIVED" -scheme FontsMakerBench \
    -destination "id=$UDID" "$@"
}

signing=()
if ((!simulator)); then
  if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
    echo "DEVELOPMENT_TEAM is not set" >&2
    exit 2
  fi
  signing=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
  [[ "${ALLOW_PROVISIONING:-0}" == 1 ]] && signing+=(-allowProvisioningUpdates)
fi

# A filter that matches nothing runs zero tests and still exits 0, so the
# preset's own result line is what counts.
bench_one() {
  local test=$1 preset=$2 tmp code
  tmp=$(mktemp)
  xcode "${signing[@]}" test-without-building "-only-testing:FontsMakerBench/BuildBenchmark/$test()" >"$tmp" 2>&1
  code=$?
  cat "$tmp"
  if ! grep -q "BENCH preset=$preset lifetimePeakMB=" "$tmp"; then
    echo "VERIFY: no result line for $preset"
    code=1
  fi
  rm -f "$tmp"
  return $code
}

run device-facts device_facts || exit 1
run xcodegen xcodegen generate --spec App/project.yml || exit 1
run build-for-testing xcode "${signing[@]}" build-for-testing || exit 1
for entry in "${PRESETS[@]}"; do
  run "bench-${entry#*:}" bench_one "${entry%%:*}" "${entry#*:}"
done

# xcodebuild may echo a test's output more than once; each line is unique by run.
grep -ho 'BENCH preset=.*' "$OUT"/*-bench-*.log | sort -u >"$OUT/bench-lines.txt"
python3 -I - "$OUT/bench-lines.txt" "$OUT/01-device-facts.log" "$simulator" >"$OUT/table.md" <<'EOF'
import re, statistics, sys
lines = open(sys.argv[1]).read().splitlines()
facts = [l for l in open(sys.argv[2]).read().splitlines() if l.startswith(("device:", "developer"))]
simulator = sys.argv[3] == "1"
runs, peaks, before = {}, {}, {}
for line in lines:
    fields = dict(f.split("=", 1) for f in line.split()[1:])
    preset = fields["preset"]
    if "run" in fields:
        runs.setdefault(preset, []).append((float(fields["seconds"]), float(fields["sampledPeakMB"])))
    elif "lifetimePeakMB" in fields:
        peaks[preset] = float(fields["lifetimePeakMB"])
    elif "before" in fields:
        before[preset] = (fields["before"], fields.get("cores"))
if simulator:
    print("**iOS Simulator: these are the Mac's numbers, not a device benchmark.**\n")
print("\n".join(facts) + "\n")
print("| preset | runs (s) | median (s) | peak phys_footprint, sampled (MB) | process lifetime peak (MB) | footprint before (MB) |")
print("|---|---|---|---|---|---|")
for preset in ["ebook-bold", "pseudo-vertical", "s2t", "bold-pseudo-vertical", "s2t-converter"]:
    r = runs.get(preset, [])
    if not r:
        print(f"| {preset} | no result | | | | |")
        continue
    times = ", ".join(f"{t:.2f}" for t, _ in r)
    print(f"| {preset} | {times} | {statistics.median(t for t, _ in r):.2f} | {max(p for _, p in r):.0f} | {peaks.get(preset, float('nan')):.0f} | {before.get(preset, ('?',))[0]} |")
EOF
echo
cat "$OUT/table.md"
failed=0
for code in "${codes[@]}"; do ((code == 0)) || failed=$((failed + 1)); done
echo "$((${#names[@]} - failed))/${#names[@]} steps passed; logs in $OUT"
((failed == 0))
