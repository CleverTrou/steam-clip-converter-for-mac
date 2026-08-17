#!/bin/bash
# Render icon-sequoia-1024.svg into AppIcon.icns for macOS 15 (Sequoia) and earlier.
# macOS 26 Liquid Glass needs a layered .icon instead — see README, "macOS 26".
set -euo pipefail
cd "$(dirname "$0")"

SRC="icon-sequoia-1024.svg"
OUT="AppIcon.icns"
SET="AppIcon.iconset"

# pick a rasteriser
if command -v rsvg-convert >/dev/null 2>&1; then
  render() { rsvg-convert -w "$1" -h "$1" "$SRC" -o "$2"; }
elif command -v magick >/dev/null 2>&1; then
  render() { magick -background none -density 1200 "$SRC" -resize "$1x$1" "$2"; }
elif command -v inkscape >/dev/null 2>&1; then
  render() { inkscape "$SRC" -w "$1" -h "$1" -o "$2" >/dev/null 2>&1; }
else
  echo "No SVG rasteriser found. Install one:  brew install librsvg   (or imagemagick)" >&2
  exit 1
fi

rm -rf "$SET"; mkdir -p "$SET"
render 16   "$SET/icon_16x16.png"
render 32   "$SET/icon_16x16@2x.png"
render 32   "$SET/icon_32x32.png"
render 64   "$SET/icon_32x32@2x.png"
render 128  "$SET/icon_128x128.png"
render 256  "$SET/icon_128x128@2x.png"
render 256  "$SET/icon_256x256.png"
render 512  "$SET/icon_256x256@2x.png"
render 512  "$SET/icon_512x512.png"
render 1024 "$SET/icon_512x512@2x.png"

iconutil -c icns "$SET" -o "$OUT"
rm -rf "$SET"
echo "built $OUT"
