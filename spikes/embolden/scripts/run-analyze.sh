#!/usr/bin/env bash
# Phase 0 analysis: fontTools cross-checks, full-font metrics per join variant,
# report (stats, grades, worst lists), then contact sheets built from the lists.
# Cheap (~1 min); safe to rerun. No `set -e`: each step records its exit code.
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(dirname "$HERE")"
FIX="$HOME/Library/Caches/FontsMaker/fixtures"
OUT="${OUT:-$HOME/git/FontsMaker/artifacts/phase0}"
BIN="$PKG/.build/release/embolden-spike"
SRC="$FIX/GuanKiapTsingKhai.ttf"
REF="$FIX/BailuKai-Medium.ttf"
LXR="$FIX/LXGWWenKaiTC-Regular.ttf"
LXM="$FIX/LXGWWenKaiTC-Medium.ttf"
mkdir -p "$OUT/logs" "$OUT/csv" "$OUT/lists" "$OUT/sheets"
STATUS="$OUT/logs/analyze-status.txt"
: >"$STATUS"
# Sheets paginate, so a shorter list would leave stale -pN pages behind.
rm -f "$OUT/sheets/"*.png

step() {
  local name="$1"; shift
  local t0=$SECONDS
  "$@" >"$OUT/logs/$name.log" 2>&1
  local code=$?
  printf '%-36s exit=%-3s %4ss\n' "$name" "$code" "$((SECONDS - t0))" | tee -a "$STATUS"
}

for f in "$SRC" "$REF" "$LXR" "$LXM"; do
  [ -f "$f" ] || { echo "missing fixture $f — run scripts/fetch-fixtures.sh" | tee -a "$STATUS"; exit 1; }
done

step 01-build swift build -c release --package-path "$PKG"
step 03-probe-reference python3 -I "$HERE/probe_reference.py" "$SRC" "$REF" "$OUT"
step 04-probe-injected python3 -I "$HERE/probe_injected.py" "$REF" "$LXM" "$OUT/lists/bailu-injected-from-lxgw.tsv"

for v in "miter 4 miter4" "miter 2 miter2" "miter 10 miter10" "round 4 round"; do
  set -- $v
  step "10-analyze-guan-$3" "$BIN" analyze --font "$SRC" --ref "$REF" --join "$1" --miter-limit "$2" --out "$OUT/csv/guan-$3.csv"
done
for v in "miter 4 miter4" "round 4 round"; do
  set -- $v
  step "30-analyze-lxgw-$3" "$BIN" analyze --font "$LXR" --join "$1" --miter-limit "$2" --out "$OUT/csv/lxgw-$3.csv"
done

step 40-report python3 -I "$HERE/report.py" "$OUT"

FRAGILE="傳導育鬱齉龘驫靈鷹讀體藝爨籲帳熱繁聯鬢萇倀長張囊疆響攀爵襲籌鑿鸞蠻廳顯驗鑰龜齒蠶灣戀豔"
COMMON="的一是不了人我在有他這中大來上個到說們為子和你地出道也時年永國書會對學經開發還進動樣點實機現頭種東過間麼問關電線黑業當聽寫意想愛風雲雨雪山水火木金土日月星心手口目耳門馬魚鳥龍"
LATIN="AaBbGgQq@&0123R5w]"
PUNCT="。，、「」『』（）：；！？…—"
step 50-sheet-representative "$BIN" sheet --font "$SRC" --ref "$REF" --chars "$FRAGILE$COMMON$LATIN$PUNCT" \
  --per-page 48 --title "GuanKiapTsingKhai, weight 12: representative glyphs" --out "$OUT/sheets/representative"
OVERLAY="永傳鬱龘國的書讀體藝靈鷹我說愛風心水AgQ&。「"
step 51-overlay-miter4 "$BIN" overlay --font "$SRC" --ref "$REF" --join miter --miter-limit 4 --chars "$OVERLAY" \
  --title "Overlay: ours miter4 (red) on BailuKai (gray)" --out "$OUT/sheets/overlay-miter4"
step 52-overlay-round "$BIN" overlay --font "$SRC" --ref "$REF" --join round --chars "$OVERLAY" \
  --title "Overlay: ours round (red) on BailuKai (gray)" --out "$OUT/sheets/overlay-round"
step 53-sheet-worst-holes "$BIN" sheet --font "$SRC" --ref "$REF" --list "$OUT/lists/worst-holes.tsv" --per-page 60 \
  --title "60 worst by surviving counter-area ratio (miter4)" --out "$OUT/sheets/worst-holes"
step 54-sheet-worst-contours "$BIN" sheet --font "$SRC" --ref "$REF" --list "$OUT/lists/worst-contours.tsv" --per-page 60 \
  --title "30 largest contourDelta (miter4)" --out "$OUT/sheets/worst-contours"
