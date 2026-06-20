#!/usr/bin/env bash
set -euo pipefail

# Builds a release MusicIsland.app and packages it into a distributable .dmg
# with a drag-to-Applications layout. Output: dist/MusicIsland-<version>.dmg
#
# Optional overrides:
#   MUSICISLAND_SIGNING_IDENTITY  codesign identity (defaults to first Apple
#                               Development identity, or ad-hoc signing)

cd "$(dirname "$0")/.."

if [[ -n "${SDKROOT:-}" && ! -d "$SDKROOT" ]]; then
  echo "Ignoring stale SDKROOT: $SDKROOT"
  unset SDKROOT
fi

VERSION="0.1.0"
APP_NAME="MusicIsland"
DIST_DIR="dist"
STAGING_DIR="$DIST_DIR/dmg-staging"
APP_DIR="$STAGING_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"

echo "==> Building release binary"
swift build -c release

echo "==> Assembling $APP_NAME.app"
rm -rf "$STAGING_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp ".build/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp Resources/AppIcon.icns "$RESOURCES_DIR/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>app.musicisland.player</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

echo "==> Code signing"
SIGNING_IDENTITY="${MUSICISLAND_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -n 1)"
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
  echo "    using identity: $SIGNING_IDENTITY"
  codesign --force --sign "$SIGNING_IDENTITY" "$MACOS_DIR/$APP_NAME"
  codesign --force --sign "$SIGNING_IDENTITY" "$APP_DIR"
else
  echo "    no Developer ID found; ad-hoc signing"
  codesign --force --sign - "$MACOS_DIR/$APP_NAME"
  codesign --force --sign - "$APP_DIR"
fi

echo "==> Building $DMG_PATH"
# Drag-to-install layout: the app plus a symlink to /Applications.
ln -sf /Applications "$STAGING_DIR/Applications"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG_PATH"

rm -rf "$STAGING_DIR"
echo "==> Done: $DMG_PATH"
