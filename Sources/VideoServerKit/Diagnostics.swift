import Foundation
import VideoServerCore

/// 動画の形式を詳しく調べ、壊れていないかを検査する。
///
/// 「再生できない」の切り分けに使う。ブラウザが黙って黒画面になる場合でも、
/// ここを見ればコンテナ・コーデック・画素形式まで分かる。
/// ブラウザが扱えない組み合わせなのか、ファイル自体が壊れているのかは
/// 症状が同じ (無音の黒画面) なので、見分ける手立てがないと辿り着けない。
enum Diagnostics {

    // MARK: ffprobe

    /// ffprobe を走らせ、JSON と標準エラーの行を返す。
    ///
    /// `-v warning` にしてあるのは、壊れたファイルの指摘 (moov が無い、
    /// タイムスタンプが飛んでいる等) が標準エラーにしか出ないため。
    /// 既存の MediaInfo.runProbe は `-v error` で、しかも捨てていた。
    static func probe(url: URL, job: WorkQueue.Job? = nil)
        -> (root: [String: Any], messages: [String]) {
        guard let ffprobe = MediaInfo.locateFFprobe() else {
            return ([:], ["ffprobe が見つかりません"])
        }
        let result = Shell.run(ffprobe, [
            "-v", "warning", "-print_format", "json",
            "-show_format", "-show_streams", "-show_error",
        ] + MediaInfo.inputOptions(for: url) + [url.path], job: job)
        let root = (try? JSONSerialization.jsonObject(with: result.output)) as? [String: Any] ?? [:]
        var messages = Self.messageLines(result.errorText)
        if result.status != 0, messages.isEmpty {
            messages.append("ffprobe が終了コード \(result.status) で終わりました")
        }
        return (root, messages)
    }

