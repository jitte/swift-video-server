import Foundation
import VideoServerCore

/// 変換再生のセッション。
///
/// シーク時に変換ジョブを差し替えるため、参照型にしてある。
public final class PlaybackSession: @unchecked Sendable {
    public let id: String
    public let item: ItemID
    public let url: URL
    public let duration: Double
    /// 映像の扱い (詰め替えか再エンコードか)。
    let video: VideoPlan
    public let audioBitrateKbps: Int
    public let videoCodecTag: String
    public let bandwidth: Int
    private let lock = NSLock()
    /// 現在の変換ジョブ。シークで差し替わる。
    private var job: TranscodeJob?
    /// 書き上がったセグメント番号。
    /// 変換をやり直しても生成済みの分は使い回す。
    private var completed = Set<Int>()
    /// 最後に返したセグメント番号 (視聴位置の目安)。
    private var lastServed = 0
    /// 先読みしすぎていないか定期的に見張る。
    private var monitor: DispatchSourceTimer?

    /// このセッションの作業ディレクトリ。全ジョブが共有する。
    var workDirectory: URL {
        PlaybackSessions.workDirectory.appendingPathComponent(id)
    }

    func segmentURL(_ index: Int) -> URL {
        workDirectory.appendingPathComponent(String(format: "seg%05d.ts", index))
    }
    /// 各セグメントの開始時刻。
    /// 詰め替えのときはキーフレームに揃えてあるため等間隔ではない。
    public let boundaries: [Double]

    init(id: String, item: ItemID, url: URL, duration: Double,
         video: VideoPlan, audioBitrateKbps: Int,
         videoCodecTag: String, bandwidth: Int, boundaries: [Double]) {
        self.id = id
        self.item = item
        self.url = url
        self.duration = duration
        self.video = video
        self.audioBitrateKbps = audioBitrateKbps
        self.videoCodecTag = videoCodecTag
        self.bandwidth = bandwidth
        self.boundaries = boundaries
    }

    /// 視聴位置からこれだけ先まで作ったら変換を止める。
    /// 3 秒 x 40 本 = 約 2 分先まで。
    static let lookaheadSegments = 40

    public var segmentCount: Int { boundaries.count }

    /// 指定セグメントを取り出す。
    ///
    /// 今のジョブがそこまで到達していない場合、待つより
    /// その位置から変換をやり直した方が速い (シーク時)。
    /// 逐次変換は実時間の数十倍で進むので、
    /// 通常の視聴で追い抜かれることはない。
    func segmentData(_ index: Int) -> Data? {
        lock.lock()
        let alreadyDone = completed.contains(index)
        let current = job
        lock.unlock()

        // 既に作ってあるものはそのまま返す。
        if alreadyDone, let data = try? Data(contentsOf: segmentURL(index)) {
            lock.lock(); lastServed = index; lock.unlock()
            current?.throttle(servedIndex: index, lookahead: Self.lookaheadSegments)
            return data
        }

        if let current, current.canReach(index) {
            let produced = current.producedThrough()
            // もうすぐ書き上がるなら待つ。
            // 大きく先を要求されたら待たずにそこから変換し直す
            // (逐次変換の追いつきを待つと、長い動画では何十秒もかかる)。
            if index <= produced + 2 {
                if let data = current.waitForSegment(index, timeout: 60) {
                    markCompleted(index)
                    current.throttle(servedIndex: index, lookahead: Self.lookaheadSegments)
                    return data
                }
            }
        }
        // ここから変換をやり直す。
        lock.lock(); lastServed = index; lock.unlock()
        Log.info("セグメント\(index) へシーク。変換を開始し直します")
        let fresh = makeJob(startingAt: index)
        lock.lock()
        let old = job
        job = fresh
        lock.unlock()
        old?.stop()
        guard let data = fresh?.waitForSegment(index, timeout: 120) else { return nil }
        markCompleted(index)
        return data
    }

    /// 再生がうまくいっていないときに、サーバ側で何が起きているかを返す。
    ///
    /// ブラウザ側は「デコードできない」としか分からないので、
    /// 変換の状態と ffmpeg の言い分を並べて、どちら側の問題かを見えるようにする。
    public func status() -> JSONValue {
        lock.lock()
        let current = job
        let served = lastServed
        let doneCount = completed.count
        lock.unlock()

        var out: [String: JSONValue] = [
            "playbackId": .string(id),
            "name": .string(url.lastPathComponent),
            "mode": .string(video.label),
            "videoCodecTag": .string(videoCodecTag),
            "segmentCount": .int(segmentCount),
            "servedSegment": .int(served),
            "completedSegments": .int(doneCount),
        ]
        if let current {
            out["producedThrough"] = .int(current.producedThrough())
            if let code = current.exitCode { out["exitCode"] = .int(Int(code)) }
            let messages = Diagnostics.messageLines(current.errorText(), limit: 20)
            out["messages"] = .array(messages.map { .string($0) })
        } else {
            out["messages"] = .array([])
        }
        return .object(out)
    }

    private func markCompleted(_ index: Int) {
        lock.lock()
        completed.insert(index)
        lastServed = max(lastServed, index)
        lock.unlock()
    }