step 55-sheet-grade-a "$BIN" sheet --font "$SRC" --ref "$REF" --list "$OUT/lists/grade-a.tsv" --per-page 60 \
  --title "Proposed grade A (miter4)" --out "$OUT/sheets/grade-a"
step 56-sheet-bailu-fixed "$BIN" sheet --font "$SRC" --ref "$REF" --list "$OUT/lists/bailu-fixed.tsv" --per-page 60 \
  --title "Glyphs BailuKai replaced with LXGW Medium (4th column = that copy)" --out "$OUT/sheets/bailu-fixed"
step 57-overlay-bailu-fixed "$BIN" overlay --font "$SRC" --ref "$REF" --join miter --miter-limit 4 --chars "傳導育帳熱繁聯鬢萇倀長" \
  --title "Overlay on BailuKai's replacement glyphs (gray = LXGW Medium copy, except 萇倀長)" --out "$OUT/sheets/overlay-bailu-fixed"
for g in b c; do
  step "55-sheet-grade-$g-sample" "$BIN" sheet --font "$SRC" --ref "$REF" --list "$OUT/lists/grade-$g-sample.tsv" --per-page 60 \
    --title "Proposed grade $(echo $g | tr bc BC): 60 evenly spaced samples (miter4)" --out "$OUT/sheets/grade-$g-sample"
done
step 59-zoom-defects "$BIN" overlay --font "$SRC" --ref "$REF" --join miter --miter-limit 4 --chars "鈗♴器劉" --cell 900 --groups 2 \
  --title "Zoom: source sliver closed (鈗 ♴) and pinholes (器 劉), ours miter4" --out "$OUT/sheets/zoom-defects"
step 59-zoom-pinhole "$BIN" overlay --font "$SRC" --ref "$REF" --join miter --miter-limit 4 --chars "器" --window 560,480,100 --cell 600 --groups 1 \
  --title "Zoom: pinhole in 器 (new 86 u2 counter) — BailuKai has it too" --out "$OUT/sheets/zoom-pinhole"
step 59-zoom-corner-A "$BIN" overlay --font "$SRC" --ref "$REF" --join miter --miter-limit 4 --compare-join round --chars "A" \
  --window 265,600,170 --cell 700 --groups 1 --title "Zoom: A apex — miter4 (red) vs round (green) vs BailuKai (gray)" --out "$OUT/sheets/zoom-corner-A"
step 59-zoom-sharp-tips "$BIN" overlay --font "$SRC" --ref "$REF" --join miter --miter-limit 4 --compare-join round --chars "★➡疯" \
  --cell 620 --groups 3 --title "Sharp tips: miter4 (red) vs round (green) vs BailuKai (gray)" --out "$OUT/sheets/zoom-sharp-tips"
printf '24775\tminute.italic #24775\n635\tʽ uni02BD #635\n15283\t螵 #15283\n8384\t戋 #8384\n' >"$OUT/lists/zoom-low-iou.tsv"
step 59-zoom-low-iou "$BIN" overlay --font "$SRC" --ref "$REF" --join miter --miter-limit 4 --list "$OUT/lists/zoom-low-iou.tsv" \
  --cell 600 --groups 4 --title "Low-IoU cases: ours miter4 (red) vs BailuKai (gray)" --out "$OUT/sheets/zoom-low-iou"
step 58-sheet-low-iou "$BIN" sheet --font "$SRC" --ref "$REF" --list "$OUT/lists/low-iou.tsv" --per-page 60 \
  --title "IoU(ours miter4, BailuKai) < 0.95, LXGW copies excluded" --out "$OUT/sheets/low-iou"
LXCHARS="永傳導育鬱齉龘驫靈鷹讀體藝爨籲的一是不了人我在有他這中大來國書AaGg@&。，「」（）"
step 60-sheet-lxgw "$BIN" sheet --font "$LXR" --ref "$LXM" --ref-by char --ref-label "LXGW TC Medium (designer)" \
  --chars "$LXCHARS" --per-page 48 --title "LXGW WenKai TC Regular, weight 12" --out "$OUT/sheets/lxgw"
step 61-sheet-lxgw-grade-a "$BIN" sheet --font "$LXR" --ref "$LXM" --ref-by char --ref-label "LXGW TC Medium (designer)" \
  --list "$OUT/lists/lxgw-grade-a.tsv" --per-page 60 --title "LXGW WenKai TC Regular: proposed grade A (miter4)" --out "$OUT/sheets/lxgw-grade-a"

echo "---- summary ($STATUS)"
cat "$STATUS"
