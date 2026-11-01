#!/bin/sh
# 首次打开所需的一步：去掉 macOS 给「从网上下载的文件」打的隔离标记，然后启动 App。
# 用法：在 Finder 里双击本文件即可，不用自己敲命令。
#
# 为什么需要这一步：这个 App 没有 Apple 开发者账号（没做公证），
# 系统第一次见到它会拦下并说「无法验证开发者」。去掉隔离标记后就能正常双击打开。

APP_NAME="cleanmyiphone.app"

here=$(cd "$(dirname "$0")" && pwd)

find_app() {
    for candidate in \
        "/Applications/$APP_NAME" \
        "$HOME/Applications/$APP_NAME" \
        "$HOME/Downloads/$APP_NAME" \
        "$here/$APP_NAME"
    do
        if [ -d "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

if ! APP=$(find_app); then
    echo "没找到 $APP_NAME。"
    echo "请先把 App 拖进「应用程序」文件夹，再双击本脚本。"
    printf '按回车关闭窗口…'
    read -r _
    exit 1
fi

case "$APP" in
    /Volumes/*)
        echo "App 还在安装盘（DMG）里：先把它拖到「应用程序」文件夹，再来双击本脚本。"
        printf '按回车关闭窗口…'
        read -r _
        exit 1
        ;;
esac

echo "路径：$APP"
echo "正在解除隔离标记…"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null
xattr -dr com.apple.provenance "$APP" 2>/dev/null

echo "启动中…"
open "$APP"
echo
echo "完成。以后直接在「启动台」或「应用程序」里双击 App 就行，不用再跑这个脚本。"
sleep 1
