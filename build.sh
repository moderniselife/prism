#!/bin/bash
# Build Prism.app without needing full Xcode (works with Command Line Tools).
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Prism"
BUNDLE_ID="com.mojolayers.prism"
VERSION="1.0.0"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

echo "▸ Compiling Swift sources…"
mkdir -p "$BUILD_DIR"
swiftc \
    -O \
    -parse-as-library \
    -swift-version 5 \
    -target arm64-apple-macosx14.0 \
    Sources/CursorProfiles/*.swift \
    -o "$BUILD_DIR/CursorProfiles"

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
cp "$BUILD_DIR/CursorProfiles" "$APP_DIR/Contents/MacOS/CursorProfiles"
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/Prism.icns"
cp "assets/logo.png" "$APP_DIR/Contents/Resources/logo.png"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>CursorProfiles</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>Prism</string>
    <key>CFBundleIconName</key><string>Prism</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© $(date +%Y)</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

echo "▸ Signing (ad-hoc)…"
codesign --force --sign - "$APP_DIR"

echo "✓ Built: $APP_DIR"
echo "  Run it with:  open \"$APP_DIR\""
