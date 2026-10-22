#!/bin/sh
# 从 gui/Resources/appicon-1024.png 重新生成 AppIcon.icns
set -e
cd "$(dirname "$0")/.."
DIR="gui/Resources"
SRC="$DIR/appicon-1024.png"
SET="$DIR/AppIcon.iconset"
mkdir -p "$SET"
rm -f "$SET"/icon_*.png
for spec in "16 1" "16 2" "32 1" "32 2" "128 1" "128 2" "256 1" "256 2" "512 1" "512 2"; do
    base=$(echo "$spec" | cut -d' ' -f1)
    scale=$(echo "$spec" | cut -d' ' -f2)
    px=$((base * scale))
    if [ "$scale" = "2" ]; then suffix="@2x"; else suffix=""; fi
    sips -z "$px" "$px" "$SRC" --out "$SET/icon_${base}x${base}${suffix}.png" >/dev/null
done
iconutil -c icns "$SET" -o "$DIR/AppIcon.icns"
echo "图标已生成：$DIR/AppIcon.icns"
