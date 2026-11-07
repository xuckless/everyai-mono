#!/usr/bin/env bash
# Turns the PNGs from shots_test.dart into the README's WebP images (needs cwebp and ImageMagick).
#   cd frontend && flutter test tool/readme_shots/shots_test.dart && tool/readme_shots/to_webp.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
src=${EVERYAI_SHOTS_OUT:-build/readme_shots}
dst=../docs/readme
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# name  width  [crop WxH+X+Y on the 2x PNG]
while read -r name width crop; do
  [[ -z $name ]] && continue
  in=$src/$name.png
  if [[ -n ${crop:-} ]]; then
    magick "$in" -crop "$crop" +repage "$tmp/$name.png"
    in=$tmp/$name.png
  fi
  cwebp -quiet -q 86 -alpha_q 100 -resize "$width" 0 "$in" -o "$dst/$name.webp"
  echo "$dst/$name.webp"
done <<'LIST'
console 1800
agents 1100
picker 1100
workflows 1100
board 1800
approval 1100
keys 1200
artifact 1400
slides 1400
chart 1400
search 1400
LIST
