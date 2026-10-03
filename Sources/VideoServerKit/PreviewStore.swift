import Foundation
import AVFoundation
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// スクラブ中に出すコマ画像 (スプライトシート) の生成と保管。
///
/// 一定間隔のコマを 1 枚の JPEG に敷き詰めておき、クライアントは
/// 表示位置をずらすだけにする。
///
/// **粗い順に段階的に作る。** 最初は 8 コマおき、次に 4 コマおき、2、1 と
/// 埋めていき、段階ごとにシートを保存する。クライアントは揃っている中で
/// 一番近いコマを出す。1GB を超える動画を NAS から読む場合でも、
/// 最初の段階はすぐ出て、再生しているうちに揃っていく。
///
/// 再生中にしか使わないので、再生を止めたら取り消す。途中まで作った
/// シートは残し、次に再生したときはそこから続ける。
final class PreviewStore: @unchecked Sendable {
    static let shared = PreviewStore()

    /// コマの横幅。小さすぎると何が写っているか分からず、
    /// 大きすぎるとシートが重くなる。
    private static let tileWidth = 160
    /// 横に並べる枚数。
    private static let columns = 10
    /// シート 1 枚に入れるコマ数の上限。
    /// 長い動画ほど間隔を粗くして、画像が巨大にならないようにする。
    private static let maxTiles = 180
    /// ffmpeg で作るとき、1 本の動画に対して同時に走らせる数。
    private static let parallelTiles = 4
    /// 埋めていく順番。値は「何コマおきに揃っているか」。
    private static let strides = [8, 4, 2, 1]

    struct Sheet: Codable {
        var size: Int
        var modified: Double
        var hash: String
        var interval: Double
        var columns: Int
        var rows: Int
        var count: Int
        var tileWidth: Int
        var tileHeight: Int
        /// 揃っているコマの間隔。この倍数番のコマがある。1 なら全部揃っている。
        /// 段階的に作る前の形式で保存されたものは nil で、全部揃っている。
        var stride: Int?

        var isComplete: Bool { (stride ?? 1) == 1 }
    }

    private let lock = NSLock()
    private var entries: [String: Sheet] = [:]
    private var dirty = false
    private var saveTimer: DispatchSourceTimer?

    private static var indexURL: URL {
        Configuration.supportDirectory.appendingPathComponent("previews.json")
    }

    static var directory: URL {
        Configuration.supportDirectory.appendingPathComponent("previews", isDirectory: true)
    }

