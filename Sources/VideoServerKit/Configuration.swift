import Foundation

/// サーバ設定の永続化。
public struct Configuration: Codable, Sendable {
    public var serverName: String
    public var port: Int
    public var shares: [Share]
    /// ブラウザ版クライアントを開くときに要求する PIN。
    /// nil か空なら要求しない。
    public var browserPIN: String?

    /// 既定の待受ポート。平文 HTTP と HTTPS を同じ番号で受ける。
    public static let defaultPort = 44433

    public struct Share: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var displayName: String
        public var path: String

        public init(id: String, displayName: String, path: String) {
            self.id = id
            self.displayName = displayName
            self.path = path
        }
    }

    public init(serverName: String, port: Int, shares: [Share], browserPIN: String? = nil) {
        self.serverName = serverName
        self.port = port
        self.shares = shares
        self.browserPIN = browserPIN
    }

    /// 設定・証明書・キャッシュの置き場所。
    /// 既定は ~/Library/Application Support/swift-video-server/。
    nonisolated(unsafe) private static var directoryOverride: URL?

    public static var supportDirectory: URL {
        if let directoryOverride { return directoryOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("swift-video-server", isDirectory: true)
    }

    /// 置き場所を差し替える。
    ///
    /// 動作確認のとき、本番の設定・証明書・キャッシュに触れずに
    /// サーバを動かせるようにするため。ログもキャッシュも証明書も
    /// すべてこの下に置かれるので、ここ 1 つを差し替えれば隔離できる。
    ///
    /// 設定や証明書を読む前に呼ぶこと。キャッシュ類は最初に触れた時点で
    /// 置き場所を決めるため、あとから変えても反映されない。
    public static func useSupportDirectory(_ path: String) {
        directoryOverride = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
    }

    public static var configURL: URL { supportDirectory.appendingPathComponent("config.json") }

    /// 読み込む。無ければ既定値を作って保存する。
    public static func load(defaultMediaPath: String?) throws -> Configuration {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: configURL),
           var cfg = try? JSONDecoder().decode(Configuration.self, from: data) {
            // 起動引数でメディアパスが指定されたら「追加」する。
            // 既存の共有を置き換えてはいけない (利用者が設定したものを失う)。
            if let p = defaultMediaPath, !cfg.shares.contains(where: { $0.path == p }) {
                cfg.shares.append(Share(id: Self.newGUID(),
                                        displayName: URL(fileURLWithPath: p).lastPathComponent,
                                        path: p))
                try cfg.save()
            }
            return cfg
        }
        let path = defaultMediaPath ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].path
        let cfg = Configuration(
            serverName: Host.current().localizedName ?? "Swift Video Server",
            port: Self.defaultPort,
            shares: [Share(id: Self.newGUID(),
                           displayName: URL(fileURLWithPath: path).lastPathComponent,
                           path: path)]
        )
        try cfg.save()
        return cfg
    }

    public func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Self.configURL, options: .atomic)
    }

    /// share id は GUID 形式 (小文字)。
    static func newGUID() -> String {
        UUID().uuidString.lowercased()
    }
}
