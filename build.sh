#!/bin/bash
# Build Prism.app without needing full Xcode (works with Command Line Tools).
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Prism"
BUNDLE_ID="com.mojolayers.prism"
# The release workflow sets PRISM_VERSION from the tag; local builds use this.
VERSION="${PRISM_VERSION:-1.5.0}"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
# Stamp which source this is, so Prism can tell builds apart.
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
if [ -n "$(git status --porcelain -- Sources 2>/dev/null)" ]; then COMMIT="$COMMIT+"; fi
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
INSTALL=0
[ "${1:-}" = "--install" ] && INSTALL=1

echo "▸ Compiling Swift sources…"
mkdir -p "$BUILD_DIR"
swiftc \
    -O \
    -parse-as-library \
    -swift-version 5 \
    -target arm64-apple-macosx14.0 \
    Sources/CursorProfiles/*.swift \
    -o "$BUILD_DIR/Prism"

echo "▸ Building app icon from assets/logo.png…"
ICONSET="$BUILD_DIR/Prism.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "assets/logo.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" "assets/logo.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done

echo "▸ Assembling app bundle…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
# The executable must not contain "Cursor": updaters and process scanners
# that match by name (ps -c, pgrep, Activity Monitor) would count Prism as
# a running Cursor instance.
cp "$BUILD_DIR/Prism" "$APP_DIR/Contents/MacOS/Prism"
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/Prism.icns"
cp "assets/logo.png" "$APP_DIR/Contents/Resources/logo.png"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Prism</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>Prism</string>
    <key>CFBundleIconName</key><string>Prism</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>PrismCommit</key><string>$COMMIT</string>
    <key>PrismBuildDate</key><string>$BUILD_DATE</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© $(date +%Y)</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

echo "▸ Signing (ad-hoc)…"
codesign --force --sign - "$APP_DIR"

echo "✓ Built: $APP_DIR ($VERSION, $COMMIT)"

if [ "$INSTALL" = 1 ]; then
    DEST="/Applications/$APP_NAME.app"
    echo "▸ Quitting the running Prism…"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do
        pgrep -f "$APP_NAME.app/Contents/MacOS/" >/dev/null || break
        sleep 0.25
    done
    pkill -f "$APP_NAME.app/Contents/MacOS/" 2>/dev/null || true
    echo "▸ Installing to ${DEST}…"
    rm -rf "$DEST"
    ditto "$APP_DIR" "$DEST"
    open "$DEST"
    echo "✓ Installed and opened $DEST"
else
    echo "  Run it with:  open \"$APP_DIR\"   (or ./build.sh --install)"
fi
