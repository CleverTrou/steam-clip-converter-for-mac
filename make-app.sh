#!/bin/bash
# Build a release binary and wrap it in a double-clickable .app bundle.
# A bare SPM executable can show a window, but without a bundle it has no
# identity: no proper Dock name, no menu bar title, no icon.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Steam Clip Converter for Mac"
BUNDLE="build/$APP_NAME.app"

# Universal (Apple silicon + Intel) by default, since the result is what gets
# published. Multi-arch builds need full Xcode, not just the Command Line Tools;
# UNIVERSAL=0 builds for this Mac's architecture only.
if [ "${UNIVERSAL:-1}" = 1 ]; then
    ARCHS=(--arch arm64 --arch x86_64)
else
    ARCHS=()
fi
# ${ARCHS[@]+...}: macOS's bash 3.2 treats an empty array as unbound under set -u.
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN=$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/SteamClipConverter

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/SteamClipConverter"

# Icon. Regenerated from the SVG source whenever it is newer than the .icns and a
# rasteriser is available; the committed .icns keeps the build working without one.
ICON_DIR="design/app-icon"
if [ "$ICON_DIR/icon-sequoia-1024.svg" -nt "$ICON_DIR/AppIcon.icns" ] \
   && command -v rsvg-convert >/dev/null 2>&1; then
    ( cd "$ICON_DIR" && ./make-icon.sh )
fi
cp "$ICON_DIR/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Steam Clip Converter</string>
    <key>CFBundleDisplayName</key><string>Steam Clip Converter for Mac</string>
    <key>CFBundleExecutable</key><string>SteamClipConverter</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.trevornelson.steamclipconverter</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.1</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Trevor Nelson. MIT License.</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to launch locally without Gatekeeper complaints.
# Not optional: Apple silicon refuses to run an arm64 binary with no signature
# at all, so a failure here must stop the build rather than ship a dead app.
codesign --force --sign - "$BUNDLE" >/dev/null

echo "built $BUNDLE"
