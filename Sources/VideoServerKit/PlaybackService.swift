import Foundation
import VideoServerCore

/// 推測できない乱数の文字列。配信の URL に載せる鍵に使う。
enum RandomToken {
    /// 128 ビットを base64url にしたもの (22 文字)。
    static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// ダイレクト再生用に発行した鍵と、指す項目の対応表。
///
/// /stream/<鍵> はこの鍵だけで認可されるため、推測できない値であることが
/// 実質的なアクセス制御になる。鍵は認証済みの /api/play でしか得られない。
///
/// 再生を止めても鍵を消す合図は来ないので、古いものは発行のついでに捨てる。
/// 見ている途中で消えないよう、使われるたびに期限を延ばす。
final class StreamTokens: @unchecked Sendable {
    private struct Entry {
        var item: ItemID
        var lastUsed: Date
    }

    /// 最後に使われてからこれだけ経ったら捨てる。
    private let lifetime: TimeInterval = 12 * 60 * 60

    private let lock = NSLock()
    private var store: [String: Entry] = [:]

    func issue(for item: ItemID) -> String {
        let token = RandomToken.make()
        let now = Date()
        lock.lock()
        store = store.filter { now.timeIntervalSince($0.value.lastUsed) < lifetime }
        store[token] = Entry(item: item, lastUsed: now)
        lock.unlock()
        return token
    }

    func lookup(_ token: String) -> ItemID? {
        lock.lock(); defer { lock.unlock() }
        guard var e = store[token] else { return nil }
        e.lastUsed = Date()
        store[token] = e
        return e.item
    }
}

/// 変換再生での映像の扱い。
enum VideoPlan: Sendable, Equatable {
    /// 映像はそのまま。容器を MPEG-TS に詰め替えるだけなので軽い。
    case remux
    /// H.264 に再エンコードする。値は目標ビットレート (kbps)。
    case transcode(kbps: Int)

    /// ログや状態表示に出す名前。
    var label: String {
        switch self {
        case .remux: return "詰め替え"
        case .transcode(let kbps): return "再エンコード \(kbps)kbps"
        }
    }
}

/// 変換再生のセッションを作る。
public struct PlaybackService: Sendable {
    let library: Library
    let sessions: PlaybackSessions

    /// 音声は常に AAC に作り直す。そのときのビットレート (kbps)。
    static let audioBitrateKbps = 256

    init(library: Library, sessions: PlaybackSessions) {
        self.library = library
        self.sessions = sessions
    }

    /// 再生セッションを作り、先頭から変換を始める。
    func startPlayback(item: ItemID, video: VideoPlan) -> PlaybackSession? {
        guard let url = library.resolve(item),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let media = MediaInfoCache.shared.fetchNow(
                  url: url,
                  size: (attrs[.size] as? Int) ?? 0,
                  modified: (attrs[.modificationDate] as? Date) ?? Date())
        else { return nil }

        let audioKbps = Self.audioBitrateKbps
        let boundaries: [Double]
        let bandwidth: Int
        switch video {
        case .remux:
            // 詰め替えは切れ目がキーフレームでないと再生できないため、
            // 実際のキーフレーム位置に合わせて区切る。
            boundaries = KeyframeIndex.segmentBoundaries(
                for: url, duration: media.durationSeconds, target: Transcoder.segmentLength)
            bandwidth = max(media.bitrate, 1_000_000)
        case .transcode(let kbps):
            // 再エンコードは区切りごとにキーフレームを置かせるので等間隔でよい。
            boundaries = KeyframeIndex.uniform(
                duration: media.durationSeconds, target: Transcoder.segmentLength)
            bandwidth = (kbps + audioKbps) * 1000
        }

        let session = PlaybackSession(
            id: RandomToken.make(),
            item: item,
            url: url,
            duration: media.durationSeconds,
            video: video,
            audioBitrateKbps: audioKbps,
            videoCodecTag: Self.codecTag(for: media, video: video),
            bandwidth: bandwidth,
            boundaries: boundaries
        )
        // 先頭から変換を始めておく。
        session.setInitialJob(session.makeJob(startingAt: 0))
        sessions.add(session)
        Log.info("再生セッション開始 \(session.id) \(video.label) "
                 + "セグメント\(session.segmentCount)本")
        return session
    }

    /// HLS のプレイリストに書く CODECS 属性 (RFC 6381 の avc1.PPCCLL)。
    ///
    /// 詰め替えのときは元の映像の avcC から profile / 互換性 / level を取る。
    /// 再エンコードのときは TranscodeJob が作る High 4.1 に揃える。
    static func codecTag(for media: MediaInfo, video: VideoPlan) -> String {
        guard video == .remux, let v = media.videoStreams.first, v.codecData.count >= 8 else {
            return "avc1.640029"
        }
        // avcC の先頭: [configurationVersion][profile][compat][level]
        let profile = String(v.codecData.dropFirst(2).prefix(2))
        let compat = String(v.codecData.dropFirst(4).prefix(2))
        let level = String(v.codecData.dropFirst(6).prefix(2))
        return "avc1.\(profile)\(compat)\(level)"
    }
}
