#!/bin/bash
# アプリのアイコン (Assets/AppIcon.icns) を作り直す。
#
# 原画は Scripts/MakeAppIcon.swift が描く。swift の実行に数秒かかるため
# build-app.sh では毎回作らず、出来上がった .icns をリポジトリに置いておく。
# 絵を変えたときだけこれを走らせ、Assets/AppIcon.icns ごとコミットする。
set -euo pipefail
cd "$(dirname "$0")/.."

# 作業場所は管理外の build/ に置く。
WORK="build/icon-work"
rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

echo "==> 原画を描く"
swift Scripts/MakeAppIcon.swift "$WORK/AppIcon.png"

# iconutil が求める名前と大きさの組。@2x は 1 つ上の大きさを縮めて作る。
echo "==> 各サイズへ縮小"
SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$WORK/AppIcon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" "$WORK/AppIcon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done

echo "==> .icns に固める"
mkdir -p Assets
iconutil -c icns "$SET" -o Assets/AppIcon.icns

echo "完成: Assets/AppIcon.icns"
