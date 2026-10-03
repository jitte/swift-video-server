#!/bin/bash
# VR 表示の検証用サンプル動画を作る。
#
# 実写の VR 素材では「上下が反転している」「左右の目が入れ替わっている」
# といった不具合に気づけないため、方向を文字で書いたパターンを用意する。
# 正面を向いて FRONT が正面に見え、文字が鏡像になっておらず、
# 立体版で L が見えれば正しく表示できている。
#
# 出力は H.264 + AAC の mp4 にする。この組み合わせはブラウザ版
# クライアントがダイレクト再生するため、HLS 経由かどうかという
# 別の要因を切り離して VR の表示だけを確かめられる。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-media/vr-samples}"

command -v ffmpeg >/dev/null || { echo "ffmpeg が見つかりません" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "==> パターンを生成"
swift Scripts/MakeVRPatterns.swift "$TMP"

echo "==> 動画に変換"
mkdir -p "$OUT"
for f in "$TMP"/*.png; do
    name=$(basename "$f" .png)
    # 静止画なので尺は短くてよい。無音の音声を付けておくと
    # ダイレクト再生の判定 (mp4 + H.264 + AAC) を満たせる。
    ffmpeg -y -v error \
        -loop 1 -i "$f" \
        -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=48000 \
        -t 20 -r 30 -g 60 \
        -c:v libx264 -profile:v high -pix_fmt yuv420p -crf 23 \
        -c:a aac -b:a 128k -shortest -movflags +faststart \
        "$OUT/$name.mp4"
    echo "  $name.mp4"
done

echo "完成: $OUT"
ls -la "$OUT"
