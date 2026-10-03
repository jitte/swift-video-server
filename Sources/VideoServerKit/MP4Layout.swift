import Foundation

/// MP4 / MOV のボックスの並びを見る。
///
/// ffprobe は断片化しているかどうかを教えてくれないので、自分で見出しを読む。
/// 読むのは各ボックスの見出し (8 か 16 バイト) だけで、中身は読み飛ばす。
enum MP4Layout {

    /// 断片化した MP4 (fragmented MP4) か。
    ///
    /// DASH 配信用に作られたもの (moov の後ろに moof + mdat が並び、
    /// 断片ごとに sidx が付く) は、ブラウザに直接渡すと iPad の Safari が
    /// 再生を始めない。HLS に詰め替えれば映像はそのままで再生できる。
    ///
    /// moov の中に mvex (断片化の宣言) があるか、最上位に moof があれば真。
    /// 読めない・分からないときは偽 (これまでどおりの判定に任せる)。
    static func isFragmented(url: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        guard let end = try? file.seekToEnd() else { return false }

        var offset: UInt64 = 0
        // 断片化したものは moov が先頭近くにあるので、ここまで見れば足りる。
        // 普通の MP4 でも最上位のボックスは数個しかない。
        for _ in 0..<64 {
            guard let box = header(file, at: offset, limit: end) else { return false }
            switch box.type {
            case "moof":
                return true
            case "moov":
                return contains(file, "mvex", from: box.bodyStart, to: box.end)
            default:
                break
            }
            offset = box.end
        }
        return false
    }

    private struct Box {
        var type: String
        var bodyStart: UInt64
        var end: UInt64
    }

    /// offset にあるボックスの見出しを読む。壊れていれば nil。
    private static func header(_ file: FileHandle, at offset: UInt64, limit: UInt64) -> Box? {
        guard offset + 8 <= limit else { return nil }
        guard (try? file.seek(toOffset: offset)) != nil,
              let head = try? file.read(upToCount: 16), head.count >= 8
        else { return nil }
        let bytes = [UInt8](head)
        let size32 = bytes[0..<4].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let type = String(decoding: bytes[4..<8], as: UTF8.self)

        var headerSize: UInt64 = 8
        var size = size32
        if size32 == 1 {
            // 64 ビットの大きさが続く。
            guard bytes.count >= 16 else { return nil }
            size = bytes[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            headerSize = 16
        } else if size32 == 0 {
            // ファイルの終わりまで。
            size = limit - offset
        }
        guard size >= headerSize, offset + size <= limit else { return nil }
        return Box(type: type, bodyStart: offset + headerSize, end: offset + size)
    }

    /// [from, to) に並ぶ子ボックスに type があるか。
    private static func contains(_ file: FileHandle, _ type: String,
                                 from: UInt64, to: UInt64) -> Bool {
        var offset = from
        for _ in 0..<256 {
            guard let box = header(file, at: offset, limit: to) else { return false }
            if box.type == type { return true }
            offset = box.end
        }
        return false
    }
}
