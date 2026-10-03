import Foundation

/// 1 つの再生セッションに対して ffmpeg を 1 回だけ走らせ、
/// セグメントをまとめて書き出させる。
///
/// セグメントを 1 本ずつ個別に切り出す方式は、
/// ffmpeg の入力シークが狙ったキーフレームより手前に戻るため
/// 区間が重なり、iOS 側で再生が途中で止まる
/// (CoreMediaErrorDomain error -12971)。
/// ffmpeg のセグメント分割機能に任せると、
/// 連続して重なりのない、キーフレームで始まる区間が得られる。
final class TranscodeJob: @unchecked Sendable {
    let directory: URL
    private let process = Process()
    private let lock = NSLock()
    private var finished = false
    private var suspended = false
    private var exitCodeValue: Int32?
    /// ffmpeg の標準エラーの置き場。
    private(set) var logURL: URL = URL(fileURLWithPath: "/dev/null")

    /// 終了していれば終了コード。走っている間は nil。
    var exitCode: Int32? { lock.lock(); defer { lock.unlock() }; return exitCodeValue }

    /// ffmpeg が書いた標準エラー。末尾だけを読む。
    func errorText(limitBytes: Int = 16 * 1024) -> String {
        guard let data = try? Data(contentsOf: logURL), !data.isEmpty else { return "" }
        return String(decoding: data.suffix(limitBytes), as: UTF8.self)
    }

    /// セグメントファイルの命名。
    static func segmentName(_ index: Int) -> String {
        String(format: "seg%05d.ts", index)
    }

    func segmentURL(_ index: Int) -> URL {
        directory.appendingPathComponent(Self.segmentName(index))
    }

    /// このジョブが担当する最初のセグメント番号。
    let startIndex: Int
    /// 担当する最後のセグメント番号 (尺の最後まで)。
    let lastIndex: Int

    /// 指定セグメントをこのジョブが produce しうるか。
    func canReach(_ index: Int) -> Bool {
        index >= startIndex && index <= lastIndex
    }

