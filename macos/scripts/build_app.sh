#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="417ssh"
BUNDLE_ID="com.zhanghuan.417ssh"
VERSION="0.2.0"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
EXECUTABLE="$APP_DIR/Contents/MacOS/RemoteJupyterTunnel"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
ORIGINAL_HOME="${HOME:-}"

cd "$ROOT_DIR"

mkdir -p "$ROOT_DIR/.build/home" "$ROOT_DIR/.build/module-cache"
export HOME="$ROOT_DIR/.build/home"
export XDG_CACHE_HOME="$ROOT_DIR/.build/cache"
export SWIFTPM_HOME="$ROOT_DIR/.build/swiftpm-home"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/module-cache"

swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$RESOURCES_DIR"

cp "$ROOT_DIR/.build/release/RemoteJupyterTunnel" "$EXECUTABLE"
chmod +x "$EXECUTABLE"

if [[ -f "$ROOT_DIR/logo.jpg" ]]; then
  cp "$ROOT_DIR/logo.jpg" "$RESOURCES_DIR/logo.jpg"

  if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
    ICON_SOURCE="$ROOT_DIR/logo.jpg"
    ICON_BASE="$BUILD_DIR/AppIconBase.png"

    if command -v python3 >/dev/null 2>&1; then
      if HOME="$ORIGINAL_HOME" python3 "$ROOT_DIR/scripts/make_app_icon.py" "$ROOT_DIR/logo.jpg" "$ICON_BASE"; then
        ICON_SOURCE="$ICON_BASE"
        cp "$ICON_BASE" "$RESOURCES_DIR/AppIcon.png"
      fi
    fi

    ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
    rm -rf "$ICONSET_DIR"
    mkdir -p "$ICONSET_DIR"

    sips -s format png -z 16 16 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
    sips -s format png -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
    sips -s format png -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
    sips -s format png -z 64 64 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
    sips -s format png -z 128 128 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
    sips -s format png -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
    sips -s format png -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
    sips -s format png -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
    sips -s format png -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
    sips -s format png -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
    iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
  fi
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>RemoteJupyterTunnel</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR" >/dev/null
fi

touch "$APP_DIR"

echo "Built: $APP_DIR"
