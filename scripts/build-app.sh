#!/bin/bash
# Builds build/Kept.app from the Swift package. Works with Command Line Tools alone (no Xcode needed).
#   scripts/build-app.sh          release build
#   scripts/build-app.sh debug    debug build
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/Kept.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Kept" "$APP/Contents/MacOS/Kept"
cp "$BIN/kept-mcp" "$APP/Contents/MacOS/kept-mcp"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon: drawn by scripts/make-icon.swift, cached until that script changes.
ICNS="build/AppIcon.icns"
if [ ! -f "$ICNS" ] || [ scripts/make-icon.swift -nt "$ICNS" ]; then
    SET="build/AppIcon.iconset"
    rm -rf "$SET" && mkdir -p "$SET"
    swift scripts/make-icon.swift build/icon-1024.png
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" build/icon-1024.png --out "$SET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z "$double" "$double" build/icon-1024.png --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$SET" -o "$ICNS"
fi
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature. macOS ties Screen Recording permission to the signature, so it asks again after each
# rebuild. Set KEPT_SIGN_IDENTITY to a real signing identity to keep the permission across builds.
codesign --force --sign "${KEPT_SIGN_IDENTITY:--}" --identifier app.kept.Kept "$APP/Contents/MacOS/kept-mcp"
codesign --force --sign "${KEPT_SIGN_IDENTITY:--}" "$APP"

echo "Built $APP"
