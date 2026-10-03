# Swift Video Server

ブラウザで観る動画サーバ。Mac の共有フォルダにある動画を、
iPad などのブラウザで一覧・再生できる。

サーバは HTML/JS と動画を配るだけで、再生と UI はブラウザ側で行う。
画面を映像として送る方式ではないので、二重エンコードによる劣化も往復遅延もない。
ブラウザがそのまま再生できない形式は、サーバが HLS に詰め替えるか変換して配る。

開くアドレスは `https://<サーバ>:44433/`。

## できること

### ブラウザ版クライアント

- 一覧、サムネイル、名前順/日付順の並べ替え、名前での絞り込み
- 再生 (mp4/H.264/AAC はダイレクト、それ以外は HLS に変換)
- シークバー、±30 秒、再生速度、全画面
- 左右スワイプでシーク。送り先の時刻とコマ画像を表示
- VR 表示 (360° / 180° / 魚眼 180°、左右分割・上下分割の立体視、
  姿勢センサー追随、二本指ドラッグでの視点操作)
- PIN による入室制限 (任意。既定では要求しない)

### サーバ

- 同一ポートで平文 HTTP と TLS を自動判別して待受
- Range 対応のストリーム配信 (無変換の直接再生)
- HLS 配信 (非対応の容器・コーデックの詰め替えと変換)
- サムネイルとスクラブ用コマ画像の生成
- ffprobe によるメディア情報の取得と、ディスクへの永続キャッシュ
- メニューバー常駐アプリ (共有フォルダとポートの設定、サーバ状態とログ、
  ログとキャッシュの削除)

未対応: Bonjour 自動発見、字幕。

## ビルドと実行

コマンドラインで動かす場合:

```sh
swift build -c release
.build/release/swift-video-server --media /path/to/movies
```

メニューバー常駐アプリとして使う場合:

```sh
./Scripts/install-app.sh        # 組み立てて /Applications へ入れ替え、起動する
```

`build-app.sh` はその作業ツリーの `build/` に `Swift Video Server.app` を作る。
worktree を増やすと同じアプリが複数の場所に出来てしまい、
どれが動いているのか分からなくなるので、常用するものは
`install-app.sh` で `/Applications` の 1 つに決める (既定は release)。

作った場所でそのまま試すこともできる。

```sh
./Scripts/build-app.sh          # 既定は debug
open "build/Swift Video Server.app"
```

どの版が動いているかは、アプリのバージョンに埋めたコミットで分かる。

```sh
defaults read "/Applications/Swift Video Server.app/Contents/Info.plist" CFBundleVersion
# 807b4b6-release   (末尾の + は未コミットの変更あり)
```

作り方は三つある。

| 指定 | 1 ファイル変更後 | 用途 |
|---|---|---|
| (無指定) / `debug` | 約 2 秒 | 直している間 |
| `fast` | 約 4 秒 | -O は効かせたまま速く作りたいとき |
| `release` | 約 10 秒 | 配布用、速度の計測 |

release が既定でとる「1 モジュール = 1 つのコンパイル処理」(WMO) は、
1 ファイル直しただけでもモジュール全体を 1 コアで作り直す (他のコアは遊ぶ)。
`fast` はこれをやめてファイル単位に分け、並列に作る。
最適化の範囲がモジュール内からファイル内へ狭まるので、
速度を測るときと配布するときは `release` で作る。

重い処理は ffmpeg と ffprobe (別プロセス) なので、debug でも実用上は困らない。
実測では一覧 (340KB) が release 32ms に対し debug 37ms、
サムネイルが 9ms に対し 12ms だった。

`fast` と `release` は作り分けを共有しないので、
行き来すると毎回すべて作り直す (約 1 分)。直している間はどちらかに決めておく。

### 起動オプション (コマンドライン版)

| オプション | 内容 |
|---|---|
| `--media <パス>` | 共有フォルダを追加して保存する |
| `--port <番号>` | 待受ポートを変える (設定に保存される) |
| `--support-dir <パス>` | 設定・証明書・キャッシュ・ログの置き場所をまるごと移す |

`--support-dir` は動作確認用。本番の設定や証明書に触れずにサーバを動かせる。
`--port` は設定ファイルを書き換えるため、確認目的なら `--support-dir` と
併用するとよい。

## HTTPS

ブラウザ版で姿勢センサー (`DeviceOrientationEvent`) を使うには
secure context が要る。そのため初回起動時にローカル CA を 1 つ作り、
それでサーバ証明書に署名する。

端末に信頼させる手順:

1. Safari で `http://<サーバ>:44433/cert.crt` を開き、CA をインストール
2. 設定 → 一般 → VPN とデバイス管理 → プロファイルをインストール
3. 設定 → 一般 → 情報 → **証明書信頼設定**で有効化 (この手順を飛ばすと信頼されない)
4. `https://<サーバ>:44433/` を開く

平文 HTTP で受けるのは `/cert.crt` だけで、それ以外は同じポートの HTTPS へ転送する。

