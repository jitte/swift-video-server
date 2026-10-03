import Foundation
import VideoServerKit

// リダイレクト時も起動ログが即座に出るようにする。
setvbuf(stdout, nil, _IOLBF, 0)

// 簡易な引数処理。
//   swift-video-server                       設定ファイルの共有フォルダを使う
//   swift-video-server --media <path>        共有フォルダを指定して保存する
//   swift-video-server --port <n>            待受ポートを変える
//   swift-video-server --support-dir <path>  設定・証明書・キャッシュの置き場所を変える
var mediaPath: String?
var portOverride: Int?
var supportDir: String?

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "--media":
        if i + 1 < args.count { mediaPath = args[i + 1]; i += 1 }
    case "--port":
        if i + 1 < args.count { portOverride = Int(args[i + 1]); i += 1 }
    case "--support-dir":
        if i + 1 < args.count { supportDir = args[i + 1]; i += 1 }
    case "--help", "-h":
        print("""
        swift-video-server - ブラウザで観る動画サーバ

        使い方:
          swift-video-server [--media <共有フォルダ>] [--port <ポート>] [--support-dir <パス>]

        既定のポートは \(Configuration.defaultPort)。設定と証明書は
        ~/Library/Application Support/swift-video-server/ に保存されます。

        --support-dir を指定すると、設定・証明書・キャッシュ・ログの
        置き場所をまるごとそこへ移せます。本番の設定に触れずに
        動作を確かめたいときに使います。
        """)
        exit(0)
    default:
        break
    }
    i += 1
}

// 設定・証明書・キャッシュを読む前に置き場所を決める。
if let supportDir {
    Configuration.useSupportDirectory(supportDir)
}

do {
    var config = try Configuration.load(defaultMediaPath: mediaPath)
    if let portOverride {
        config.port = portOverride
        try config.save()
    }
    let server = VideoServer(config: config)
    try server.run()
} catch {
    FileHandle.standardError.write(Data("起動に失敗しました: \(error)\n".utf8))
    exit(1)
}
