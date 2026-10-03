import Foundation
import VideoServerCore

/// フォルダの中身を組み立てた結果を持っておく。
///
/// NAS では readdir と 1 件ごとの stat だけでも時間がかかる。
/// 一度作った一覧はそのまま返し、更新は背後で行う。
/// 内容が変わっていれば次の要求から新しいものが返る。
final class DirectoryCache: @unchecked Sendable {
    static let shared = DirectoryCache()

    private struct Entry {
        var children: [LibraryEntry]
        var builtAt: Date
    }

    // 作り終わりを待つ要求を起こすため、NSLock ではなく NSCondition にする。
    private let lock = NSCondition()
    private var entries: [String: Entry] = [:]
    private var refreshing = Set<String>()

    /// 先読みの対象にする子フォルダの上限。
    /// 子フォルダが数百ある場合に NAS を読み続けないようにする。
    private let prewarmLimit = 30

    /// この時間を過ぎたら背後で作り直す。
    private let staleAfter: TimeInterval = 10

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .utility
        return q
    }()

    /// 一覧を得る。あるものは即返し、古ければ背後で更新する。
    /// 無いときだけその場で作る。
    func children(for key: String, build: @escaping () -> [LibraryEntry]) -> [LibraryEntry] {
        lock.lock()
        // 先読みなどで作っている最中なら、同じフォルダを二重に読まずに待つ。
        while entries[key] == nil, refreshing.contains(key) {
            lock.wait()
        }
        if let hit = entries[key] {
            lock.unlock()
            if Date().timeIntervalSince(hit.builtAt) > staleAfter {
                scheduleRefresh(key: key, build: build)
            }
            return hit.children
        }
        // 初回はその場で作る (ここは待たせるしかない)。
        // 作っている間に来た同じフォルダの要求は、上の待ちに入る。
        refreshing.insert(key)
        lock.unlock()

        let started = Date()
        let built = build()
        Log.info(String(format: "一覧を作成 %.2f秒 %d件 %@",
                        Date().timeIntervalSince(started), built.count, key))

        lock.lock()
        entries[key] = Entry(children: built, builtAt: Date())
        refreshing.remove(key)
        lock.broadcast()
        lock.unlock()
        return built
    }

    /// まだ一覧が無いフォルダを、背後で先に作っておく。
    /// 開いたフォルダの子を先読みしておけば、次にそこを開いたときに待たない。
    func prewarm(keys: [String], build: @escaping (String) -> [LibraryEntry]) {
        for key in keys.prefix(prewarmLimit) {
            lock.lock()
            let known = entries[key] != nil
            lock.unlock()
            if known { continue }
            scheduleRefresh(key: key) { build(key) }
        }
    }

    private func scheduleRefresh(key: String, build: @escaping () -> [LibraryEntry]) {
        lock.lock()
        if refreshing.contains(key) { lock.unlock(); return }
        refreshing.insert(key)
        lock.unlock()

        queue.addOperation { [weak self] in
            guard let self else { return }
            let built = build()
            self.lock.lock()
            self.entries[key] = Entry(children: built, builtAt: Date())
            self.refreshing.remove(key)
            // 作り終わりを待っている要求を起こす。
            self.lock.broadcast()
            self.lock.unlock()
        }
    }

    // MARK: フォルダ内の動画の控え

    private var videoFiles: [String: [(url: URL, size: Int, modified: Date)]] = [:]
    /// 動画 1 件ごとの大きさと更新日。一覧を作ったときの値をそのまま持つ。
    private var fileAttributes: [String: (size: Int, modified: Date)] = [:]

    /// 一覧を組み立てたときの動画ファイル。背景処理の依頼に使う。
    /// NAS を読み直さずに済む。
    func setVideoFiles(_ files: [(url: URL, size: Int, modified: Date)], for key: String) {
        lock.lock()
        videoFiles[key] = files
        for f in files { fileAttributes[f.url.path] = (f.size, f.modified) }
        lock.unlock()
    }

    func videoFiles(for key: String) -> [(url: URL, size: Int, modified: Date)] {
        lock.lock(); defer { lock.unlock() }
        return videoFiles[key] ?? []
    }

    /// 一覧を作ったときに分かっている大きさと更新日。
    ///
    /// サムネイルを 1 枚返すたびに NAS を stat すると、混んでいるときは
    /// 1 件で数百ミリ秒かかる。一覧に並ぶ数だけ積もり、表示が遅くなる。
    /// 一覧は 10 秒で作り直すので、ここから答えても古いままにはならない。
    func attributes(forFile path: String) -> (size: Int, modified: Date)? {
        lock.lock(); defer { lock.unlock() }
        return fileAttributes[path]
    }

    // MARK: フォルダ内の子フォルダの控え

    private var subfolders: [String: [(url: URL, item: ItemID)]] = [:]

    /// 一覧を組み立てたときの子フォルダ。先読みの依頼に使う。
    func setSubfolders(_ folders: [(url: URL, item: ItemID)], for key: String) {
        lock.lock(); subfolders[key] = folders; lock.unlock()
    }

    func subfolders(for key: String) -> [(url: URL, item: ItemID)] {
        lock.lock(); defer { lock.unlock() }
        return subfolders[key] ?? []
    }

    /// 共有フォルダの設定が変わったときなどに捨てる。
    func invalidateAll() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }
}