    private init() {
        load()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.saveIfNeeded() }
        t.resume()
        saveTimer = t
    }

    // MARK: 取り出し

    /// 作ってあればその情報を返す (途中までのものも含む)。生成は始めない。
    func sheet(for url: URL, size: Int, modified: Date) -> Sheet? {
        let mtime = modified.timeIntervalSince1970
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[url.path], e.size == size, abs(e.modified - mtime) < 1 else {
            return nil
        }
        return e
    }

    /// 動画のパスからシート画像を取り出す。
    func image(for url: URL) -> Data? {
        lock.lock()
        let e = entries[url.path]
        lock.unlock()
        guard let e else { return nil }
        return try? Data(contentsOf: Self.directory.appendingPathComponent("\(e.hash).jpg"))
    }

    /// 索引とシート画像をすべて捨てる。次に再生すれば作り直される。
    func clear() {
        lock.lock()
        entries.removeAll()
        dirty = false
        lock.unlock()
        try? FileManager.default.removeItem(at: Self.indexURL)
        try? FileManager.default.removeItem(at: Self.directory)
    }

    // MARK: 生成と取り消し

    static func jobKey(_ url: URL) -> String { "preview:\(url.path)" }

    /// 再生中の動画のシートを最優先で作らせる (揃っていれば何もしない)。
    /// 別の動画のシートを作っていたら、それは取り消す (再生中しか使わないため)。
    func request(url: URL, size: Int, modified: Date, info: MediaInfo) {
        if let s = sheet(for: url, size: size, modified: modified), s.isComplete { return }
        guard info.durationSeconds > 0 else { return }
        let key = Self.jobKey(url)
        WorkQueue.shared.cancel { $0.key.hasPrefix("preview:") && $0.key != key }
        let width = info.videoStreams.first?.width ?? 0
        let height = info.videoStreams.first?.height ?? 0
        // 実行中なら submit は何もしないので、何度呼んでもよい。
        WorkQueue.shared.submit(key: key, scope: "video:\(url.path)", lane: .foreground) {
            [weak self] job in
            self?.generate(url: url, size: size, modified: modified,
                           duration: info.durationSeconds, width: width, height: height, job: job)
        }
    }

    /// 再生を止めたら呼ぶ。途中までのシートは残る。
    func cancel(url: URL) {
        let key = Self.jobKey(url)
        WorkQueue.shared.cancel { $0.key == key }
    }

    private func generate(url: URL, size: Int, modified: Date, duration: Double,
                          width: Int, height: Int, job: WorkQueue.Job) {
        let plan = Self.layout(duration: duration, width: width, height: height)
        var tiles = [CGImage?](repeating: nil, count: plan.count)
        var have = Set<Int>()

        // 途中まで作ったシートがあれば、そこからコマを切り出して続きから作る。
        if let prev = sheet(for: url, size: size, modified: modified),
           prev.count == plan.count, prev.tileHeight == plan.tileHeight,
           let stride = prev.stride,
           let data = try? Data(contentsOf: Self.directory.appendingPathComponent("\(prev.hash).jpg")),
           let src = CGImageSourceCreateWithData(data as CFData, nil),
           let sheetImage = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            for i in Swift.stride(from: 0, to: plan.count, by: stride) {
                // CGImage の切り出しは左上が原点。
                let rect = CGRect(x: (i % Self.columns) * Self.tileWidth,
                                  y: (i / Self.columns) * plan.tileHeight,
                                  width: Self.tileWidth, height: plan.tileHeight)
                if let tile = sheetImage.cropping(to: rect) { tiles[i] = tile; have.insert(i) }
            }
        }

        var useFFmpeg = !Self.avFoundationExtensions.contains(url.pathExtension.lowercased())
        for stride in Self.strides {
            let wanted = Swift.stride(from: 0, to: plan.count, by: stride).filter { !have.contains($0) }
            // 途中から再開したとき、この段階のコマがすでに揃っていれば保存し直さない。
            // 保存するとシートの版が変わり、クライアントが無駄に画像を取り直す。
            if wanted.isEmpty { continue }
            let began = Date()
            do {
                var got: [Int: CGImage] = [:]
                if !useFFmpeg {
                    got = Self.tilesWithAVFoundation(url: url, indices: wanted, interval: plan.interval,
                                                     tileHeight: plan.tileHeight, job: job)
                    // AVFoundation で 1 枚も作れなければ、以降は ffmpeg に切り替える。
                    if got.isEmpty, !job.isCancelled { useFFmpeg = true }
                }
                if useFFmpeg {
                    got = Self.tilesWithFFmpeg(url: url, indices: wanted, interval: plan.interval,
                                               tileHeight: plan.tileHeight, job: job)
                }
                if job.isCancelled { return }
                for (i, image) in got { tiles[i] = image; have.insert(i) }
            }
            guard let data = Self.compose(tiles, rows: plan.rows, tileHeight: plan.tileHeight) else {
                continue
            }
            save(data, url: url, size: size, modified: modified, plan: plan, stride: stride)
            Log.info(String(format: "プレビュー生成 %@ %d/%d コマ (%d おき) %.1f秒 (%@)",
                            url.lastPathComponent, have.count, plan.count, stride,
                            Date().timeIntervalSince(began), useFFmpeg ? "ffmpeg" : "AVFoundation"))
        }
    }

    private func save(_ data: Data, url: URL, size: Int, modified: Date,
                      plan: (interval: Double, count: Int, rows: Int, tileHeight: Int), stride: Int) {
        let hash = Self.sha1(data)
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? data.write(to: Self.directory.appendingPathComponent("\(hash).jpg"), options: .atomic)
        lock.lock()
        let old = entries[url.path]?.hash
        entries[url.path] = Sheet(
            size: size, modified: modified.timeIntervalSince1970, hash: hash,
            interval: plan.interval, columns: Self.columns, rows: plan.rows,
            count: plan.count, tileWidth: Self.tileWidth, tileHeight: plan.tileHeight,
            stride: stride)
        dirty = true
        lock.unlock()
        // 前の段階のシート画像は不要になる。
        if let old, old != hash {
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent("\(old).jpg"))
        }
    }

    /// コマ数・間隔・寸法を決める。
    /// 尺が長いほど間隔を粗くして、シートの大きさを頭打ちにする。
    static func layout(duration: Double, width: Int, height: Int)
        -> (interval: Double, count: Int, rows: Int, tileHeight: Int) {
        let interval = max(2.0, (duration / Double(maxTiles)).rounded(.up))
        let count = max(1, min(maxTiles, Int(duration / interval)))
        let rows = max(1, Int((Double(count) / Double(columns)).rounded(.up)))
        // 元の縦横比を保つ。分からなければ 16:9 とみなす。
        let ratio = (width > 0 && height > 0) ? Double(height) / Double(width) : 9.0 / 16.0
        let tileHeight = max(2, Int((Double(tileWidth) * ratio / 2).rounded()) * 2)
        return (interval, count, rows, tileHeight)
    }

    // MARK: コマの取り出し

    /// AVFoundation で読める容器。
    static let avFoundationExtensions: Set<String> = ["mp4", "m4v", "mov"]

    /// 番号 i のコマの時刻。区間の中央にする (先頭は暗転していることが多い)。
    static func time(of index: Int, interval: Double) -> Double {
        (Double(index) + 0.5) * interval
    }

    /// AVFoundation でコマを作る。
    ///
    /// ファイルを 1 回だけ開き、索引 (moov) も 1 回だけ読んで、各時刻へは
    /// 索引を使って飛ぶ。ffmpeg をコマごとに起動する方式は、そのたびに
    /// ファイルを開き直して索引を読み直すため、NAS 上では 170 コマで
    /// 2 分以上かかっても終わらなかった。ローカルでも 109 コマで
    /// ffmpeg 4 並列 3.82 秒に対し 0.77 秒。
    static func tilesWithAVFoundation(url: URL, indices: [Int], interval: Double,
                                      tileHeight: Int, job: WorkQueue.Job) -> [Int: CGImage] {
        guard !indices.isEmpty else { return [:] }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.maximumSize = CGSize(width: tileWidth, height: tileHeight)
        generator.appliesPreferredTrackTransform = true
        // 近くのキーフレームに吸着させる。位置の精度より速さを取る。
        let tolerance = CMTime(seconds: interval / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        // 完了通知は別スレッドから来るので、結果は参照型に鍵付きで集める。
        final class Collector: @unchecked Sendable {
            let lock = NSLock()
            var images: [Int: CGImage] = [:]
            var remaining: Int
            let done = DispatchSemaphore(value: 0)
            init(count: Int) { remaining = count }
        }
        let box = Collector(count: indices.count)
        let values = indices.map {
            NSValue(time: CMTime(seconds: time(of: $0, interval: interval), preferredTimescale: 600))
        }
        generator.generateCGImagesAsynchronously(forTimes: values) { requested, image, _, _, _ in
            // 要求時刻は (i + 0.5) * interval なので、割って切り捨てれば番号になる。
            let index = Int((requested.seconds / interval).rounded(.down))
            box.lock.lock()
            if let image { box.images[index] = image }
            box.remaining -= 1
            let finished = box.remaining == 0
            box.lock.unlock()
            if finished { box.done.signal() }
        }
        // 待つ間に取り消されたら止める。残りは取り消し扱いで通知が来て終わる。
        while box.done.wait(timeout: .now() + 0.25) == .timedOut {
            if job.isCancelled { generator.cancelAllCGImageGeneration() }
        }
        box.lock.lock(); defer { box.lock.unlock() }
        return box.images
    }

    /// ffmpeg でコマを作る。AVFoundation が読めない形式 (mkv など) 向け。
    /// 各時刻へシークして 1 コマずつ取り、4 本まで並べて走らせる。
    static func tilesWithFFmpeg(url: URL, indices: [Int], interval: Double,
                                tileHeight: Int, job: WorkQueue.Job) -> [Int: CGImage] {
        guard let ffmpeg = Transcoder.locateFFmpeg() else { return [:] }
        final class Collector: @unchecked Sendable {
            let lock = NSLock()
            var images: [Int: CGImage] = [:]
        }
        let box = Collector()
        let limiter = DispatchSemaphore(value: parallelTiles)
        let group = DispatchGroup()
        for i in indices {
            if job.isCancelled { break }
            limiter.wait()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { limiter.signal(); group.leave() }
                guard !job.isCancelled else { return }
                let data = job.run(ffmpeg, [
                    "-v", "error",
                    "-noaccurate_seek",
                    "-ss", String(format: "%.3f", time(of: i, interval: interval)),
                ] + MediaInfo.inputOptions(for: url) + [
                    "-i", url.path,
                    "-frames:v", "1", "-an", "-sn",
                    "-vf", "scale=\(tileWidth):\(tileHeight)",
                    "-q:v", "6",
                    "-f", "mjpeg", "pipe:1",
                ])
                guard let data,
                      let src = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
                box.lock.lock(); box.images[i] = image; box.lock.unlock()
            }
        }
        group.wait()
        box.lock.lock(); defer { box.lock.unlock() }
        return box.images
    }

    /// コマを並べて 1 枚の JPEG にする。まだ無いコマは黒のまま残す。
    static func compose(_ tiles: [CGImage?], rows: Int, tileHeight: Int) -> Data? {
        let w = tileWidth * columns, h = tileHeight * rows
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        var drawn = 0
        for (i, tile) in tiles.enumerated() {
            guard let image = tile else { continue }
            let col = i % columns, row = i / columns
            // CGContext は左下が原点なので、上の行ほど y が大きい。
            let y = h - (row + 1) * tileHeight
            ctx.draw(image, in: CGRect(x: col * tileWidth, y: y, width: tileWidth, height: tileHeight))
            drawn += 1
        }
        guard drawn > 0, let sheet = ctx.makeImage() else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, sheet,
                                   [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    static func sha1(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: 永続化

    private func load() {
        let fm = FileManager.default
        let decoded = (try? Data(contentsOf: Self.indexURL))
            .flatMap { try? JSONDecoder().decode([String: Sheet].self, from: $0) } ?? [:]

        // 元の動画が消えているものは索引から外す。
        var kept: [String: Sheet] = [:]
        var removedPaths = 0
        for (path, e) in decoded {
            if fm.fileExists(atPath: path) {
                kept[path] = e
            } else {
                removedPaths += 1
            }
        }

        // 索引が指していないシート画像は捨てる。
        // 索引を保存する前に終了した場合にも取り残しが出るため、
        // 索引側からではなくディレクトリを走査して突き合わせる。
        let inUse = Set(kept.values.map { "\($0.hash).jpg" })
        var removedImages = 0
        if let files = try? fm.contentsOfDirectory(atPath: Self.directory.path) {
            for f in files where f.hasSuffix(".jpg") && !inUse.contains(f) {
                if (try? fm.removeItem(at: Self.directory.appendingPathComponent(f))) != nil {
                    removedImages += 1
                }
            }
        }

        lock.lock()
        entries = kept
        if removedPaths > 0 { dirty = true }
        lock.unlock()

        if removedPaths > 0 || removedImages > 0 {
            Log.info("プレビューの索引を読み込みました "
                     + "(\(kept.count) 件、元ファイルが消えた \(removedPaths) 件を整理、"
                     + "画像 \(removedImages) 枚を削除)")
        } else {
            Log.info("プレビューの索引を読み込みました (\(kept.count) 件)")
        }
    }

    private func saveIfNeeded() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        let snapshot = entries
        dirty = false
        lock.unlock()
        try? FileManager.default.createDirectory(
            at: Configuration.supportDirectory, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(snapshot) {
            try? d.write(to: Self.indexURL, options: .atomic)
        }
    }

    func flush() { saveIfNeeded() }
}
