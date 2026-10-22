#!/bin/sh
# 协议一致性回归检查（不连设备，纯比对字节）
# 顶层语句只允许出现在 main.swift，所以这里把检查文件复制成 main.swift 再编译。
set -e
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
cp gui/ProtocolCheck.swift "$TMP/main.swift"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx11.0" \
  gui/Protocol.swift gui/CoolerEngine.swift gui/SMCReader.swift gui/Settings.swift "$TMP/main.swift" \
  -o "$TMP/pc"
"$TMP/pc"
rm -rf "$TMP"
