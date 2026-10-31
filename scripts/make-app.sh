#!/bin/bash
# 组装 .app 并 ad-hoc 签名
# 说明：本机（外置卷）上 SwiftPM 默认构建目录写不进去，构建产物统一放到 /tmp。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
SCRATCH="${SCRATCH_PATH:-/tmp/cm-scratch}"
MC="${MODULE_CACHE:-/tmp/cm-mc}"
TMP="${BUILD_TMP:-/tmp/cm-tmp}"
mkdir -p "$SCRATCH" "$MC" "$TMP"
export CLANG_MODULE_CACHE_PATH="$MC"
export TMPDIR="$TMP"

swift build -c "$CONFIG" --disable-sandbox --scratch-path "$SCRATCH" \
  -Xswiftc -module-cache-path -Xswiftc "$MC" >/dev/null

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path --scratch-path "$SCRATCH" 2>/dev/null | tail -1)"
APP="build/cleanmyiphone.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/CleanMyiPhone" "$APP/Contents/MacOS/cleanmyiphone"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "built: $APP"
