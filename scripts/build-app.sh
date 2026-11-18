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

swift scripts/make-icon.swift "$APP/Contents/Resources/KeptMenu.png" --menu-mark

# Signing. macOS ties privacy grants such as Screen Recording to the app's designated requirement. An
# ad-hoc signature makes that requirement the build's cdhash, so every rebuild silently invalidates the
# grant while System Settings still shows Kept as enabled. Signing with a certificate makes the
# requirement "identifier + certificate", which is the same for every build.
#   KEPT_SIGN_IDENTITY set    use that identity from your keychains (for example "Apple Development: …")
#   otherwise                 use a self-signed identity kept in its own keychain file, created on first
#                             build. It is never added to the keychain search list or trusted system-wide.
SIGN_DIR="${KEPT_SIGN_DIR:-$HOME/Library/Developer/Kept}"
SIGN_KEYCHAIN="$SIGN_DIR/kept-signing.keychain-db"
SIGN_NAME="Kept Local Signing"
SIGN_PASS="kept-local-signing"

ensure_local_identity() {
    if [ ! -f "$SIGN_KEYCHAIN" ]; then
        echo "Creating local signing identity in $SIGN_KEYCHAIN"
        mkdir -p "$SIGN_DIR"
        local tmp
        tmp="$(mktemp -d)"
        cat > "$tmp/cfg" <<CFG
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$SIGN_NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CFG
        /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$tmp/cfg" \
            -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
        /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$SIGN_NAME" \
            -out "$tmp/id.p12" -passout "pass:$SIGN_PASS"
        # Build the keychain beside its final path and move it into place only once it is complete.
        local new="$SIGN_DIR/kept-signing-new.keychain-db"
        rm -f "$new"
        security create-keychain -p "$SIGN_PASS" "$new"
        security set-keychain-settings "$new"
        security unlock-keychain -p "$SIGN_PASS" "$new"
        security import "$tmp/id.p12" -k "$new" -P "$SIGN_PASS" -T /usr/bin/codesign >/dev/null
        security set-key-partition-list -S apple-tool:,apple: -s -k "$SIGN_PASS" "$new" >/dev/null
        mv "$new" "$SIGN_KEYCHAIN"
        rm -rf "$tmp"
    fi
    security unlock-keychain -p "$SIGN_PASS" "$SIGN_KEYCHAIN"
}

if [ -n "${KEPT_SIGN_IDENTITY:-}" ]; then
    SIGN=(--sign "$KEPT_SIGN_IDENTITY")
elif ensure_local_identity; then
    SIGN=(--keychain "$SIGN_KEYCHAIN" --sign "$SIGN_NAME")
else
    echo "warning: no stable signing identity; falling back to an ad-hoc signature." >&2
    echo "warning: macOS will stop honouring Screen Recording access after each rebuild." >&2
    SIGN=(--sign -)
fi

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
