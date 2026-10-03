#!/bin/bash
# メニューバー常駐アプリ (Swift Video Server.app) を組み立てる。
#
# SwiftPM は .app バンドルを作れないので、実行ファイルを作ってから
# 手でバンドル構造を組む。LSUIElement を立てることで
# Dock にアイコンを出さずメニューバーだけに常駐する。
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Swift Video Server.app"

# 作り方を選ぶ。既定は debug。
#
#   debug   (既定) 最適化なし。1 ファイル変更で約 2 秒。直している間はこれ。
#   fast          -O のままモジュール一括最適化 (WMO) をやめる。約 4 秒。
#   release       配布用と速度の計測用。約 10 秒。
#
# release が既定でとる WMO は「1 モジュール = 1 つのコンパイル処理」なので、
# 1 ファイル直しただけでも VideoServerKit 全体を 1 コアで作り直す
# (この構成では他のコアが遊んだまま約 10 秒)。
# ファイル単位に分ければ並列に走るが、最適化の範囲はモジュール内から
# ファイル内へ狭まる。速度を測るときと配布するときは release で作る。
#
# 重い処理は ffmpeg と ffprobe (別プロセス) なので、debug でも実用上は困らない。
# 実測: 一覧 (340KB) は release 32ms に対し debug 37ms、
#       サムネイルは 9ms に対し 12ms。
MODE="${1:-debug}"
EXTRA=""
case "$MODE" in
    debug)   CONFIG="debug" ;;
    release) CONFIG="release" ;;
    fast)
        CONFIG="release"
        # 引数に空白は入らないので、ここは分割されてよい。
        EXTRA="-Xswiftc -no-whole-module-optimization"
        ;;
    *)
        echo "使い方: $0 [debug|fast|release]" >&2
        exit 2
        ;;
esac

echo "==> ビルド ($MODE)"
swift build -c "$CONFIG" --product VideoServerApp $EXTRA

BIN=".build/$CONFIG/VideoServerApp"
[ -x "$BIN" ] || { echo "実行ファイルが見つかりません: $BIN" >&2; exit 1; }

echo "==> バンドル組み立て"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SwiftVideoServer"

# ブラウザ版クライアントの静的ファイルは SwiftPM がリソースバンドルに固める。
# Bundle.module は Contents/Resources を見るので、そこへ置く。
# 忘れると .app 版だけブラウザ版が 404 になる (コマンドライン版は .build 直下を見るので気付けない)。
BUNDLE=".build/$CONFIG/swift-video-server_VideoServerKit.bundle"
if [ -d "$BUNDLE" ]; then
    cp -R "$BUNDLE" "$APP/Contents/Resources/"
else
    echo "警告: リソースバンドルが見つかりません: $BUNDLE" >&2
fi

# アイコン。作り直すときは Scripts/make-app-icon.sh を走らせる。
cp Assets/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Swift Video Server</string>
    <key>CFBundleDisplayName</key>
    <string>Swift Video Server</string>
    <key>CFBundleIdentifier</key>
    <string>net.jitte.swift-video-server</string>
    <key>CFBundleExecutable</key>
    <string>SwiftVideoServer</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <!-- Dock に出さずメニューバーだけに常駐する -->
    <key>LSUIElement</key>
    <true/>
    <!-- ローカルネットワーク上のクライアントから接続を受ける -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>同じネットワーク上のブラウザに動画を配信します。</string>
</dict>
PLIST
echo "</plist>" >> "$APP/Contents/Info.plist"

# どのコミットから作ったかを埋める。作業ツリーが増えると、
# 動いているものがどの版か分からなくなるため。
# 例: defaults read "/Applications/Swift Video Server.app/Contents/Info.plist" CFBundleVersion
REV="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
git diff --quiet 2>/dev/null || REV="$REV+"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $REV-$MODE" "$APP/Contents/Info.plist" >/dev/null

# 署名。開発者証明書が無い環境でも動くよう ad-hoc で署名する。
echo "==> 署名 (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "完成: $APP"
echo "起動: open \"$APP\""
