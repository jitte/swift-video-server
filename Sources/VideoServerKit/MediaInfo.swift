import Foundation
import VideoServerCore

/// ffprobe で調べた動画の情報のうち、再生方法を決めるのに使うもの。
/// MediaInfoCache がディスクに保存する。
public struct MediaInfo: Sendable, Codable {
    public var durationSeconds: Double
    public var bitrate: Int
    public var videoStreams: [VideoStream]
    public var audioStreams: [AudioStream]

    public struct VideoStream: Sendable, Codable {
        public var codec: String
        public var width: Int
        public var height: Int
        /// ffprobe の profile を小文字にしたもの (例: high)。
        public var profile: String
        /// H.264 の avcC (MP4 の codec_data) の 16 進。
        /// HLS のプレイリストに書く CODECS 属性をここから作る。
        public var codecData: String
        /// ffprobe の pix_fmt (例: yuv420p)。ブラウザに直接渡せるかの判断に使う。
        public var pixelFormat: String
    }

    public struct AudioStream: Sendable, Codable {
        public var codec: String
        public var channels: Int
        public var sampleRate: Int
    }

    // MARK: ffprobe

    /// ffprobe で調べる。job を渡すと取り消しと優先度が効く。
    static func runProbe(url: URL, job: WorkQueue.Job? = nil) -> MediaInfo? {
        guard let ffprobe = locateFFprobe() else { return nil }
        let arguments = [
            "-v", "error", "-print_format", "json",
            "-show_format", "-show_streams", "-show_data",
        ] + inputOptions(for: url) + [url.path]
        let result = Shell.run(ffprobe, arguments, job: job)
        guard result.status == 0,
              let root = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any]
        else {
            // 調べられなかった理由を残す。ここを捨てていたため、
            // 再生できない動画が「情報なし」としか分からなかった。
            if !(job?.isCancelled ?? false) {
                Log.warn("ffprobe が失敗しました (終了コード \(result.status)) "
                         + "\(url.lastPathComponent)"
                         + Self.errorSuffix(result.errorText))
            }
            return nil
        }

        let format = root["format"] as? [String: Any] ?? [:]
        let duration = Double(format["duration"] as? String ?? "") ?? 0
        let bitrate = Int(format["bit_rate"] as? String ?? "") ?? 0

        var videos: [VideoStream] = []
        var audios: [AudioStream] = []
        for s in (root["streams"] as? [[String: Any]] ?? []) {
            let codec = (s["codec_name"] as? String) ?? "unknown"
            switch s["codec_type"] as? String {
            case "video":
                videos.append(VideoStream(
                    codec: codec,
                    width: (s["width"] as? Int) ?? 0,
                    height: (s["height"] as? Int) ?? 0,
                    profile: ((s["profile"] as? String) ?? "").lowercased(),
                    codecData: Self.parseExtradata(s["extradata"] as? String),
                    pixelFormat: (s["pix_fmt"] as? String)?.lowercased() ?? ""
                ))
            case "audio":
                audios.append(AudioStream(
                    codec: codec,
                    channels: (s["channels"] as? Int) ?? 0,
                    sampleRate: Int(s["sample_rate"] as? String ?? "") ?? 0
                ))
            default:
                continue
            }
        }
        guard !videos.isEmpty || !audios.isEmpty else { return nil }

        return MediaInfo(durationSeconds: duration, bitrate: bitrate,
                         videoStreams: videos, audioStreams: audios)
    }

    /// ログに添える標準エラーの先頭数行。全部載せると壊れたファイルで溢れる。
    static func errorSuffix(_ text: String, lines: Int = 3) -> String {
        let picked = Diagnostics.messageLines(text, limit: lines)
        return picked.isEmpty ? "" : ": " + picked.joined(separator: " / ")
    }

    /// ffprobe の extradata は 16 進ダンプ形式で返る。
    ///   "\n00000000: 0164 001f ffe1 ...  .d......\n"
    /// ここから 16 進部分だけを取り出して連結する。
    static func parseExtradata(_ dump: String?) -> String {
        guard let dump else { return "" }
        var hex = ""
        for line in dump.split(separator: "\n") {
            // "オフセット: 16進 16進 ...  ASCII" の中央部分だけを使う。
            guard let colon = line.firstIndex(of: ":") else { continue }
            let rest = line[line.index(after: colon)...]
            for token in rest.split(separator: " ") {
                // ASCII 表示部に入ったら打ち切る。
                guard token.count == 4 || token.count == 2,
                      token.allSatisfy({ $0.isHexDigit }) else { break }
                hex += token
            }
        }
        return hex.lowercased()
    }

    static func locateFFprobe() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/usr/bin/ffprobe",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// ffmpeg / ffprobe の `-i` の前に置く、入力の読み方の指定。
    ///
    /// FLV には各タグの後ろに「直前のタグの長さ」が書いてあり、ffmpeg は
    /// これが合わないと "Packet mismatch" を出して、そのタグを捨てて読み直す。
    /// 書き出したソフトによってはこの欄だけが壊れていて (0x0EFA が 0x0EFA0000
    /// になっている等)、中身は無事でも指摘が出る。全タグで壊れていると
    /// 読み直しが続かず開くことすらできない。この欄は読むのに要らないので無視させる。
    ///
    /// FLV 以外に渡すと "Option not found" で ffmpeg が落ちるため、拡張子で分ける。
    static func inputOptions(for url: URL) -> [String] {
        url.pathExtension.lowercased() == "flv" ? ["-flv_ignore_prevtag", "1"] : []
    }
}
