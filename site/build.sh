#!/bin/sh
# Assembles the website into one folder: the page, plus the fonts, the painting and the
# README pictures it shares with the app, so none of them is kept twice in git.
#   site/build.sh OUT_DIR
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:?usage: site/build.sh OUT_DIR}
rm -rf "$OUT"
mkdir -p "$OUT/assets/fonts" "$OUT/assets/readme"
cp "$ROOT/site/index.html" "$ROOT/site/scenes.css" "$ROOT/site/scenes.js" "$OUT/"
cp -R "$ROOT/site/apps" "$OUT/apps"
cp "$ROOT/Resources/background-colour.jpg" "$OUT/assets/painting.jpg"
cp "$ROOT/Resources/Fonts/GeistPixel-Square.ttf" "$ROOT/Resources/Fonts/GeistPixel-Circle.ttf" \
   "$ROOT/Resources/Fonts/GeistMono-Regular.otf" "$ROOT/Resources/Fonts/Geist-Regular.otf" \
   "$ROOT/Resources/Fonts/Geist-Medium.otf" "$ROOT/Resources/Fonts/LICENSE-Geist-OFL.txt" "$OUT/assets/fonts/"
for f in icon.png banner.jpg tamil.png search.png; do
  cp "$ROOT/docs/readme/$f" "$OUT/assets/readme/"
done
touch "$OUT/.nojekyll"
echo "site: $OUT"
