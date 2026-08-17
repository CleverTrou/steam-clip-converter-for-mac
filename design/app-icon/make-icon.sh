#!/bin/bash
# Render the icon SVGs into AppIcon.icns for macOS 15 (Sequoia) and earlier.
# macOS 26 Liquid Glass needs a layered .icon instead — see README, "macOS 26".
#
# An .icns is a set of independent rasters, not one image scaled, so the small
# slots can carry simplified geometry without affecting the large ones. Anything
# rendered into 32 physical pixels or fewer uses a size-specific variant:
#
#   icon_16x16      16px  <- icon-16.svg          (no sprockets, largest glyph)
#   icon_16x16@2x   32px  <- icon-32.svg          (4 sprockets, no shadow)
#   icon_32x32      32px  <- icon-32.svg
#   icon_32x32@2x   64px  <- icon-sequoia-1024.svg (full artwork from here up)
#
set -euo pipefail
cd "$(dirname "$0")"

FULL="icon-sequoia-1024.svg"
SMALL32="icon-32.svg"
SMALL16="icon-16.svg"
OUT="AppIcon.icns"
SET="AppIcon.iconset"

# pick a rasteriser
if command -v rsvg-convert >/dev/null 2>&1; then
  render() { rsvg-convert -w "$2" -h "$2" "$1" -o "$3"; }
elif command -v magick >/dev/null 2>&1; then
  render() { magick -background none -density 1200 "$1" -resize "$2x$2" "$3"; }
elif command -v inkscape >/dev/null 2>&1; then
  render() { inkscape "$1" -w "$2" -h "$2" -o "$3" >/dev/null 2>&1; }
else
  echo "No SVG rasteriser found. Install one:  brew install librsvg   (or imagemagick)" >&2
  exit 1
fi

rm -rf "$SET"; mkdir -p "$SET"
render "$SMALL16" 16   "$SET/icon_16x16.png"
render "$SMALL32" 32   "$SET/icon_16x16@2x.png"
render "$SMALL32" 32   "$SET/icon_32x32.png"
render "$FULL"    64   "$SET/icon_32x32@2x.png"
render "$FULL"    128  "$SET/icon_128x128.png"
render "$FULL"    256  "$SET/icon_128x128@2x.png"
render "$FULL"    256  "$SET/icon_256x256.png"
render "$FULL"    512  "$SET/icon_256x256@2x.png"
render "$FULL"    512  "$SET/icon_512x512.png"
render "$FULL"    1024 "$SET/icon_512x512@2x.png"

iconutil -c icns "$SET" -o "$OUT"
rm -rf "$SET"
echo "built $OUT"