    init?(
        input: URL,
        boundaries: [Double],
        startIndex: Int = 0,
        video: VideoPlan,
        audioBitrateKbps: Int,
        directory: URL
    ) {
        self.directory = directory
        self.startIndex = startIndex
        self.lastIndex = boundaries.count - 1
        guard let ffmpeg = Transcoder.locateFFmpeg() else {
            Log.warn("ffmpeg が見つかりません")
            return nil
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 途中から始める場合はシークする。
        // -ss は狙った時刻より手前のキーフレームに乗ることがあるため、
        // 区切り位置はシーク地点からの相対時刻で渡して
        // ffmpeg 自身に正確に切らせる。
        let origin = boundaries[startIndex]
        var args = ["-v", "error"]
        if startIndex > 0 {
            args += ["-ss", String(format: "%.3f", origin)]
        }
        args += MediaInfo.inputOptions(for: input) + ["-i", input.path]
        if startIndex > 0 {
            // 絶対時刻を保って HLS の時間軸を崩さない。
            args += ["-copyts", "-avoid_negative_ts", "disabled"]
        }

        // このジョブが担当する区切り位置 (シーク地点からの相対)。
        let cutTimes = boundaries.dropFirst(startIndex + 1)
            .map { String(format: "%.3f", $0 - origin) }
            .joined(separator: ",")
        switch video {
        case .remux:
            args += ["-c:v", "copy"]
        case .transcode(let kbps):
            args += [
                "-c:v", "libx264", "-preset", "veryfast",
                "-b:v", "\(kbps)k",
                "-maxrate", "\(kbps)k",
                "-bufsize", "\(kbps * 2)k",
                // iOS が確実に再生できる設定にする。
                "-profile:v", "high", "-level", "4.1", "-pix_fmt", "yuv420p",
            ]
            // 再エンコード時は境界に必ずキーフレームを置く。
            // 区切りが無い (残りが 1 本だけ) ときに空文字を渡すと
            // "Invalid keyframe time" で ffmpeg が起動直後に落ちる。
            if !cutTimes.isEmpty { args += ["-force_key_frames", cutTimes] }
        }
        args += ["-c:a", "aac", "-b:a", "\(audioBitrateKbps)k", "-ac", "2"]
        args += ["-f", "segment", "-segment_format", "mpegts"]
        // 区切り位置を明示する。プレイリストと一致させるため。
        // 最後の 1 本だけを作る場合は区切りが無いので、指定自体を省く。
        if !cutTimes.isEmpty { args += ["-segment_times", cutTimes] }
        args += [
            "-segment_start_number", "\(startIndex)",
            directory.appendingPathComponent("seg%05d.ts").path,
        ]

        process.executableURL = ffmpeg
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        // 標準エラーはファイルに落とす。再生が止まったときに
        // 「何が起きたか」を後から読めるようにするため。
        // パイプにすると誰も読まない間に詰まって ffmpeg が止まる。
        let log = directory.appendingPathComponent("ffmpeg-\(startIndex).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: log)
        process.standardError = logHandle ?? FileHandle.nullDevice
        logURL = log
        process.terminationHandler = { [weak self] p in
            try? logHandle?.close()
            guard let self else { return }
            self.lock.lock()
            self.finished = true
            self.exitCodeValue = p.terminationStatus
            self.lock.unlock()
            let status = p.terminationStatus
            if status == 0 || status == SIGTERM {
                Log.info("変換終了 (終了コード \(status)) \(directory.lastPathComponent)")
            } else {
                // 途中で落ちた場合だけ理由を添える。
                Log.warn("変換が異常終了しました (終了コード \(status)) "
                         + directory.lastPathComponent
                         + MediaInfo.errorSuffix(self.errorText()))
            }
        }
        do {
            try process.run()
        } catch {
            Log.warn("ffmpeg の起動に失敗: \(error)")
            return nil
        }
    }

    /// 書き終わっている最大のセグメント番号。
    /// ffmpeg は次を開いた時点で前を閉じるので、
    /// 「存在する最大番号 - 1」までが完成とみなせる。
    func producedThrough() -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return startIndex - 1
        }
        var highest = -1
        for n in names where n.hasPrefix("seg") && n.hasSuffix(".ts") {
            if let v = Int(n.dropFirst(3).dropLast(3)) { highest = max(highest, v) }
        }
        if highest < 0 { return startIndex - 1 }
        return isFinished ? highest : highest - 1
    }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    /// 指定セグメントが「書き終わっている」状態になるまで待つ。
    ///
    /// ffmpeg は次のセグメントを開き始めた時点で前のセグメントを閉じるため、
    /// 次のファイルが現れたら完成とみなせる。
    /// 最後のセグメントは処理の終了をもって完成とする。
    func waitForSegment(_ index: Int, timeout: TimeInterval) -> Data? {
        // 止まっていると永遠に来ないので動かす。
        resume()
        let fm = FileManager.default
        let target = segmentURL(index)
        let next = segmentURL(index + 1)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let done = fm.fileExists(atPath: next.path) || isFinished
            if done, fm.fileExists(atPath: target.path) {
                return try? Data(contentsOf: target)
            }
            if isFinished, !fm.fileExists(atPath: target.path) {
                return nil  // 変換が終わったのに無い = そこまで到達しなかった
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        Log.warn("セグメント\(index) の待機がタイムアウトしました")
        return nil
    }

    /// 先読みしすぎないよう一時停止する。
    ///
    /// Force Conversion 設定では全ファイルが変換対象になるため、
    /// 放っておくと 1 分だけ観るつもりでも最後まで変換してしまう。
    /// 視聴位置から一定以上先に進んでいたら止め、
    /// 追いつかれたら再開する。
    func throttle(servedIndex: Int, lookahead: Int) {
        guard !isFinished else { return }
        let ahead = producedThrough() - servedIndex
        lock.lock()
        let wasSuspended = suspended
        lock.unlock()

        if ahead > lookahead, !wasSuspended {
            if process.suspend() {
                lock.lock(); suspended = true; lock.unlock()
            }
        } else if ahead <= lookahead / 2, wasSuspended {
            resume()
        }
    }

    /// 止めていたら動かす。
    func resume() {
        lock.lock()
        let wasSuspended = suspended
        lock.unlock()
        guard wasSuspended else { return }
        if process.resume() {
            lock.lock(); suspended = false; lock.unlock()
        }
    }

    /// 変換を止める。生成済みのセグメントは残す
    /// (シークで作り直すたびに捨てると、戻ったときに作り直しになる)。
    func stop() {
        // 止めたままだと終了できないので、必ず動かしてから終える。
        resume()
        if process.isRunning { process.terminate() }
    }
}
