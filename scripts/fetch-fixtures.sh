#!/usr/bin/env bash
# Downloads pinned reference fonts into a shared, read-only cache.
# The cache lives outside the repo so every worktree reuses one copy (~100 MB)
# instead of re-downloading; sha256 pins keep test results reproducible.
set -u

DEST="${FONTSMAKER_FIXTURES:-$HOME/Library/Caches/FontsMaker/fixtures}"
mkdir -p "$DEST"

FIXTURES=(
  "GuanKiapTsingKhai.ttf|758632243c499e431fd0c847f5e8c431acf59a9b41a26237a819466139994d38|https://github.com/tonyhuan/GuanKiapTsingKhai/releases/download/V1.20/GuanKiapTsingKhai.ttf"
  "GuanKiapTsingKhai-90.ttf|47c3b4afbf137bfc13484db790464eccc792833d83db3cda6d7c1abff9a53521|https://github.com/tonyhuan/GuanKiapTsingKhai/releases/download/V1.20/GuanKiapTsingKhai-90.ttf"
  "GuanKiapTsingKhai-T.ttf|69465751acbd3deed8f1123f39c8e297bd86779246b45c5efdb52d3b2061d072|https://github.com/tonyhuan/GuanKiapTsingKhai/releases/download/V1.20/GuanKiapTsingKhai-T.ttf"
  "BailuKai-Medium.ttf|c4ac77906015f8a862b2b7b074fd6e3e6b203e55fad0f9b2a57cdb43ca71db7b|https://github.com/huthief/BailuKai/releases/download/20261012/BailuKai-Medium.ttf"
  "BailuKai-Medium-90.ttf|341f6c40bab8c007b802b1a3497c6731b42500d66b63df15dd6c829aa1d2cc8d|https://github.com/huthief/BailuKai/releases/download/20261012/BailuKai-Medium-90.ttf"
  "LXGWWenKaiTC-Regular.ttf|b1a0795862c1415bf3f393ea50b2a4ea6275012cf5bad3f94feeb1222f555731|https://github.com/lxgw/LxgwWenkaiTC/releases/download/v1.522/LXGWWenKaiTC-Regular.ttf"
  "LXGWWenKaiTC-Medium.ttf|94ca2870022fb8e4f90e2887524603690598142d17b620dfae318f1818ba8e17|https://github.com/lxgw/LxgwWenkaiTC/releases/download/v1.522/LXGWWenKaiTC-Medium.ttf"
  # Import normalization (Phase 4a): one design as CFF, static TrueType and variable.
  "ZhudouSans-Regular.otf|fdf92981a2f1ab323a1ca37f48dbf87a8a1f6c9ba24ef262947e2e6a3280713b|https://raw.githubusercontent.com/Buernia/Zhudou-Sans/61f340baca1511a7e82f6220afc16e6c119d023f/fonts/otf/ZhudouSans-Regular.otf"
  "ZhudouSans-Regular.ttf|7cc959633c72fc3304840462b64c649da7952e607747d2fc40e892441d271e55|https://raw.githubusercontent.com/Buernia/Zhudou-Sans/61f340baca1511a7e82f6220afc16e6c119d023f/fonts/ttf/ZhudouSans-Regular.ttf"
  "ZhudouSansVF.ttf|2318e2742b02f15af24d41eb259ce8b97535166b8d6e1ef07aa36f8b03432dc7|https://raw.githubusercontent.com/Buernia/Zhudou-Sans/61f340baca1511a7e82f6220afc16e6c119d023f/fonts/variable/ZhudouSansVF.ttf"
  # Variable fonts with opsz and avar.
  "Literata-VF.ttf|b41138c9373112f32abb589cc22e8674b06ed4048b0c513be922bdd26f274440|https://raw.githubusercontent.com/google/fonts/4e5f06dbb274a27ebe71ed54ea706b3ee40eabd9/ofl/literata/Literata%5Bopsz,wght%5D.ttf"
  "Inter-VF.ttf|29160a80ff49ddcab2c97711247e08b1fab27a484a329ce8b813d820dc559031|https://raw.githubusercontent.com/google/fonts/0b58fb370093f9a9f4ff785d94405710b79de67c/ofl/inter/Inter%5Bopsz,wght%5D.ttf"
  # English reading tuning (Phase 4c): a static, hinted, kerned OFL text face
  # with all four styles, the style-linked family a reader's bold and italic use.
  "CrimsonText-Regular.ttf|48e6c5d5ad1d01599d374ecb817e15890d1feb3b8a3a88e527d44c90389e1f06|https://raw.githubusercontent.com/google/fonts/7380f7cebbf2250460c23fd301b51bcbab162edf/ofl/crimsontext/CrimsonText-Regular.ttf"
  "CrimsonText-Italic.ttf|4ed1699ac7c64e8b3d33f6bb8323c3d7206b0d7bacb9ee2d65c697e6014d29de|https://raw.githubusercontent.com/google/fonts/7380f7cebbf2250460c23fd301b51bcbab162edf/ofl/crimsontext/CrimsonText-Italic.ttf"
  "CrimsonText-Bold.ttf|a3a0765fc5e8d0b49b540a23aefe0184887dd79f06a0bdf4db7035cea6befa93|https://raw.githubusercontent.com/google/fonts/7380f7cebbf2250460c23fd301b51bcbab162edf/ofl/crimsontext/CrimsonText-Bold.ttf"
  "CrimsonText-BoldItalic.ttf|467013e913e46304760461c46661c994b2aa1769e3fbd31371026300315181b4|https://raw.githubusercontent.com/google/fonts/7380f7cebbf2250460c23fd301b51bcbab162edf/ofl/crimsontext/CrimsonText-BoldItalic.ttf"
  # A static monospaced OFL face (every advance 600, post.isFixedPitch 1) with
  # GPOS mark anchors: widen must keep it monospaced and move the anchors.
  "JetBrainsMono-Regular.ttf|a0bf60ef0f83c5ed4d7a75d45838548b1f6873372dfac88f71804491898d138f|https://raw.githubusercontent.com/JetBrains/JetBrainsMono/cd5227bd1f61dff3bbd6c814ceaf7ffd95e947d9/fonts/ttf/JetBrainsMono-Regular.ttf"
)

