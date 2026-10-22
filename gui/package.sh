#!/bin/sh
# 把 dist/水冷魔盒.app 打成 dist/WCooler-app.zip
# 用 Python 的 zipfile 而不是系统 zip：它会给非 ASCII 文件名设置 UTF-8 标志位（0x800），
# 否则不同工具解压中文名可能变成乱码（macOS 的 zip / ditto 都不会置这个标志）。
set -e
cd "$(dirname "$0")/.."
APP="dist/水冷魔盒.app"
OUT="dist/WCooler-app.zip"
[ -d "$APP" ] || { echo "找不到 $APP，先跑 sh gui/build.sh"; exit 1; }
rm -f "$OUT"
python3 - "$APP" "$OUT" <<'PY'
import os, stat, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for root, dirs, files in os.walk(src):
        dirs.sort(); files.sort()
        for name in dirs + files:
            p = os.path.join(root, name)
            st = os.lstat(p)
            zi = zipfile.ZipInfo(os.path.relpath(p, "."))
            zi.external_attr = (stat.S_IMODE(st.st_mode) << 16) | (0x10 if stat.S_ISDIR(st.st_mode) else 0)
            z.writestr(zi, b"" if stat.S_ISDIR(st.st_mode) else open(p, "rb").read())
print("打包完成：%s" % out)
PY
