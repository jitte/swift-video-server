import Foundation

/// メディア情報の永続キャッシュと、背後で走る取得キュー。
///
/// 一覧を返すたびにファイルごとへ ffprobe を起動すると、
/// NAS 上の大量のファイルでは応答が返らずクライアントが
/// Connection Timeout になる。
/// そこで一覧では「キャッシュにあるものだけ」を即座に返し、
/// 未取得のものは背後で調べてキャッシュに足す。
/// 次に同じフォルダを開いたときには揃っている。
final class MediaInfoCache: @unchecked Sendable {
    static let shared = MediaInfoCache()

    /// ファイルの同一性は パス + サイズ + 更新日時 で判定する。
    private struct Entry: Codable {
        var size: Int
        var modified: Double
        var info: MediaInfo
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var dirty = false

    private static var fileURL: URL {
        Configuration.supportDirectory.appendingPathComponent("mediainfo.json")
    }

    private var saveTimer: DispatchSourceTimer?

    private init() {
        load()
        // 変更をまとめて書き出す。
        // Timer は RunLoop のあるスレッドでしか発火しないため、
        // サーバ内では DispatchSourceTimer を使う。
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.saveIfNeeded() }
        t.resume()
        saveTimer = t
    }

    // MARK: 取り出し

    /// キャッシュにあれば返す。取得は始めない。
    func lookup(url: URL, size: Int, modified: Date) -> MediaInfo? {
        let mtime = modified.timeIntervalSince1970
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[url.path], e.size == size, abs(e.modified - mtime) < 1 else {
            return nil
        }
        return e.info
    }

    /// キャッシュにあれば返す。無ければ nil を返し、前景の先頭で取得を始める。
    /// 個別に要求されたもの (表示中のサムネイルなど) に使う。
    func cachedOrFetch(url: URL, size: Int, modified: Date) -> MediaInfo? {
        if let hit = lookup(url: url, size: size, modified: modified) { return hit }
        request([(url, size, modified)], scope: "item:\(url.path)", lane: .foreground)
        return nil
    }

    /// まとめて取得を依頼する。順序を保って待ち行列の先頭に入る。
    /// ffprobe はヘッダしか読まないので、1GB を超える動画でも 1 件は短い。
    func request(_ files: [(url: URL, size: Int, modified: Date)], scope: String,
                 lane: WorkQueue.Lane) {
        let missing = files.filter { lookup(url: $0.url, size: $0.size, modified: $0.modified) == nil }
        let items: [(key: String, work: (WorkQueue.Job) -> Void)] = missing.map { f in
            ("probe:\(f.url.path)", { [weak self] job in
                guard let self,
                      self.lookup(url: f.url, size: f.size, modified: f.modified) == nil,
                      let probed = MediaInfo.runProbe(url: f.url, job: job)
                else { return }
                self.store(url: f.url, size: f.size, modified: f.modified, info: probed)
            })
        }
        WorkQueue.shared.submit(items, scope: scope, lane: lane)
    }

    private func store(url: URL, size: Int, modified: Date, info: MediaInfo) {
        lock.lock()
        entries[url.path] = Entry(size: size, modified: modified.timeIntervalSince1970, info: info)
        dirty = true
        lock.unlock()
    }

    /// 必要なら今すぐ調べる。再生開始時のように結果が要る場面で使う。
    /// job を渡すと、その仕事の取り消しと優先度が ffprobe にも効く。
    func fetchNow(url: URL, size: Int, modified: Date, job: WorkQueue.Job? = nil) -> MediaInfo? {
        if let hit = lookup(url: url, size: size, modified: modified) { return hit }
        guard let probed = MediaInfo.runProbe(url: url, job: job) else { return nil }
        store(url: url, size: size, modified: modified, info: probed)
        return probed
    }

    /// 保持している情報を捨て、ファイルも消す。
    /// 消しても次に一覧を開いたときに調べ直されるだけで、失われるものはない。
    func clear() {
        lock.lock()
        entries.removeAll()
        // 消した直後に書き戻さないよう、未保存の印も落とす。
        dirty = false
        lock.unlock()
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    // MARK: 永続化

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return }

        // 元の動画が消えているものは捨てる。
        let fm = FileManager.default
        let kept = decoded.filter { fm.fileExists(atPath: $0.key) }
        let removed = decoded.count - kept.count

        lock.lock()
        entries = kept
        if removed > 0 { dirty = true }
        lock.unlock()

        if removed > 0 {
            Log.info("メディア情報のキャッシュを読み込みました "
                     + "(\(kept.count) 件、消えた \(removed) 件を整理)")
        } else {
            Log.info("メディア情報のキャッシュを読み込みました (\(kept.count) 件)")
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
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    func flush() { saveIfNeeded() }
}
