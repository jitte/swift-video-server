import Foundation
import VideoServerCore

/// 一覧に並ぶ 1 項目。フォルダを読んだときの値をそのまま持つ。
///
/// 尺やサムネイルの有無は持たない。背後で取得が進むにつれて変わるので、
/// 応答を作るときに MediaInfoCache / SnapshotStore から引く。
struct LibraryEntry: Sendable {
    enum Kind: Sendable { case folder, video }

    var kind: Kind
    var item: ItemID
    var url: URL
    var name: String
    /// 動画の大きさ (バイト)。フォルダは 0。
    var size: Int
    var modified: Date
}

/// 共有フォルダを走査し、一覧を組み立てる。
public struct Library: Sendable {
    let config: Configuration

    public init(config: Configuration) {
        self.config = config
    }

    /// 再生対象とみなす拡張子。
    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "avi", "wmv", "flv", "mpg", "mpeg", "ts", "m2ts", "3gp", "webm",
    ]

    // MARK: 共有フォルダの解決

    func share(withID id: String) -> Configuration.Share? {
        config.shares.first { $0.id == id }
    }

    /// 項目から実ファイルパスを解決する。
    /// 共有フォルダの外に出る相対パスは拒否する (パストラバーサル対策)。
    public func resolve(_ item: ItemID) -> URL? {
        guard let share = share(withID: item.share) else { return nil }
        let root = URL(fileURLWithPath: share.path).standardizedFileURL
        let target = root.appendingPathComponent(item.path).standardizedFileURL
        guard target.path == root.path || target.path.hasPrefix(root.path + "/") else { return nil }
        return target
    }

    // MARK: トップレベル

    /// 共有フォルダの一覧。1 件ずつフォルダとして返す。
    func topLevelEntries() -> [LibraryEntry] {
        // 共有フォルダの一覧を見せた時点で、各共有フォルダの中身を先読みする。
        // 次に開くのはそのどれかなので、開いたときに待たずに済む。
        let roots = config.shares.map {
            (url: URL(fileURLWithPath: $0.path), item: ItemID(share: $0.id, path: ""))
        }
        let byPath = Dictionary(roots.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        DirectoryCache.shared.prewarm(keys: roots.map { $0.url.path }) { [self] path in
            guard let r = byPath[path] else { return [] }
            return self.buildChildren(of: r.item, at: r.url)
        }

        return config.shares.compactMap { share in
            let url = URL(fileURLWithPath: share.path)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            return LibraryEntry(kind: .folder, item: ItemID(share: share.id, path: ""), url: url,
                                name: share.displayName, size: 0,
                                modified: (attrs[.modificationDate] as? Date) ?? Date())
        }
    }

    // MARK: フォルダを開く

    /// 項目そのものを読む。
    func entry(for item: ItemID) -> LibraryEntry? {
        guard let url = resolve(item) else { return nil }
        // 有無・種別・大きさ・更新日をまとめて 1 回で読む。
        // fileExists と attributesOfItem に分けると NAS を 2 往復することになる。
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        else { return nil }
        let isDir = values.isDirectory ?? false
        let name = item.path.isEmpty
            ? (share(withID: item.share)?.displayName ?? url.lastPathComponent)
            : url.lastPathComponent
        return LibraryEntry(kind: isDir ? .folder : .video, item: item, url: url, name: name,
                            size: isDir ? 0 : (values.fileSize ?? 0),
                            modified: values.contentModificationDate ?? Date())
    }

    /// フォルダを開く。中身を返し、中の動画の情報取得と子フォルダの先読みを依頼する。
    func open(_ folder: LibraryEntry) -> [LibraryEntry] {
        guard folder.kind == .folder else { return [] }
        let children = self.children(of: folder.item, at: folder.url)
        requestBackgroundWork(forFolder: folder.url)
        prewarmSubfolders(of: folder.url)
        return children
    }

    /// 今見ているフォルダの動画について、動画情報とサムネイルを依頼する。
    ///
    /// 開いたフォルダを「今見ているもの」にし、それまで前景だった別フォルダの
    /// 仕事は背景へ回す (捨てずに続ける)。先頭に入るので、あとから
    /// 入れた方が先に処理される。一覧に尺を早く出したいので、
    /// サムネイルを先に入れ、動画情報をその前に入れる。
    func requestBackgroundWork(forFolder url: URL) {
        let files = DirectoryCache.shared.videoFiles(for: url.path)
        guard !files.isEmpty else { return }
        let scope = "folder:\(url.path)"
        WorkQueue.shared.focus(kind: "folder:", scope: scope)
        SnapshotStore.shared.request(files, scope: scope, lane: .foreground)
        MediaInfoCache.shared.request(files, scope: scope, lane: .foreground)
    }

    /// 開いたフォルダの子フォルダの一覧を背後で先に作っておく。
    ///
    /// 初めて開くフォルダは NAS を読むまで一覧を返せず、中身が 1 件でも待たされる。
    /// 開いたフォルダの一段下だけを先読みしておけば、次に開くときは待たない。
    /// 先読みした一覧からさらに下は読まない (木全体を読みに行かないように)。
    func prewarmSubfolders(of url: URL) {
        let folders = DirectoryCache.shared.subfolders(for: url.path)
        guard !folders.isEmpty else { return }
        let byPath = Dictionary(folders.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        DirectoryCache.shared.prewarm(keys: folders.map { $0.url.path }) { [self] path in
            guard let f = byPath[path] else { return [] }
            return self.buildChildren(of: f.item, at: f.url)
        }
    }

    func children(of parent: ItemID, at url: URL) -> [LibraryEntry] {
        // 組み立て済みの一覧があればそれを返す。更新は背後で行う。
        DirectoryCache.shared.children(for: url.path) {
            self.buildChildren(of: parent, at: url)
        }
    }

    func buildChildren(of parent: ItemID, at url: URL) -> [LibraryEntry] {
        let fm = FileManager.default

        // 属性は一括で先読みする。
        // ファイルごとに attributesOfItem と fileExists を呼ぶと
        // 1 件につき 2 回 stat することになり、NAS (SMB) では
        // 558 件で 90 秒以上かかっていた。
        let keys: [URLResourceKey] = [
            .nameKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
        ]
        guard let urls = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let keySet = Set(keys)
        let sorted = urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }

        var out: [LibraryEntry] = []
        var videos: [(url: URL, size: Int, modified: Date)] = []
        var folders: [(url: URL, item: ItemID)] = []
        defer {
            DirectoryCache.shared.setVideoFiles(videos, for: url.path)
            DirectoryCache.shared.setSubfolders(folders, for: url.path)
        }
        for childURL in sorted {
            let name = childURL.lastPathComponent
            if name.hasPrefix(".") { continue }
            // 先読み済みなので、ここでの取り出しは往復を伴わない。
            let values = try? childURL.resourceValues(forKeys: keySet)
            let isDir = values?.isDirectory ?? false
            let modified = values?.contentModificationDate ?? Date()
            let size = values?.fileSize ?? 0

            let childID = parent.appending(name)

            if isDir {
                folders.append((childURL, childID))
                out.append(LibraryEntry(kind: .folder, item: childID, url: childURL,
                                        name: name, size: 0, modified: modified))
            } else {
                let ext = childURL.pathExtension.lowercased()
                guard Self.videoExtensions.contains(ext) else { continue }
                videos.append((childURL, size, modified))
                out.append(LibraryEntry(kind: .video, item: childID, url: childURL,
                                        name: name, size: size, modified: modified))
            }
        }
        return out
    }
}
