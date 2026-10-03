import Foundation
import CryptoKit

/// ブラウザ版クライアントの静的ファイルを配る。
///
/// 実体は Sources/VideoServerKit/Resources/Public に置き、SwiftPM が作る
/// リソースバンドルごと配布する。
enum StaticFiles {
    /// バンドル内の Public/ の場所。見つからなければ nil。
    ///
    /// SwiftPM が生成する Bundle.module は使わない。あれは
    /// Bundle.main.bundleURL の直下だけを見るため、.app では
    /// Swift Video Server.app/swift-video-server_VideoServerKit.bundle という不自然な位置を要求するうえ、
    /// 見つからないと fatalError でプロセスごと落ちる。
    /// 静的ファイルが無いだけでサーバが死ぬのは割に合わないので、
    /// 候補を順に当たって、駄目なら nil を返す。
    static let root: URL? = {
        let name = "swift-video-server_VideoServerKit.bundle"
        var candidates: [URL] = []
        // .app では Contents/Resources に置く (バンドルとして自然な位置)。
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent(name))
        }
        // SwiftPM が既定で置く位置 (コマンドライン版はここ)。
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(name))
        // 実行ファイルと同じ場所。
        candidates.append(URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent(name))

        // バンドルの中身の置き方はツールの版で変わる。
        // 以前は直下に Public/ があったが、Xcode を更新したあとの SwiftPM では
        // macOS のバンドル形式 (Contents/Resources/Public) で作られるようになった。
        let layouts = ["Public", "Contents/Resources/Public"]
        for candidate in candidates {
            for layout in layouts {
                let publicDir = candidate.appendingPathComponent(layout)
                if FileManager.default.fileExists(atPath: publicDir.path) {
                    return publicDir
                }
            }
        }
        Log.info("ブラウザ版クライアントの静的ファイルが見つかりません")
        return nil
    }()

    struct File {
        var contentType: String
        var data: Data
        /// 内容から作る識別子。再ビルドで中身が変われば値も変わるので、
        /// ブラウザが古いファイルを使い続けるのを防げる。
        var etag: String
    }

    /// "/..." を Public/ 以下のファイルに解決する。"/" は index.html。
    /// 共有フォルダと同じく、外に出る相対パスは拒否する。
    static func lookup(path: String) -> File? {
        guard let root else { return nil }
        let base = root.standardizedFileURL

        let rel = (path.isEmpty || path == "/") ? "/index.html" : path
        // %20 などを戻してから解決する。
        let decoded = rel.removingPercentEncoding ?? rel

        let target = base.appendingPathComponent(decoded).standardizedFileURL
        guard target.path.hasPrefix(base.path + "/") else { return nil }
        guard let data = try? Data(contentsOf: target) else { return nil }

        // どれも数十 KB なので、要求のたびに計算しても負担にならない。
        let digest = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return File(contentType: contentType(for: target.pathExtension.lowercased()),
                    data: data,
                    etag: "\"\(digest.prefix(16))\"")
    }

    static func contentType(for ext: String) -> String {
        switch ext {
        case "html": return "text/html; charset=utf-8"
        case "js": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "webmanifest": return "application/manifest+json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        default: return "application/octet-stream"
        }
    }
}
