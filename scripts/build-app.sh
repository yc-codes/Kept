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
cp -R "$BIN/Kept_Kept.bundle" "$APP/Contents/Resources/"
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

swift scripts/make-icon.swift "$APP/Contents/Resources/KeptMenu.png" --menu-mark

# A certificate keeps macOS privacy grants stable across builds. CI and local
# builds without a supplied identity use an ad-hoc signature.
SIGN=(--sign "${KEPT_SIGN_IDENTITY:--}")

EXT="$APP/Contents/PlugIns/KeptShare.appex"
mkdir -p "$EXT/Contents/MacOS"
cp ShareExtension/Info.plist "$EXT/Contents/Info.plist"
xcrun swiftc -target "$(uname -m)-apple-macos14.0" -application-extension -parse-as-library \
    ShareExtension/ShareViewController.swift -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$EXT/Contents/MacOS/KeptShare"
codesign --force "${SIGN[@]}" --entitlements ShareExtension/Share.entitlements "$EXT"

codesign --force "${SIGN[@]}" --identifier app.kept.Kept "$APP/Contents/MacOS/kept-mcp"
codesign --force "${SIGN[@]}" "$APP"
codesign --verify --strict "$APP"
echo "Signed: $(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"

# Finder and the Dock cache icons per app path. Re-registering the fresh bundle makes them drop a stale one.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true

echo "Built $APP"
