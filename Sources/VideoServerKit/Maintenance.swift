import Foundation

/// 保存している物の内訳と、その削除。
///
/// 扱うのは「消しても作り直せるもの」だけに絞る。
/// 設定 (config.json) と証明書 (ca.pem / cert.pem など) は
/// 消すとクライアントの登録がやり直しになるため、ここでは触らない。
public enum Maintenance {
    public enum Kind: String, CaseIterable, Sendable {
        case log
        case mediaInfo
        case snapshots
        case previews
        case sessions

        public var title: String {
            switch self {
            case .log: return "ログ"
            case .mediaInfo: return "動画情報のキャッシュ"
            case .snapshots: return "サムネイル"
            case .previews: return "スクラブ用のコマ画像"
            case .sessions: return "変換中の一時ファイル"
            }
        }

        public var detail: String {
            switch self {
            case .log:
                return "swift-video-server.log"
            case .mediaInfo:
                return "消すと次の一覧表示で調べ直します"
            case .snapshots:
                return "消すと次の一覧表示で作り直します"
            case .previews:
                return "消すと次の再生時に作り直します"
            case .sessions:
                return "再生中に消すとその再生は中断されます"
            }
        }
    }

    public struct Entry: Identifiable, Sendable {
        public var id: String { kind.rawValue }
        public let kind: Kind
        public let bytes: Int64

        public var title: String { kind.title }
        public var detail: String { kind.detail }
    }

    /// 種類ごとの使用量。
    public static func usage() -> [Entry] {
        Kind.allCases.map { Entry(kind: $0, bytes: size(of: $0)) }
    }

    /// 合計。
    public static func totalBytes() -> Int64 {
        Kind.allCases.reduce(0) { $0 + size(of: $1) }
    }

    public static func clear(_ kind: Kind) {
        switch kind {
        case .log:
            Log.clear()
        case .mediaInfo:
            MediaInfoCache.shared.clear()
        case .snapshots:
            SnapshotStore.shared.clear()
        case .previews:
            PreviewStore.shared.clear()
        case .sessions:
            // 変換中のものごと消す。再生中なら中断される。
            try? FileManager.default.removeItem(at: PlaybackSessions.workDirectory)
        }
        Log.info("\(kind.title)を削除しました")
    }

    public static func clearAll() {
        for kind in Kind.allCases { clear(kind) }
    }

    // MARK: 使用量の集計

    static func size(of kind: Kind) -> Int64 {
        switch kind {
        case .log:
            return fileSize(Log.fileURL)
        case .mediaInfo:
            return fileSize(Configuration.supportDirectory
                .appendingPathComponent("mediainfo.json"))
        case .snapshots:
            return fileSize(Configuration.supportDirectory
                .appendingPathComponent("snapshots.json"))
                + directorySize(SnapshotStore.directory)
        case .previews:
            return fileSize(Configuration.supportDirectory
                .appendingPathComponent("previews.json"))
                + directorySize(PreviewStore.directory)
        case .sessions:
            return directorySize(PlaybackSessions.workDirectory)
        }
    }

    static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    /// 配下をたどって合計する。件数が多くなりうるので
    /// ディレクトリ単位でまとめて数える。
    static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: url,
                                    includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                    options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }
}