    /// 標準エラーを行に割り、重複と空行を落とす。
    /// 壊れたファイルは同じ指摘を何千行も出すので、そのまま見せない。
    static func messageLines(_ text: String, limit: Int = 40) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in text.split(separator: "\n") {
            // "[h264 @ 0x12ab00]" の番地は実行ごとに変わるだけで意味がない。
            // 落としておくと同じ指摘がまとまり、読む側も楽になる。
            let line = Self.pointerPattern
                .stringByReplacingMatches(
                    in: String(raw), range: NSRange(raw.startIndex..., in: raw),
                    withTemplate: "[$1]")
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, seen.insert(line).inserted else { continue }
            out.append(line)
            if out.count >= limit { break }
        }
        return out
    }

    /// ffmpeg が付ける "[h264 @ 0x12ab00]" の番地部分。
    static let pointerPattern = try! NSRegularExpression(
        pattern: #"\[([a-zA-Z0-9_]+) @ 0x[0-9a-f]+\]"#)

    // MARK: 形式の詳細

    /// 画面に出す形式情報を組み立てる。
    static func details(url: URL, size: Int, modified: Date) -> [String: JSONValue] {
        let (root, messages) = probe(url: url)
        let format = root["format"] as? [String: Any] ?? [:]
        let rawStreams = root["streams"] as? [[String: Any]] ?? []

        var videos: [JSONValue] = []
        var audios: [JSONValue] = []
        var others: [JSONValue] = []
        for s in rawStreams {
            switch s["codec_type"] as? String {
            case "video": videos.append(videoStream(s))
            case "audio": audios.append(audioStream(s))
            default: others.append(otherStream(s))
            }
        }

        var out: [String: JSONValue] = [
            "name": .string(url.lastPathComponent),
            "size": .int(size),
            "modified": .string(HTTPHandler.httpDate(modified)),
            "container": .object([
                "format": .string((format["format_long_name"] as? String) ?? "不明"),
                "formatName": .string((format["format_name"] as? String) ?? ""),
                "duration": .double(Double(format["duration"] as? String ?? "") ?? 0),
                "bitrate": .int(Int(format["bit_rate"] as? String ?? "") ?? 0),
                "streamCount": .int(rawStreams.count),
            ]),
            "video": .array(videos),
            "audio": .array(audios),
            "other": .array(others),
            "probeMessages": .array(
                dropDataStreamNotices(messages, streams: rawStreams).map { .string($0) }),
        ]

        // ffprobe がエラーを返した (開けない) ときは、その理由をそのまま出す。
        if let err = root["error"] as? [String: Any] {
            out["fatal"] = .string((err["string"] as? String) ?? "ファイルを開けません")
        }

        // 再生の見立て。ブラウザにそのまま渡せるかと、その理由。
        let info = MediaInfoCache.shared.lookup(url: url, size: size, modified: modified)
        let verdict = directPlay(url: url, streams: rawStreams)
        out["playback"] = .object([
            "direct": .bool(verdict.ok),
            "mode": .string(verdict.ok ? "direct" : "transcode"),
            "reasons": .array(verdict.reasons.map { .string($0) }),
            "duration": .double(info?.durationSeconds ?? 0),
        ])
        return out
    }

    /// ffprobe の level は 31 のような整数で来る。見慣れた 3.1 の形で出す。
    private static func levelString(_ level: Int?) -> String {
        guard let level, level > 0 else { return "" }
        return "\(level / 10).\(level % 10)"
    }

    private static func videoStream(_ s: [String: Any]) -> JSONValue {
        let fr = frameRate(s["avg_frame_rate"] as? String ?? s["r_frame_rate"] as? String)
        return .object([
            "index": .int((s["index"] as? Int) ?? 0),
            "codec": .string((s["codec_name"] as? String) ?? "不明"),
            "codecLong": .string((s["codec_long_name"] as? String) ?? ""),
            "profile": .string((s["profile"] as? String) ?? ""),
            "level": .string(levelString(s["level"] as? Int)),
            "width": .int((s["width"] as? Int) ?? 0),
            "height": .int((s["height"] as? Int) ?? 0),
            "pixelFormat": .string((s["pix_fmt"] as? String) ?? ""),
            "bitDepth": .int(Int(s["bits_per_raw_sample"] as? String ?? "") ?? 0),
            "frameRate": .double(fr),
            "bitrate": .int(Int(s["bit_rate"] as? String ?? "") ?? 0),
            "frames": .int(Int(s["nb_frames"] as? String ?? "") ?? 0),
            "fieldOrder": .string((s["field_order"] as? String) ?? ""),
        ])
    }

    private static func audioStream(_ s: [String: Any]) -> JSONValue {
        .object([
            "index": .int((s["index"] as? Int) ?? 0),
            "codec": .string((s["codec_name"] as? String) ?? "不明"),
            "codecLong": .string((s["codec_long_name"] as? String) ?? ""),
            "profile": .string((s["profile"] as? String) ?? ""),
            "channels": .int((s["channels"] as? Int) ?? 0),
            "channelLayout": .string((s["channel_layout"] as? String) ?? ""),
            "sampleRate": .int(Int(s["sample_rate"] as? String ?? "") ?? 0),
            "bitrate": .int(Int(s["bit_rate"] as? String ?? "") ?? 0),
            "language": .string(((s["tags"] as? [String: Any])?["language"] as? String) ?? ""),
        ])
    }

    /// 映像・音声以外のストリームについての「デコーダが無い」を落とす。
    ///
    /// iPhone やカメラの MOV には bin_data 等のデータトラックが付いていることがあり、
    /// ffprobe はそのデコーダを開こうとして
    /// "Unsupported codec with id 98314 for input stream 2" と言う。
    /// このサーバはデータトラックを読まない (ffmpeg も既定では選ばない) ので
    /// 再生には関係がなく、指摘として出すと壊れているように見えてしまう。
    /// ストリーム自体は「その他のストリーム」に出る。
    static func dropDataStreamNotices(_ messages: [String], streams: [[String: Any]]) -> [String] {
        let media = Set(streams.compactMap { s -> Int? in
            let type = s["codec_type"] as? String
            return type == "video" || type == "audio" ? s["index"] as? Int : nil
        })
        return messages.filter { line in
            let range = NSRange(line.startIndex..., in: line)
            guard let m = unsupportedCodecPattern.firstMatch(in: line, range: range),
                  let r = Range(m.range(at: 1), in: line),
                  let index = Int(line[r])
            else { return true }
            return media.contains(index)
        }
    }

    static let unsupportedCodecPattern = try! NSRegularExpression(
        pattern: #"Unsupported codec with id \d+ for input stream (\d+)"#)

    private static func otherStream(_ s: [String: Any]) -> JSONValue {
        .object([
            "index": .int((s["index"] as? Int) ?? 0),
            "type": .string((s["codec_type"] as? String) ?? "不明"),
            "codec": .string((s["codec_name"] as? String) ?? ""),
        ])
    }

    private static func frameRate(_ text: String?) -> Double {
        guard let parts = text?.split(separator: "/"), parts.count == 2,
              let num = Double(parts[0]), let den = Double(parts[1]), den > 0
        else { return 0 }
        return num / den
    }

    // MARK: 直接再生の見立て

    /// ブラウザ (iOS/macOS の Safari) にそのまま渡してよい組み合わせか。
    ///
    /// コーデック名だけで判断すると、H.264 でも 4:2:2 や 10bit のものは
    /// ブラウザが描けず、音も出ない真っ黒な画面になる。
    /// ffmpeg は読めるのでサムネイルやスプライトだけは出る、という食い違いが
    /// 起きるため、画素形式まで見て迷ったら変換に倒す。
    static func directPlay(url: URL, streams: [[String: Any]]) -> (ok: Bool, reasons: [String]) {
        var reasons: [String] = []

        let ext = url.pathExtension.lowercased()
        if !["mp4", "m4v", "mov"].contains(ext) {
            reasons.append("容器が \(ext.uppercased()) なので、ブラウザにそのままでは渡せません")
        } else if MP4Layout.isFragmented(url: url) {
            reasons.append("断片化した MP4 (DASH 用など) なので、Safari がそのままでは再生を始めません")
        }

        let videos = streams.filter { $0["codec_type"] as? String == "video" }
        let audios = streams.filter { $0["codec_type"] as? String == "audio" }

        if videos.isEmpty {
            reasons.append("映像が見つかりません")
        }
        if let v = videos.first {
            reasons.append(contentsOf: videoReasons(
                codec: (v["codec_name"] as? String) ?? "",
                pixelFormat: (v["pix_fmt"] as? String) ?? "",
                profile: (v["profile"] as? String) ?? ""))
        }

        // 音声は全部見る。1 本でも AAC でないものがあれば変換が要る
        // (実際の判定 WebAPI.canPlayDirectly も全部を見ている)。
        for a in audios {
            let codec = ((a["codec_name"] as? String) ?? "").lowercased()
            if !codec.contains("aac") {
                reasons.append("音声が \(codec.isEmpty ? "不明" : codec) なので、音を出すには変換が要ります")
            }
        }

        return (reasons.isEmpty && !videos.isEmpty, reasons)
    }

    /// 映像をブラウザがそのまま描けるか。描けないなら理由を返す。
    ///
    /// 容器とは別に判断する。HLS に詰め替えるときも、映像を無変換で通すか
    /// 再エンコードするかはここで決まる (詰め替えただけでは 4:2:2 は 4:2:2 のまま)。
    static func videoReasons(codec: String, pixelFormat: String, profile: String) -> [String] {
        let codec = codec.lowercased()
        let pix = pixelFormat.lowercased()
        var reasons: [String] = []

        let allowed: Set<String>
        switch codec {
        case "h264":
            // H.264 は 8bit の 4:2:0 だけ。10bit は Safari が描けない。
            allowed = ["yuv420p", "yuvj420p", "nv12"]
        case "hevc", "h265":
            // HEVC は Main と Main10 まで。
            allowed = ["yuv420p", "yuvj420p", "nv12", "yuv420p10le"]
        default:
            return ["映像が \(codec.isEmpty ? "不明" : codec) で、ブラウザが対応していません"]
        }

        if !allowed.contains(pix) {
            reasons.append("映像の画素形式が \(pix.isEmpty ? "不明" : pix) で、"
                           + "ブラウザが描けません"
                           + (codec == "h264" ? " (8bit の 4:2:0 のみ)" : " (4:2:0 の 8/10bit のみ)"))
        }
        let lowered = profile.lowercased()
        if lowered.contains("4:2:2") || lowered.contains("4:4:4")
            || lowered.contains("422") || lowered.contains("444") {
            reasons.append("映像のプロファイルが \(profile) で、ブラウザが対応していません")
        }
        return reasons
    }

    /// MediaInfo から同じ判断をする。再生を始めるときはこちらを使う。
    static func browserCanDecode(_ v: MediaInfo.VideoStream) -> Bool {
        videoReasons(codec: v.codec, pixelFormat: v.pixelFormat, profile: v.profile).isEmpty
    }

    // MARK: 壊れていないかの検査

    enum Depth: String {
        /// 先頭と末尾を少しだけデコードする。数秒で終わる。
        case quick
        /// 全編をデコードする。確実だが、NAS 上の大きな動画では数分かかる。
        case deep
    }

    /// 検査する秒数 (速い検査の先頭・末尾それぞれ)。
    static let quickSeconds = 10

    /// ffmpeg にデコードさせ、出た指摘を集める。
    ///
    /// 出力は捨てる (`-f null`) ので、読むのは元ファイルだけ。
    /// 壊れている箇所があれば標準エラーに出る。
    static func check(url: URL, depth: Depth, duration: Double, job: WorkQueue.Job) -> JSONValue {
        guard let ffmpeg = Transcoder.locateFFmpeg() else {
            return .object([
                "state": .string("done"), "ok": .bool(false),
                "messages": .array([.string("ffmpeg が見つかりません")]),
            ])
        }
        let began = Date()
        var messages: [String] = []
        var failed = false

        /// 1 回分。区間の指定は引数で渡す。
        func run(_ prefix: [String], label: String) {
            guard !job.isCancelled else { return }
            let result = Shell.run(ffmpeg, prefix + MediaInfo.inputOptions(for: url) + ["-i", url.path, "-f", "null", "-"], job: job)
            let lines = messageLines(result.errorText, limit: 20)
            if result.status != 0 { failed = true }
            if !lines.isEmpty || result.status != 0 {
                messages.append(contentsOf: lines.map { "\(label): \($0)" })
                if lines.isEmpty {
                    messages.append("\(label): ffmpeg が終了コード \(result.status) で終わりました")
                }
            }
        }

        // 尺が短いものを先頭と末尾に分けると区間が重なるだけで、
        // -sseof も効かない。まるごと見ても一瞬なので全編にする。
        let wholeFile = depth == .deep
            || (duration > 0 && duration <= Double(quickSeconds * 2))
        if wholeFile {
            run(["-v", "error"], label: "全編")
        } else {
            run(["-v", "error", "-t", "\(quickSeconds)"], label: "先頭")
            run(["-v", "error", "-sseof", "-\(quickSeconds)"], label: "末尾")
        }

        if job.isCancelled {
            return .object(["state": .string("none")])
        }

        return .object([
            "state": .string("done"),
            "depth": .string(depth.rawValue),
            "ok": .bool(!failed && messages.isEmpty),
            "messages": .array(messages.map { .string($0) }),
            "elapsed": .double(Date().timeIntervalSince(began)),
            "scope": .string(wholeFile ? "全編" : "先頭と末尾の各 \(quickSeconds) 秒"),
            "finishedAt": .string(HTTPHandler.httpDate(Date())),
        ])
    }
}

/// 子プロセスを動かして標準出力と標準エラーの両方を受け取る。
///
/// これまでは標準エラーを捨てていたため、ffmpeg や ffprobe が何に
/// つまずいたのかが残らず、「終了コード 1」しか分からなかった。
enum Shell {
    struct Result {
        var status: Int32
        var output: Data
        var errorText: String
    }

    static func run(_ executable: URL, _ arguments: [String], job: WorkQueue.Job? = nil) -> Result {
        // 取り消しと優先度を効かせたい場合は WorkQueue の仕掛けに任せる。
        if let job {
            let data = job.run(executable, arguments)
            return Result(status: job.lastStatus, output: data ?? Data(),
                          errorText: job.lastErrorText)
        }

        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        p.qualityOfService = .userInitiated
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            return Result(status: -1, output: Data(), errorText: "起動できません: \(error)")
        }
        // 両方のパイプを並行して読み切る。片方を待っている間に
        // もう片方が埋まると、子プロセスが書き込みで止まってしまう。
        var errData = Data()
        let reader = DispatchQueue(label: "swift-video-server.shell.stderr")
        let done = DispatchSemaphore(value: 0)
        reader.async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        done.wait()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, output: outData,
                      errorText: String(decoding: errData, as: UTF8.self))
    }
}

