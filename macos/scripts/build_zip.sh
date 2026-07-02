#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="417ssh"
VERSION="${VERSION:-$(cat "$ROOT_DIR/VERSION" 2>/dev/null || echo "0.2.0")}"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
ZIP_PATH="$BUILD_DIR/$APP_NAME-$VERSION-mac-app.zip"
STAGING_DIR="$BUILD_DIR/zip-staging"

"$ROOT_DIR/scripts/build_app.sh"

rm -rf "$STAGING_DIR" "$ZIP_PATH"
mkdir -p "$STAGING_DIR"

cp -R "$APP_DIR" "$STAGING_DIR/$APP_NAME.app"

if command -v ditto >/dev/null 2>&1; then
  ditto -c -k --sequesterRsrc --keepParent "$STAGING_DIR/$APP_NAME.app" "$ZIP_PATH"
else
  (cd "$STAGING_DIR" && zip -qr "$ZIP_PATH" "$APP_NAME.app")
fi

echo "Built: $ZIP_PATH"
