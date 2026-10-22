#!/bin/sh
# 构建通用二进制（arm64 + x86_64）的菜单栏 App：gui/*.swift -> dist/WCooler.app
# 本地开发用 gui/build.sh（只编本机架构，更快）；发版/CI 用这个。
set -e
cd "$(dirname "$0")/.."

APP="dist/WCooler.app"
SRCS="gui/Protocol.swift gui/CoolerEngine.swift gui/SMCReader.swift gui/Settings.swift gui/Views.swift gui/main.swift"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

for arch in arm64 x86_64; do
    echo "编译 $arch …"
    swiftc -O -swift-version 5 -target "${arch}-apple-macosx11.0" \
        $SRCS -o "$TMP/WCooler-$arch"
done

lipo -create -output "$APP/Contents/MacOS/WCooler" \
    "$TMP/WCooler-arm64" "$TMP/WCooler-x86_64"
cp gui/Info.plist "$APP/Contents/Info.plist"

# ad-hoc 签名：避免每次开机都被 Gatekeeper 拦一次蓝牙权限
codesign -s - --force --deep "$APP" 2>/dev/null || echo "（跳过签名）"

echo "构建完成：$PWD/$APP"
lipo -info "$APP/Contents/MacOS/WCooler"