/// 検査は時間がかかるので、要求を受けたら背後で始めて結果をここに置く。
/// クライアントは同じ URL を叩き直して状態を見る。
final class DiagnoseStore: @unchecked Sendable {
    static let shared = DiagnoseStore()

    private let lock = NSLock()
    private var results: [String: JSONValue] = [:]
    private var running: [String: (depth: Diagnostics.Depth, startedAt: Date, token: Int)] = [:]
    /// 何度目の依頼か。古い検査の結果で新しいものを上書きしないための札。
    private var tokens = 0

    /// 検査を始める。既に同じ深さで走っていれば何もしない。
    /// 深さが変わったときは前の検査を止めてから入れ直す。
    func start(url: URL, depth: Diagnostics.Depth, duration: Double) {
        lock.lock()
        if let r = running[url.path], r.depth == depth { lock.unlock(); return }
        let wasRunning = running[url.path] != nil
        tokens += 1
        let token = tokens
        running[url.path] = (depth, Date(), token)
        results[url.path] = nil
        lock.unlock()

        // 走っている検査があれば先に止める。止めないと WorkQueue が
        // 同じ鍵の依頼を「実行中」として捨ててしまい、速い検査の結果で
        // 全編の検査が終わったことにされる。
        if wasRunning {
            WorkQueue.shared.cancel { $0.key.hasPrefix("diagnose:\(url.path)#") }
        }

        // 前景に入れる。利用者が今まさに見ている 1 件なので、
        // 一覧のサムネイル作りより先に片付けたい。
        WorkQueue.shared.submit(key: "diagnose:\(url.path)#\(token)",
                                scope: "diagnose:\(url.path)",
                                lane: .foreground) { [weak self] job in
            let result = Diagnostics.check(url: url, depth: depth, duration: duration, job: job)
            guard let self else { return }
            self.lock.lock()
            // 自分より後の依頼が始まっていたら、この結果は捨てる。
            if self.running[url.path]?.token == token {
                self.running[url.path] = nil
                self.results[url.path] = result
            }
            self.lock.unlock()
        }
    }

    /// 今の状態。走っていなければ最後の結果、それも無ければ state:"none"。
    func state(for url: URL) -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        if let r = running[url.path] {
            return .object([
                "state": .string("running"),
                "depth": .string(r.depth.rawValue),
                "elapsed": .double(Date().timeIntervalSince(r.startedAt)),
            ])
        }
        return results[url.path] ?? .object(["state": .string("none")])
    }

    /// 検査をやめる。画面を閉じたときに呼ぶ。
    func cancel(url: URL) {
        lock.lock(); running[url.path] = nil; lock.unlock()
        WorkQueue.shared.cancel { $0.key.hasPrefix("diagnose:\(url.path)#") }
    }
}
