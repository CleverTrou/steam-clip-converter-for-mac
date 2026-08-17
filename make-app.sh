#!/bin/bash
# Build a release binary and wrap it in a double-clickable .app bundle.
# A bare SPM executable can show a window, but without a bundle it has no
# identity: no proper Dock name, no menu bar title, no icon.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Steam Clip Converter for Mac"
BUNDLE="build/$APP_NAME.app"

swift build -c release
BIN=$(swift build -c release --show-bin-path)/SteamClipConverter

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/SteamClipConverter"

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Steam Clip Converter</string>
    <key>CFBundleDisplayName</key><string>Steam Clip Converter for Mac</string>
    <key>CFBundleExecutable</key><string>SteamClipConverter</string>
    <key>CFBundleIdentifier</key><string>com.trevornelson.steamclipconverter</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to launch locally without Gatekeeper complaints.
codesign --force --sign - "$BUNDLE" >/dev/null 2>&1 || true

echo "built $BUNDLE"
