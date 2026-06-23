#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -n "${SDKROOT:-}" && ! -d "$SDKROOT" ]]; then
  echo "Ignoring stale SDKROOT: $SDKROOT"
  unset SDKROOT
fi

run_swift() {
  mkdir -p .build/swift-home .build/clang-module-cache .build/swiftpm-cache .build/swiftpm-config .build/swiftpm-security
  HOME="$PWD/.build/swift-home" \
    CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
    swift "$@" \
      --disable-sandbox \
      --cache-path "$PWD/.build/swiftpm-cache" \
      --config-path "$PWD/.build/swiftpm-config" \
      --security-path "$PWD/.build/swiftpm-security"
}

run_swift build
pkill -x MusicIsland 2>/dev/null || true

APP_DIR=".build/MusicIsland.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp .build/debug/MusicIsland "$MACOS_DIR/MusicIsland"
cp Resources/AppIcon.icns "$RESOURCES_DIR/AppIcon.icns"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>MusicIsland</string>
  <key>CFBundleIdentifier</key>
  <string>app.musicisland.player</string>
  <key>CFBundleName</key>
  <string>MusicIsland</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

SIGNING_IDENTITY="${MUSICISLAND_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -n 1)"
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
  codesign --force --sign "$SIGNING_IDENTITY" "$MACOS_DIR/MusicIsland"
  codesign --force --sign "$SIGNING_IDENTITY" "$APP_DIR"
else
  codesign --force --sign - "$MACOS_DIR/MusicIsland"
  codesign --force --sign - "$APP_DIR"
fi

open "$PWD/$APP_DIR"
