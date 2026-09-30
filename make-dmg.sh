#!/bin/bash
# Package the app as the disk image attached to each GitHub release: the app
# beside an Applications shortcut, so installing is one drag.
set -euo pipefail
cd "$(dirname "$0")"

./make-app.sh

APP_NAME="Steam Clip Converter for Mac"
BUNDLE="build/$APP_NAME.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$BUNDLE/Contents/Info.plist")
DMG="build/Steam-Clip-Converter-for-Mac-$VERSION.dmg"

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
ditto "$BUNDLE" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

# ULFO (LZFSE) opens on macOS 10.11 and later, well below the app's minimum.
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -fs HFS+ -format ULFO -ov "$DMG" >/dev/null

echo "built $DMG"
shasum -a 256 "$DMG"
