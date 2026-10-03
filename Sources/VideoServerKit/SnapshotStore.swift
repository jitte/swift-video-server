import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// サムネイル (静止画) の生成と保管。
///
/// 動画 1 本につき JPEG を 1 枚作り、中身のハッシュを名前にして保存する。
/// 名前が中身で決まるので、同じ画像になる動画 (複製など) は 1 枚を共有でき、
/// 索引と画像の食い違いも起きにくい。
///
/// 生成は WorkQueue に載せる。配信は保存済みの JPEG を縮小して返し、
/// 配信のたびに動画を読み直すことはしない (NAS 上の動画を読むと遅く、
/// 要求を処理するスレッドを長く塞ぐため)。
final class SnapshotStore: @unchecked Sendable {
    static let shared = SnapshotStore()

    /// 保存する元画像の横幅。16:9 の 480p 相当。
    /// 一覧では縮小して配るので、これより大きく作っても使われない。
    private static let width = 854

    private struct Entry: Codable {
        var size: Int
        var modified: Double
        var hash: String
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var dirty = false
    private var saveTimer: DispatchSourceTimer?
    /// 配信用に縮小した画像の控え。
    private var deliveryCache: [String: Data] = [:]

    private static var indexURL: URL {
        Configuration.supportDirectory.appendingPathComponent("snapshots.json")
    }

    static var directory: URL {
        Configuration.supportDirectory.appendingPathComponent("snapshots", isDirectory: true)
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

    /// 作ってあればその SHA-1 を返す。生成は始めない。
    func hash(for url: URL, size: Int, modified: Date) -> String? {
        let mtime = modified.timeIntervalSince1970
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[url.path], e.size == size, abs(e.modified - mtime) < 1 else {
            return nil
        }
        return e.hash
    }

    /// SHA-1 から画像を取り出す。
    func image(forHash hash: String) -> Data? {
        try? Data(contentsOf: Self.directory.appendingPathComponent("\(hash).jpg"))
    }

    /// 配信用の画像。保存済みの元画像を、要求された幅と品質に縮小して返す。
    /// 元画像がまだ無ければ nil (生成の依頼は呼び出し側が行う)。
    ///
    /// 元画像より大きくは作らない。以前は動画から切り出し直していたが、
    /// そのたびに NAS 上の動画を読むことになり遅かった。
    func deliveryImage(for url: URL, size: Int, modified: Date,
                       maxWidth: Int?, quality: Int?) -> Data? {
        guard let hash = hash(for: url, size: size, modified: modified),
              let master = image(forHash: hash) else { return nil }
        let w = maxWidth ?? Self.width
        let q = quality ?? 90
        let key = "\(hash)|\(w)|\(q)"

        lock.lock()
        if let hit = deliveryCache[key] { lock.unlock(); return hit }
        lock.unlock()

        let data = Self.resize(master, maxWidth: w, quality: q) ?? master
        lock.lock()
        if deliveryCache.count > 500 { deliveryCache.removeAll() }
        deliveryCache[key] = data
        lock.unlock()
        return data
    }

    /// 索引と画像をすべて捨てる。次に一覧を開けば作り直される。
    func clear() {
        lock.lock()
        entries.removeAll()
        deliveryCache.removeAll()
        dirty = false
        lock.unlock()
        try? FileManager.default.removeItem(at: Self.indexURL)
        try? FileManager.default.removeItem(at: Self.directory)
    }

    // MARK: 生成

    /// まとめて生成を依頼する。順序を保って待ち行列の先頭に入る。
    func request(_ files: [(url: URL, size: Int, modified: Date)], scope: String,
                 lane: WorkQueue.Lane) {
        let missing = files.filter { hash(for: $0.url, size: $0.size, modified: $0.modified) == nil }
        let items: [(key: String, work: (WorkQueue.Job) -> Void)] = missing.map { f in
            ("snapshot:\(f.url.path)", { [weak self] job in
                self?.generate(url: f.url, size: f.size, modified: f.modified, job: job)
            })
        }
        WorkQueue.shared.submit(items, scope: scope, lane: lane)
    }

    private func generate(url: URL, size: Int, modified: Date, job: WorkQueue.Job) {
        guard hash(for: url, size: size, modified: modified) == nil,
              // 切り出す位置を決めるのに尺が要る。無ければここで調べる。
              let info = MediaInfoCache.shared.fetchNow(url: url, size: size,
                                                       modified: modified, job: job),
              info.durationSeconds > 0, !job.isCancelled,
              let data = Self.render(url: url, duration: info.durationSeconds, job: job)
        else { return }

        let hash = Self.sha1(data)
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? data.write(to: Self.directory.appendingPathComponent("\(hash).jpg"), options: .atomic)
        lock.lock()
        entries[url.path] = Entry(size: size, modified: modified.timeIntervalSince1970, hash: hash)
        dirty = true
        lock.unlock()
    }

    /// ffmpeg で 1 枚取り出す。頭は暗いことが多いので少し進めた位置から取る。
    /// 入力側でシークするので、1GB を超える動画でも読むのは一部だけで済む。
    static func render(url: URL, duration: Double, job: WorkQueue.Job) -> Data? {
        guard let ffmpeg = Transcoder.locateFFmpeg() else { return nil }
        let at = max(1.0, min(duration * 0.1, 120.0))
        let data = job.run(ffmpeg, [
            "-v", "error",
            "-ss", String(format: "%.3f", at),
        ] + MediaInfo.inputOptions(for: url) + [
            "-i", url.path,
            "-frames:v", "1",
            "-vf", "scale='min(\(width),iw)':-2",
            "-q:v", "5",
            "-f", "mjpeg", "pipe:1",
        ])
        guard let data, data.count > 2, data[0] == 0xFF, data[1] == 0xD8 else { return nil }
        return data
    }

    /// JPEG を縮小して品質を指定し直す。元より大きくはしない。
    static func resize(_ data: Data, maxWidth: Int, quality: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        if maxWidth >= w { return data }

        // 縮小後の長辺を指定する必要がある。
        let longSide = max(maxWidth, Int((Double(maxWidth) * Double(h) / Double(w)).rounded()))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: longSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: Double(max(1, min(100, quality))) / 100,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    static func sha1(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: 永続化

    private func load() {
        guard let d = try? Data(contentsOf: Self.indexURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: d)
        else { return }

        // 元の動画が消えているものは索引から外し、画像も捨てる。
        // そうしないと、動画を削除・移動するたびに溜まり続ける。
        let fm = FileManager.default
        var kept: [String: Entry] = [:]
        var removedPaths = 0
        for (path, e) in decoded {
            if fm.fileExists(atPath: path) {
                kept[path] = e
            } else {
                removedPaths += 1
            }
        }
        // 残った索引がまだ使っているハッシュは消さない
        // (内容が同じ動画は同じ画像を指すことがある)。
        let inUse = Set(kept.values.map { $0.hash })
        var removedImages = 0
        for (_, e) in decoded where !inUse.contains(e.hash) {
            let f = Self.directory.appendingPathComponent("\(e.hash).jpg")
            if (try? fm.removeItem(at: f)) != nil { removedImages += 1 }
        }

        lock.lock()
        entries = kept
        if removedPaths > 0 { dirty = true }
        lock.unlock()

        if removedPaths > 0 {
            Log.info("サムネイルの索引を読み込みました "
                     + "(\(kept.count) 件、元ファイルが消えた \(removedPaths) 件を整理、"
                     + "画像 \(removedImages) 枚を削除)")
        } else {
            Log.info("サムネイルの索引を読み込みました (\(kept.count) 件)")
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
