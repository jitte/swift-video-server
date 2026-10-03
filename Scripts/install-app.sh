#!/bin/bash
# 組み立てた Swift Video Server.app を /Applications へ入れ替える。
#
# build-app.sh はその作業ツリーの build/ に作るため、worktree を増やすと
# 同じ net.jitte.swift-video-server が複数の場所に出来る。どれが動いているのか分からなくなり、
# 直したはずの修正が入っていないものを触る事故が起きる。
# 常用するものは /Applications の 1 つに決め、ここから入れ替える。
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-release}"
DEST="/Applications/Swift Video Server.app"

./Scripts/build-app.sh "$MODE"

# 入れ替える前に終える。動いたまま中身を差し替えると、
# 署名が合わなくなった時点で OS に落とされる。
#
# 待つのは $DEST から動いているプロセスだけで、秒数では打ち切らない。
# 終了処理 (変換中の ffmpeg の後始末など) は 10 秒を超えることがあり、
# 決め打ちの秒数で中止すると、終わりかけのものを残してやり直しになっていた。
# 固まって終わらない場合は Ctrl-C で抜ける。
echo "==> 動いているものを終了"
PIDS=$(pgrep -f "$DEST/Contents/MacOS/SwiftVideoServer" || true)
if [ -n "$PIDS" ]; then
    osascript -e 'tell application id "net.jitte.swift-video-server" to quit' >/dev/null 2>&1 || true
    WAITED=0
    for pid in $PIDS; do
        # 他人が起動したプロセスは wait できないので、消えるまで見に行く。
        while kill -0 "$pid" 2>/dev/null; do
            sleep 1
            WAITED=$((WAITED + 1))
            if [ $((WAITED % 5)) -eq 0 ]; then
                echo "  終了を待っています (PID $pid, ${WAITED} 秒)"
            fi
        done
    done
fi

echo "==> $DEST へ入れ替え"
rm -rf "$DEST"
# ditto は拡張属性と署名をそのまま運ぶ。cp -R だと署名が壊れることがある。
ditto "build/Swift Video Server.app" "$DEST"

echo "==> 起動"
open "$DEST"

REV="$(git rev-parse --short HEAD 2>/dev/null || echo 不明)"
echo "入れ替えました: $DEST ($MODE, $REV)"
