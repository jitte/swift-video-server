import Foundation

/// 映像のキーフレーム位置 (秒) を求める。
///
/// 無変換の詰め替えでは、セグメントの先頭が
/// 必ずキーフレームでなければならない。途中から始まる区間を渡すと
/// デコーダが再生を開始できず、iOS 側で
/// CoreMediaErrorDomain error -12971 になる。
enum KeyframeIndex {
    private static let cache = Cache()

    /// キーフレームの時刻一覧を昇順で返す。取得できなければ空。
    static func keyframeTimes(for url: URL) -> [Double] {
        cache.value(for: url)
    }

    static func probe(_ url: URL) -> [Double] {
        guard let ffprobe = MediaInfo.locateFFprobe() else { return [] }
        let p = Process()
        p.executableURL = ffprobe
        // パケットのフラグを見る。K が付いているものがキーフレーム。
        // フレームを復号せずインデックスだけ読むので比較的速い。
        p.arguments = [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "packet=pts_time,flags",
            "-of", "csv=p=0",
        ] + MediaInfo.inputOptions(for: url) + [url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return [] }

        var times: [Double] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 2, let t = Double(cols[0]) else { continue }
            if cols[1].hasPrefix("K") { times.append(t) }
        }
        return times.sorted()
    }

    /// キーフレームに揃えたセグメント開始時刻を作る。
    ///
    /// 目標長 (5秒) 以上になる最初のキーフレームで区切る。
    /// キーフレームが取れない場合は等間隔に戻す。
    static func segmentBoundaries(for url: URL, duration: Double, target: Double) -> [Double] {
        let keys = keyframeTimes(for: url)
        guard keys.count > 1 else {
            return uniform(duration: duration, target: target)
        }
        var bounds: [Double] = [0]
        var current = 0.0
        for k in keys {
            if k - current >= target - 0.001 {
                bounds.append(k)
                current = k
            }
        }
        // 末尾が尺に近すぎる区切りは畳む。
        if bounds.count > 1, duration - bounds[bounds.count - 1] < 0.2 {
            bounds.removeLast()
        }
        return bounds
    }

    static func uniform(duration: Double, target: Double) -> [Double] {
        let n = max(1, Int(ceil(duration / target)))
        return (0..<n).map { Double($0) * target }
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var store: [String: [Double]] = [:]

        func value(for url: URL) -> [Double] {
            let key = url.path
            lock.lock()
            if let hit = store[key] { lock.unlock(); return hit }
            lock.unlock()
            let probed = KeyframeIndex.probe(url)
            lock.lock(); store[key] = probed; lock.unlock()
            return probed
        }
    }
}
