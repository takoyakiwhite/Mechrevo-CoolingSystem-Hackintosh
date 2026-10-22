#!/bin/sh
# 构建菜单栏 App：gui/*.swift -> dist/WCooler.app
set -e
cd "$(dirname "$0")/.."

# 文件名保持 ASCII：zip 会弄坏中文文件名。中文名靠 Info.plist 的
# CFBundleDisplayName 生效（Finder / 权限弹窗 / 关于 都显示「水冷魔盒」）
APP="dist/WCooler.app"
ARCH="$(uname -m)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "编译（$ARCH）…"
swiftc -O -swift-version 5 \
  -target "${ARCH}-apple-macosx11.0" \
  gui/Protocol.swift gui/CoolerEngine.swift gui/SMCReader.swift gui/GPUReader.swift gui/Settings.swift gui/Views.swift gui/main.swift \
  -o "$APP/Contents/MacOS/WCooler"

cp gui/Info.plist "$APP/Contents/Info.plist"
cp gui/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# ad-hoc 签名：避免每次开机都被 Gatekeeper 拦一次蓝牙权限
codesign -s - --force --deep "$APP" 2>/dev/null || echo "（跳过签名）"

echo "构建完成：$PWD/$APP"
echo "运行：  open $APP"