# Fonts published only inside a zip: name|sha256|zip URL|zip sha256|member.
# Large CJK CFF (cmap beyond the old format 4 limit) and a CJK collection.
ARCHIVED=(
  "GenSenRounded2TC-R.otf|86b50c3309e232bf51e11c75dbd2f3b37f1efef7e1c02ed221e1d3387d6c38f1|https://github.com/ButTaiwan/gensen-font/releases/download/v2.100/GenSenRounded2TC-otf.zip|34637f2c3e003c7fb899333de5522c26bd6be8c4ad9e5cf1b8a26bea56cb4320|GenSenRounded2TC-R.otf"
  "GenSenRounded2-R.ttc|34ec5dbacd7f2b8dd14569cf4a41d0eeaf2bdaede45087bf51919857a26528a2|https://github.com/ButTaiwan/gensen-font/releases/download/v2.100/GenSenRounded2-ttc.zip|01f57ff5eac25143c654cfd37ab06d191703fb67aea94811ec48f101a2f6e203|GenSenRounded2-R.ttc"
  # Traditional-only CJK (no 简, 这, 发): s2t must add the simplified code points (Phase 4d).
  "Iansui-Regular.ttf|7f1aa62e9dcbf40d0ce41a5d3f1e5ea602e66c295778ac6fefb6b84d8ed08bd5|https://github.com/ButTaiwan/iansui/releases/download/v1.020/iansui.zip|28d58aef9b7a21c137945a4fd14138d6284a8573c0c1b123f6e5b708423348a6|Iansui-Regular.ttf"
)

sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

failed=0
for entry in "${FIXTURES[@]}"; do
  IFS='|' read -r name sha url <<<"$entry"
  path="$DEST/$name"
  if [[ -f "$path" ]] && [[ "$(shasum -a 256 "$path" | cut -d' ' -f1)" == "$sha" ]]; then
    echo "ok       $name"
    continue
  fi
  tmp="$path.part"
  if ! curl -fsSL -o "$tmp" "$url"; then
    echo "FAIL     $name (download)"; rm -f "$tmp"; failed=1; continue
  fi
  actual="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"
  if [[ "$actual" != "$sha" ]]; then
    echo "FAIL     $name (sha256 $actual != $sha)"; rm -f "$tmp"; failed=1; continue
  fi
  mv -f "$tmp" "$path"
  echo "fetched  $name"
done

for entry in "${ARCHIVED[@]}"; do
  IFS='|' read -r name sha url zipsha member <<<"$entry"
  path="$DEST/$name"
  if [[ -f "$path" ]] && [[ "$(sha_of "$path")" == "$sha" ]]; then
    echo "ok       $name"
    continue
  fi
  zip="$DEST/$name.zip.part"
  if ! curl -fsSL -o "$zip" "$url"; then
    echo "FAIL     $name (download)"; rm -f "$zip"; failed=1; continue
  fi
  actual="$(sha_of "$zip")"
  if [[ "$actual" != "$zipsha" ]]; then
    echo "FAIL     $name (zip sha256 $actual != $zipsha)"; rm -f "$zip"; failed=1; continue
  fi
  # -p streams the one member, so archive paths never touch the file system.
  tmp="$path.part"
  if ! unzip -p "$zip" "$member" >"$tmp"; then
    echo "FAIL     $name (unzip)"; rm -f "$zip" "$tmp"; failed=1; continue
  fi
  rm -f "$zip"
  actual="$(sha_of "$tmp")"
  if [[ "$actual" != "$sha" ]]; then
    echo "FAIL     $name (sha256 $actual != $sha)"; rm -f "$tmp"; failed=1; continue
  fi
  mv -f "$tmp" "$path"
  echo "fetched  $name"
done

echo "fixtures: $DEST"
exit $failed
