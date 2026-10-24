#!/usr/bin/env bash
# Downloads OpenCC files of the commit the bundled dictionaries come from
# (Sources/FontsMakerKit/Resources/OpenCC/SOURCE.txt) into a shared cache,
# pinned by sha256: the inputs that regenerate the regional-phrase dictionary
# (scripts/opencc_regional_phrases.py), the oracle's configs and OpenCC's own
# test cases. Nothing here is committed except what SOURCE.txt lists.
set -u

COMMIT=025f371dc76b598d77384fbdab90c937471844d8
DEST="${FONTSMAKER_OPENCC:-$HOME/Library/Caches/FontsMaker/opencc-$COMMIT}"
RAW="https://raw.githubusercontent.com/BYVoid/OpenCC/$COMMIT"
mkdir -p "$DEST"

FILES=(
  "STPhrases.txt|f6eab5e5c6dd7640597878d3dfc6599ee1279d2bc91561eadd8e114194e2925a|data/dictionary/STPhrases.txt"
  "STCharacters.txt|a0ca1601c70648cf48b33c3c6210ccbecc5c7eead4b4c3daf76587ba2c03582b|data/dictionary/STCharacters.txt"
  "TWVariants.txt|e187278e119c427ca561180ac5da5b20e9f8681190458f35c327ce499e95a6a5|data/dictionary/TWVariants.txt"
  "TWVariantsPhrases.txt|36df033675a2e9152927fa8419f0732a061cb4909c5060f25a5cfc9b08ffff06|data/dictionary/TWVariantsPhrases.txt"
  "HKPhrases.txt|de3ed57532c9e57e73998f696ec8afe49307b44aa01a8342aa9ae6ed1f6dd9da|data/dictionary/HKPhrases.txt"
  "TWPhrases.txt|bcb435b744ee3e522beb9b18fcc5486a36ed4763c6aa642ce18112fb5d604e31|data/dictionary/TWPhrases.txt"
  "TSCharacters.txt|737c21c66f55a419dd6956cb3089476cdefc5a36877452631617696df1e5d925|data/dictionary/TSCharacters.txt"
  "TSPhrases.txt|362fa1b9a7d6edd04b462a32e12c9fef3adae822ab1dee9c83561cc37c06cb1f|data/dictionary/TSPhrases.txt"
  "CJK_Compatibility_Ideographs.txt|663cc10b7de7c7cee3ff9df1ee963977d6c26c00b23f8fe670fab481283ed4f9|data/dictionary/CJK_Compatibility_Ideographs.txt"
  "t2s.json|96fe5cc374a80ccc49e3370006cce3aefe4af955868ae0b14fb3079ec695be4f|data/config/t2s.json"
  "s2t.json|a188392af5ca23e1d602c5a93651f1d852fccdaa24c2b29abed7a0c8ac359048|data/config/s2t.json"
  "s2tw.json|5830ee3440ba3dc6bf1e197205b4248e2d860b8a3680475db4419b0dbf96ac39|data/config/s2tw.json"
  "testcases.json|3f8273c5f432090ec1a8a01bd4d545046ad5a28e69eb41a081c5e3e54d3e402b|test/testcases/testcases.json"
  "LICENSE|b534e465949558eec2597b04f5092b5e161236a68dfbfd04d547592ac3964308|LICENSE"
)

failed=0
for entry in "${FILES[@]}"; do
  IFS='|' read -r name sha path <<<"$entry"
  target="$DEST/$name"
  if [[ -f "$target" ]] && [[ "$(shasum -a 256 "$target" | cut -d' ' -f1)" == "$sha" ]]; then
    echo "ok       $name"
    continue
  fi
  tmp="$target.part"
  if ! curl -fsSL -o "$tmp" "$RAW/$path"; then
    echo "FAIL     $name (download)"; rm -f "$tmp"; failed=1; continue
  fi
  actual="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"
  if [[ "$actual" != "$sha" ]]; then
    echo "FAIL     $name (sha256 $actual != $sha)"; rm -f "$tmp"; failed=1; continue
  fi
  mv -f "$tmp" "$target"
  echo "fetched  $name"
done

echo "opencc $COMMIT: $DEST"
exit $failed
