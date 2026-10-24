#!/usr/bin/env bash
# Downloads the spike's untrusted inputs, one directory per source, and records
# URL + sha256 in a manifest so every number in the write-up can be traced back
# to exact bytes. Nothing here is committed: corpora and fonts stay in the cache.
#
# Usage: bash spikes/s2t-phrases/fetch.sh
# Env:   SPIKE_CACHE (default ~/Library/Caches/FontsMaker/spike-s2t-phrases)
#        SPIKE_OUT   (default /Users/ricky/git/FontsMaker/artifacts/s2t-phrases)
set -u

CACHE="${SPIKE_CACHE:-$HOME/Library/Caches/FontsMaker/spike-s2t-phrases}"
OUT="${SPIKE_OUT:-/Users/ricky/git/FontsMaker/artifacts/s2t-phrases}"
mkdir -p "$CACHE" "$OUT"
MANIFEST="$OUT/downloads.tsv"
printf 'dir\tfile\tsha256\turl\n' >"$MANIFEST.tmp"

OPENCC_COMMIT=025f371dc76b598d77384fbdab90c937471844d8
OPENCC_RAW="https://raw.githubusercontent.com/BYVoid/OpenCC/$OPENCC_COMMIT"
GUANKIAP_RELEASE="https://github.com/tonyhuan/GuanKiapTsingKhai/releases/download/V1.20"

failed=0
# fetch <dir> <url> [file name]: downloads once, then only re-hashes.
fetch() {
  local dir="$CACHE/$1" url="$2" name="${3:-${2##*/}}"
  mkdir -p "$dir"
  if [[ ! -s "$dir/$name" ]]; then
    # The SIGHAN server drops long transfers: keep the partial file and resume.
    local ok=0 attempt
    for attempt in 1 2 3 4 5 6; do
      if curl -fsSL -C - -o "$dir/$name.part" "$url"; then ok=1; break; fi
    done
    if [[ $ok != 1 ]]; then
      echo "FAIL  $1/$name ($url)"; failed=1; return
    fi
    mv -f "$dir/$name.part" "$dir/$name"
    echo "got   $1/$name"
  else
    echo "have  $1/$name"
  fi
  printf '%s\t%s\t%s\t%s\n' "$1" "$name" "$(shasum -a 256 "$dir/$name" | cut -d' ' -f1)" "$url" >>"$MANIFEST.tmp"
}

# OpenCC at the commit our bundled STCharacters/TWVariants come from: the
# dictionaries the rules are generated from, the configs the oracle mirrors,
# the generator of STPhrases_GeneratedFromRegionalPhrases, the segmentation and
# conversion sources (to pin matching semantics), and the official test cases.
for path in \
  data/config/s2t.json data/config/s2tw.json \
  data/dictionary/STPhrases.txt data/dictionary/STCharacters.txt \
  data/dictionary/TWVariants.txt data/dictionary/TWVariantsPhrases.txt \
  data/dictionary/TWPhrases.txt data/dictionary/HKPhrases.txt \
  data/dictionary/HKVariants.txt data/dictionary/HKVariantsPhrases.txt \
  data/dictionary/CJK_Compatibility_Ideographs.txt \
  data/dictionary/BUILD.bazel data/CMakeLists.txt \
  data/scripts/generate_st_phrases_from_regional_phrases.py data/scripts/common.py \
  src/MaxMatchSegmentation.cpp src/Conversion.cpp src/ConversionChain.cpp \
  src/DictGroup.cpp src/DictGroup.hpp src/Config.cpp src/Converter.cpp \
  test/testcases/testcases.json; do
  fetch opencc-025f371 "$OPENCC_RAW/$path" "$(echo "$path" | tr '/' '_')"
done

# Natural text. Gutenberg's Chinese books are traditional: 吶喊 (Lu Xun, 1923,
# public domain) is the traditional side-effect corpus.
fetch gutenberg-27166 "https://www.gutenberg.org/cache/epub/27166/pg27166.txt"
# Simplified: 呐喊 from a mainland edition (same stories as the Gutenberg file),
# and SIGHAN 2005 bakeoff test sets (PKU, MSR): modern news text written in
# simplified, one sentence per line.
fetch nahan-simplified \
  "https://raw.githubusercontent.com/BlankRain/ebooks/master/%E5%91%90%E5%96%8A-%E9%B2%81%E8%BF%85-TXT%E5%B0%8F%E8%AF%B4%E5%A4%A9%E5%A0%82.txt" \
  nahan.txt
fetch sighan2005 "http://sighan.cs.uchicago.edu/bakeoff2005/data/icwb2-data.zip"
# Modern traditional text for side effects (question 4): UD_Chinese-GSD, Wikipedia
# sentences in traditional script (r2.16 = commit a7cb427). The Gutenberg 吶喊
# alone would only show 1920s wording and its own conversion artifacts.
UD_GSD="https://raw.githubusercontent.com/UniversalDependencies/UD_Chinese-GSD/a7cb4270c8ea437d7f2cd7978b0dcc0941cb7266"
for part in train dev test; do
  fetch ud-chinese-gsd "$UD_GSD/zh_gsd-ud-$part.conllu"
done

# Prior art: GuanKiapTsingKhai's word-level variants (V1.20, same release as
# the fixtures).
fetch guankiap-w "$GUANKIAP_RELEASE/GuanKiapTsingKhai-W.ttf"
fetch guankiap-tw "$GUANKIAP_RELEASE/GuanKiapTsingKhai-TW.ttf"

# The zip is untrusted: extract only the two raw test files, by exact name,
# into their own directory.
SIG="$CACHE/sighan2005"
if [[ -s "$SIG/icwb2-data.zip" && ! -s "$SIG/extracted/pku_test.utf8" ]]; then
  mkdir -p "$SIG/extracted"
  unzip -o -j -q "$SIG/icwb2-data.zip" icwb2-data/testing/pku_test.utf8 icwb2-data/testing/msr_test.utf8 \
    -d "$SIG/extracted" || { echo "FAIL  unzip sighan"; failed=1; }
fi
for f in pku_test.utf8 msr_test.utf8; do
  [[ -s "$SIG/extracted/$f" ]] && printf 'sighan2005/extracted\t%s\t%s\t%s\n' "$f" \
    "$(shasum -a 256 "$SIG/extracted/$f" | cut -d' ' -f1)" "icwb2-data.zip:icwb2-data/testing/$f" >>"$MANIFEST.tmp"
done

mv -f "$MANIFEST.tmp" "$MANIFEST"
echo "manifest: $MANIFEST"
exit $failed
