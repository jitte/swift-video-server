#!/bin/bash
# 壊れた動画の検証用サンプルを作る。
#
# 手元の古い FLV で「直前のタグの長さ」欄だけが壊れたものがあり、
# ffmpeg が "Packet mismatch" を出していた。実物は共有できないので、
# 正常な FLV を作ってから同じ壊れ方を再現する。
#
#   good.flv  正常
#   bad1.flv  先頭のタグだけ壊れている (実物と同じ症状。指摘は出るが読める)
#   bad.flv   全タグが壊れている (-flv_ignore_prevtag が無いと開けない)
#
# FLV はブラウザにそのまま渡せないので、どれもサーバ側の変換を通る。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-media/broken-samples}"

command -v ffmpeg >/dev/null || { echo "ffmpeg が見つかりません" >&2; exit 1; }

mkdir -p "$OUT"

echo "==> 正常な FLV を生成"
# 実物に合わせて Constrained Baseline の H.264 + AAC にする。
ffmpeg -y -v error \
    -f lavfi -i testsrc=size=640x360:rate=30 \
    -f lavfi -i sine=frequency=440:sample_rate=44100 \
    -t 30 -g 60 \
    -c:v libx264 -profile:v baseline -pix_fmt yuv420p \
    -c:a aac -b:a 64k \
    "$OUT/good.flv"
echo "  good.flv"

echo "==> 壊す"
swift Scripts/BreakFLV.swift "$OUT/good.flv" "$OUT/bad1.flv" first
swift Scripts/BreakFLV.swift "$OUT/good.flv" "$OUT/bad.flv" all

echo "完成: $OUT"
ls -la "$OUT"
