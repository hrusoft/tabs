#!/bin/bash
# Renders the dmg window's background, Artwork/dmg-background.svg (660 x 500 pt), into what the dmg packs:
# Scripts/dmg/background.png (1x) and background@2x.png (dmgbuild makes the two one Retina TIFF).
#
#   Scripts/dmg/render-background.sh
#
# Run it after editing the SVG, look at both PNGs, and commit the three files together: a release packs the PNGs
# as committed, so it never depends on a renderer.
#
# QuickLook renders the SVG (WebKit, the only SVG renderer macOS ships). It draws into a square, art at the top,
# and sips crops only around the middle: so the art is centred in a square viewBox first, then cropped back out.
set -euo pipefail

dir="$(cd "$(dirname "$0")" && pwd)"
svg="$dir/../../Artwork/dmg-background.svg"
size='width="660" height="500" viewBox="0 0 660 500"'
grep -q "$size" "$svg" || { echo "render-background: expected <svg $size> in $svg" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sed "s/$size/width=\"660\" height=\"660\" viewBox=\"0 -80 660 660\"/" "$svg" >"$work/background.svg"

for scale in 1 2; do
  rm -f "$work/background.svg.png"
  qlmanage -t -s $((660 * scale)) -o "$work" "$work/background.svg" >/dev/null 2>&1
  [ -f "$work/background.svg.png" ] || { echo "render-background: QuickLook rendered nothing" >&2; exit 1; }
  out="$dir/background.png"
  [ "$scale" = 1 ] || out="$dir/background@${scale}x.png"
  sips -c $((500 * scale)) $((660 * scale)) "$work/background.svg.png" --out "$out" >/dev/null
  echo "$out"
done