    /// 指定セグメントから始まる変換ジョブを作る。
    func makeJob(startingAt index: Int) -> TranscodeJob? {
        TranscodeJob(
            input: url,
            boundaries: boundaries,
            startIndex: index,
            video: video,
            audioBitrateKbps: audioBitrateKbps,
            directory: workDirectory
        )
    }

    func setInitialJob(_ j: TranscodeJob?) {
        lock.lock(); job = j; lock.unlock()
        startMonitor()
    }

    /// 変換が視聴位置から離れすぎていないか定期的に確認する。
    ///
    /// セグメント要求時にしか見ないと、クライアントが要求を止めた間に
    /// 最後まで変換し切ってしまう (視聴を止めても走り続ける)。
    private func startMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let j = self.job
            let served = self.lastServed
            self.lock.unlock()
            j?.throttle(servedIndex: served, lookahead: Self.lookaheadSegments)
        }
        timer.resume()
        lock.lock(); monitor = timer; lock.unlock()
    }

    func cleanUp() {
        lock.lock()
        let j = job
        job = nil
        completed.removeAll()
        monitor?.cancel()
        monitor = nil
        lock.unlock()
        j?.stop()
        try? FileManager.default.removeItem(at: workDirectory)
    }

    /// n 番目のセグメントの長さ。最後は尺の残り。
    public func segmentDuration(_ index: Int) -> Double {
        let start = boundaries[index]
        let end = index + 1 < boundaries.count ? boundaries[index + 1] : duration
        return max(0, end - start)
    }
}

/// 再生セッションの一覧。セッションの id で引く。
final class PlaybackSessions: @unchecked Sendable {
    /// セッション用の一時ディレクトリの置き場。
    static var workDirectory: URL {
        Configuration.supportDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    private let lock = NSLock()
    private var store: [String: PlaybackSession] = [:]

    func add(_ session: PlaybackSession) {
        lock.lock(); store[session.id] = session; lock.unlock()
    }

    func lookup(_ id: String) -> PlaybackSession? {
        lock.lock(); defer { lock.unlock() }
        return store[id]
    }

    func remove(_ id: String) {
        lock.lock()
        let s = store.removeValue(forKey: id)
        lock.unlock()
        s?.cleanUp()
    }

    /// サーバ停止時などにすべて片付ける。
    func removeAll() {
        lock.lock()
        let all = Array(store.values)
        store.removeAll()
        lock.unlock()
        for s in all { s.cleanUp() }
    }
}

/// HLS (RFC 8216) のプレイリストの生成。
///
/// 置き場所は /hls/<セッション id>/ の下にまとめ、プレイリストの中は相対 URL で書く。
///   index.m3u8  マルチバリアント (CODECS を知らせるため。バリアントは 1 つ)
///   media.m3u8  メディアプレイリスト
///   <n>.ts      セグメント
enum Playlist {
    static let prefix = "/hls/"

    static func indexURL(for s: PlaybackSession) -> String {
        "\(prefix)\(s.id)/index.m3u8"
    }

    /// マルチバリアントプレイリスト。
    ///
    /// 1 本しか無くても置くのは、CODECS を先に知らせるため。
    /// 知らせておくと、プレイヤーはセグメントを取る前に再生できるか判断できる。
    static func index(for s: PlaybackSession) -> String {
        var out = "#EXTM3U\n#EXT-X-VERSION:3\n"
        out += "#EXT-X-STREAM-INF:BANDWIDTH=\(s.bandwidth),"
        out += "CODECS=\"\(s.videoCodecTag),mp4a.40.2\"\n"
        out += "media.m3u8\n"
        return out
    }

    /// メディアプレイリスト。尺が既知なので全セグメントを並べて閉じる (VOD)。
    /// セグメントは要求されたときに作る。
    static func media(for s: PlaybackSession) -> String {
        let durations = (0..<s.segmentCount).map { s.segmentDuration($0) }
        var out = "#EXTM3U\n#EXT-X-VERSION:3\n"
        out += "#EXT-X-PLAYLIST-TYPE:VOD\n"
        out += "#EXT-X-TARGETDURATION:\(targetDuration(durations))\n"
        out += "#EXT-X-MEDIA-SEQUENCE:0\n"
        for (i, d) in durations.enumerated() {
            out += String(format: "#EXTINF:%.3f,\n", d)
            out += "\(i).ts\n"
        }
        out += "#EXT-X-ENDLIST\n"
        return out
    }

    /// EXT-X-TARGETDURATION に書く値。
    ///
    /// HLS では各セグメントの長さを四捨五入した値がこれ以下でなければならず、
    /// Safari は守られていないプレイリストを黙って捨てる (セグメントを 1 本も
    /// 取りに来ない)。無変換の詰め替えはキーフレームで区切るので、
    /// キーフレームが 4 秒おきなら 1 本が 4 秒を超え、決め打ちの 3 では足りない。
    /// hls.js は大目に見るので、Safari 以外では気づけない。
    static func targetDuration(_ durations: [Double]) -> Int {
        let longest = durations.max() ?? 0
        return max(Int(Transcoder.segmentLength), Int(longest.rounded(.up)))
    }
}