サーバ証明書の有効期間は 397 日。Apple の信頼評価は長すぎる証明書を
拒むため (詳細は [docs/design.md](docs/design.md))。
残り 30 日を切ると起動時に作り直す。CA は 10 年なので、
更新時に端末へ入れ直す必要はない。

## PIN

設定画面で 4〜8 桁の数字を決めておくと、ブラウザで開いたときに入力を求める。
未設定なら誰でも開ける (既定)。

- 受け渡しは Cookie (HTTPS のときだけ送られる)。`<video>` や `<img>` は
  ブラウザが自前で要求を出すため、ヘッダでは持ち回せない
- トークンはサーバのメモリにだけ置く。サーバを止めると入力し直しになる
- PIN を変えると、発行済みのセッションは自動的に無効になる
- 10 回続けて間違えると 60 秒受け付けない

**守る範囲は `/api` (一覧・閲覧) と、`/stream` (ダイレクト再生)・`/hls` (変換再生)。**
配信の URL には推測できない鍵も入っているが、URL が漏れても PIN を
入力していない端末では再生できない。画面そのもの (`/`) と `/cert.crt` は対象外。

LAN 内で「他の人が勝手に開かない」程度の用途を想定している。

## 保存場所

既定ポートは 44433。設定、証明書、各種キャッシュは
`~/Library/Application Support/swift-video-server/` に保存される
(`--support-dir` で変更可)。

| ファイル | 内容 |
|---|---|
| `config.json` | サーバ名、ポート、共有フォルダ、PIN |
| `ca.pem` / `ca-key.pem` / `ca.srl` | ローカル CA |
| `cert.pem` / `key.pem` | サーバ証明書 |
| `mediainfo.json` | ffprobe の結果 |
| `snapshots.json` / `snapshots/` | サムネイルの索引と画像 |
| `previews.json` / `previews/` | スクラブ用スプライトシート |
| `sessions/` | 変換中の一時セグメント (再生終了で消える) |
| `swift-video-server.log` | 動作ログ |

ログとキャッシュは設定画面から種類ごとに削除できる。
設定と証明書は誤って消さないよう、削除の対象に含めていない。

## 検証用の素材

再生方式ごとの確認には、手元の動画から容器やコーデックを変えたものを作る。

```sh
# ダイレクト再生 (H.264 + AAC の mp4)
ffmpeg -i src.mp4 -t 30 -c:v libx264 -pix_fmt yuv420p -c:a aac direct.mp4
# 詰め替え (中身は H.264 のまま、容器だけ非対応)
ffmpeg -i direct.mp4 -c copy remux.mkv
# 再エンコード (映像のコーデックも非対応)
ffmpeg -i direct.mp4 -c:v mpeg4 -c:a libmp3lame transcode.avi
```

VR 表示の確認には、方向を文字で描いたパターンを使う。
実写素材では上下の反転や左右の目の取り違えに気づけないため。

```sh
./Scripts/make-vr-samples.sh          # 既定は media/vr-samples へ
```

360°・180°・魚眼と、それぞれの立体視版を生成する。
正面を向いて FRONT が正面に見え、文字が鏡像でなく、
立体版で `L` が見えれば正しく表示できている。

壊れた動画への対処の確認には、わざと壊した FLV を使う。

```sh
./Scripts/make-broken-samples.sh      # 既定は media/broken-samples へ
```

「直前のタグの長さ」欄が壊れた FLV を、先頭だけのもの (`bad1.flv`) と
全タグのもの (`bad.flv`)、比較用の正常なもの (`good.flv`) の 3 本作る。
どれも再生でき、診断の検査で異常が出なければ対処できている。

## 依存

macOS 13 以降と Swift 6 のツールチェーン (Xcode 16 以降) で動く。

`ffmpeg` と `ffprobe` が必要 (メディア情報の取得、変換、サムネイル生成)。
同梱していないので、Homebrew などで導入し、`/opt/homebrew/bin` か
`/usr/local/bin` に置く。

証明書の生成には `openssl` を使う (macOS 標準の LibreSSL で動く)。

## 設計と実装メモ

再生方式の選び方、HLS の組み立て方、NAS 上での性能対策、
仕様書に載っておらず実機で潰すしかなかった事柄
(証明書が iOS に拒否される条件、姿勢センサーの合成順序、ffmpeg の癖) は
[docs/design.md](docs/design.md) に記録している。

## ライセンス

MIT License。[LICENSE](LICENSE) を参照。

依存している Swift パッケージは、いずれも Apache License 2.0。

| パッケージ | 用途 |
|---|---|
| [swift-nio](https://github.com/apple/swift-nio) | HTTP サーバ |
| [swift-nio-ssl](https://github.com/apple/swift-nio-ssl) | TLS (内部に BoringSSL を含む。BoringSSL 由来の部分は OpenSSL / ISC ライセンス) |
| swift-atomics / swift-collections / swift-system | 上の 2 つが使う |

ffmpeg / ffprobe は別プロセスとして呼び出すだけで、同梱も改変もしていない。
導入した ffmpeg のライセンス (LGPL / GPL、ビルド時の構成による) は利用者の側で確認すること。
