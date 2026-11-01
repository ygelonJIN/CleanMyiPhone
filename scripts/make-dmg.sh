#!/bin/bash
# 打一个可以直接发给别人的 DMG：
#   通用二进制（Apple 芯片 + Intel）→ .app（ad-hoc 签名）→ DMG
#   DMG 里放：App + 「首次打开.command」+「使用说明.txt」+ /Applications 快捷方式
#
# 用法：
#   scripts/make-dmg.sh              # 完整构建 + 出 DMG
#   SKIP_BUILD=1 scripts/make-dmg.sh # 只用 build/ 里现成的二进制
#
# 说明：本机（外置卷）上 SwiftPM 默认构建目录写不进去，构建产物统一放 /tmp。
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="cleanmyiphone"
APP="build/${APP_NAME}.app"
DIST="dist"

# ---------- 1. 两个架构各编一次，再合成通用二进制 ----------
# 为什么分两次：SwiftPM 的 --arch 只编一个架构，直接 lipo 合并最简单可靠。
build_one() {
    local arch="$1"
    local scratch="/tmp/cm-scratch-${arch}"
    local mc="/tmp/cm-mc-${arch}"
    local tmp="/tmp/cm-tmp-${arch}"
    mkdir -p "$scratch" "$mc" "$tmp"
    echo "→ 编译 ${arch}" >&2
    CLANG_MODULE_CACHE_PATH="$mc" TMPDIR="$tmp" \
        swift build -c release --disable-sandbox --scratch-path "$scratch" \
        --arch "$arch" -Xswiftc -module-cache-path -Xswiftc "$mc" >/dev/null
    # 产物位置两种：带 --arch 时在 <scratch>/release/，否则在 <scratch>/<arch>-apple-macosx/release/
    local bin=""
    for candidate in "$scratch/release/CleanMyiPhone" "$scratch"/*-apple-macosx/release/CleanMyiPhone; do
        if [ -f "$candidate" ]; then bin="$candidate"; break; fi
    done
    [ -n "$bin" ] || { echo "找不到 ${arch} 的产物" >&2; exit 1; }
    printf '%s\n' "$bin"
}

mkdir -p build "$DIST" /tmp/cm-mc /tmp/cm-tmp /tmp/cm-arch

if [ "${SKIP_BUILD:-0}" = "1" ]; then
    echo "→ 跳过编译，用 /tmp/cm-arch 里上次的两份单架构产物"
    for arch in arm64 x86_64; do
        [ -f "/tmp/cm-arch/${arch}" ] \
            || { echo "缺 /tmp/cm-arch/${arch}，去掉 SKIP_BUILD=1 重来" >&2; exit 1; }
    done
else
    cp "$(build_one arm64)"  /tmp/cm-arch/arm64
    cp "$(build_one x86_64)" /tmp/cm-arch/x86_64
fi

# ---------- 2. 组装 .app ----------
echo "→ 组装 ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create /tmp/cm-arch/arm64 /tmp/cm-arch/x86_64 \
     -output "$APP/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# 图标等资源：Info.plist 之外的全部搬进 Contents/Resources
# （Info.plist 里写着 CFBundleIconFile=AppIcon，缺了这个文件 Finder 只会显示通用图标）
for res in Resources/*; do
    [ "$(basename "$res")" = "Info.plist" ] && continue
    [ -f "$res" ] && cp "$res" "$APP/Contents/Resources/"
done

# ---------- 3. ad-hoc 签名（没有开发者 ID，只能这样） ----------
echo "→ ad-hoc 签名"
codesign --force --deep --sign - --timestamp=none "$APP" >/dev/null
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/   /'

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
DMG="${DIST}/${APP_NAME}-${VERSION}-universal.dmg"
# 同一份内容再落一个**普通文件夹**：想直接 AirDrop / 压缩打包发人的就用这个
FOLDER="${DIST}/${APP_NAME}-${VERSION}"

# ---------- 4. 装配（DMG 和文件夹共用这一份 stage） ----------
STAGE="$(mktemp -d /tmp/cm-dmg-stage.XXXXXX)"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

ditto "$APP" "$STAGE/${APP_NAME}.app"
ln -s /Applications "$STAGE/Applications"
cp scripts/dmg/首次打开.command "$STAGE/首次打开.command"
cp scripts/dmg/使用说明.txt "$STAGE/使用说明.txt"

# 权限要按「别人也能读」的规格摆好：DMG 挂上去可能不看属主（uid 变了），
# 目录/文件一律 a+rX，脚本 0755 —— 否则别人打开会看到"没有权限"。
chmod 755 "$STAGE" "$STAGE/首次打开.command"
chmod 644 "$STAGE/使用说明.txt"
chmod -R a+rX "$STAGE/${APP_NAME}.app"
chmod 755 "$STAGE/${APP_NAME}.app/Contents/MacOS/${APP_NAME}"

# DMG 里不留任何扩展属性（我自己机器上的 xattr 不值得带出去）
xattr -cr "$STAGE" 2>/dev/null || true

# ---------- 5. 先落「文件夹版」（与 DMG 内容完全一致） ----------
echo "→ 装配文件夹 $FOLDER"
rm -rf "$FOLDER"
ditto "$STAGE" "$FOLDER"          # ditto 保留权限、可执行位和 Applications 符号链接

echo "→ 打 DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO \
      -ov -quiet "$DMG"

# 再打一个 zip：微信 / 邮件发文件夹不方便时才用它（ditto 打包会保留可执行位）
ZIP="${DIST}/${APP_NAME}-${VERSION}.zip"
echo "→ 打 zip $ZIP"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$FOLDER" "$ZIP"

# ---------- 6. 回验：挂上去看内容、验签名、看架构 ----------
MOUNT="$(mktemp -d /tmp/cm-dmg-mnt.XXXXXX)"
hdiutil attach "$DMG" -nobrowse -readonly -quiet -mountpoint "$MOUNT"
echo "→ DMG 内容："
ls -1 "$MOUNT" | sed 's/^/   /'
echo "→ 架构："
lipo -info "$MOUNT/${APP_NAME}.app/Contents/MacOS/${APP_NAME}" | sed 's/^/   /'
echo "→ 签名："
codesign -dv "$MOUNT/${APP_NAME}.app" 2>&1 | grep -E 'Identifier|Signature|Format' | sed 's/^/   /'
hdiutil detach "$MOUNT" -quiet
rmdir "$MOUNT"

echo
echo "完成（三种发法，内容一模一样）："
echo "  文件夹  $FOLDER          ← 直接 AirDrop 整个文件夹"
echo "  压缩包  $ZIP"
echo "  DMG    $DMG       ← 最稳，双击挂载后拖进「应用程序」"
echo "文件夹 $(du -sh "$FOLDER" | cut -f1)　压缩包 $(du -h "$ZIP" | cut -f1)　DMG $(du -h "$DMG" | cut -f1)"
shasum -a 256 "$DMG" | sed 's/^/sha256: /'
