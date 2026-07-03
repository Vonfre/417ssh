#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="417ssh"
VERSION="${VERSION:-$(cat "$ROOT_DIR/VERSION" 2>/dev/null || echo "0.4.4")}"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
ZIP_PATH="$BUILD_DIR/$APP_NAME-$VERSION-mac-app.zip"
STAGING_DIR="$BUILD_DIR/zip-staging"
README_PATH="$STAGING_DIR/README-macOS.txt"

"$ROOT_DIR/scripts/build_app.sh"

rm -rf "$STAGING_DIR" "$ZIP_PATH"
mkdir -p "$STAGING_DIR"

cp -R "$APP_DIR" "$STAGING_DIR/$APP_NAME.app"
if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$STAGING_DIR/$APP_NAME.app" || true
fi
cat > "$README_PATH" <<'README'
417ssh macOS 首次打开说明

如果双击 417ssh.app 时出现“Apple 无法验证 417ssh 是否包含可能危害 Mac 安全或泄漏隐私的恶意软件”：

1. 点击“完成”，不要点击“移到废纸篓”。
2. 在 Finder 里找到 417ssh.app。
3. 按住 Control 点击，或右键点击 417ssh.app。
4. 选择“打开”。
5. 在新的提示窗口里再次选择“打开”。

如果仍然不能打开：

1. 打开“系统设置”。
2. 进入“隐私与安全性”。
3. 在安全提示区域选择“仍要打开”。

出现这个提示的原因是当前版本还没有使用 Apple Developer ID 做签名和公证。应用本身由 GitHub Actions 从源码自动构建，发布包旁边的 SHA256SUMS.txt 可用于校验下载文件完整性。

应用内自动更新会在替换新版 417ssh.app 时清理 macOS 下载隔离标记，并自动重新打开应用。
README

if command -v ditto >/dev/null 2>&1; then
  ditto -c -k --sequesterRsrc "$STAGING_DIR" "$ZIP_PATH"
else
  (cd "$STAGING_DIR" && zip -qr "$ZIP_PATH" "$APP_NAME.app" "README-macOS.txt")
fi

echo "Built: $ZIP_PATH"
