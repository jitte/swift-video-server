import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import VideoServerCore

/// サーバ本体。
/// 1 つのポートで平文 HTTP と TLS の両方を受ける。
///
/// GUI から起動・停止するため、bind するだけの start() と
/// 終了まで待つ waitUntilStopped() を分けてある。
public final class VideoServer {
    let config: Configuration
    let library: Library
    let playback: PlaybackService
    let streamTokens = StreamTokens()
    let sessions = PlaybackSessions()
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?

    public private(set) var isRunning = false

    public init(config: Configuration) {
        self.config = config
        self.library = Library(config: config)
        self.playback = PlaybackService(library: library, sessions: sessions)
    }

    /// 待受を開始する。ブロックしない。
    public func start() throws {
        guard !isRunning else { return }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.group = group

        let (chain, key) = try CertificateStore.loadOrCreate()
        var tlsConfig = TLSConfiguration.makeServerConfiguration(certificateChain: chain, privateKey: key)
        tlsConfig.applicationProtocols = ["http/1.1"]

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [self] channel in
                let sniffer = TLSSniffingHandler(
                    tlsConfiguration: tlsConfig,
                    configurePlain: { ch in self.configureHTTP(channel: ch, secure: false) },
                    configureTLS: { ch in self.configureHTTP(channel: ch, secure: true) }
                )
                return channel.pipeline.addHandler(sniffer)
            }

        do {
            channel = try bootstrap.bind(host: "0.0.0.0", port: config.port).wait()
        } catch {
            try? group.syncShutdownGracefully()
            self.group = nil
            throw error
        }
        isRunning = true
        Log.info("待受開始 0.0.0.0:\(config.port)")
    }

    /// 待受を止める。
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        // 変換中のセッションと一時ファイルを片付ける。
        sessions.removeAll()
        // 取得済みのメディア情報を書き出しておく。
        MediaInfoCache.shared.flush()
        SnapshotStore.shared.flush()
        try? channel?.close().wait()
        channel = nil
        try? group?.syncShutdownGracefully()
        group = nil
        Log.info("待受停止")
    }

    /// サーバが止まるまで待つ (コマンドライン用)。
    public func waitUntilStopped() throws {
        try channel?.closeFuture.wait()
    }

    /// コマンドライン用: 起動して情報を表示し、終了まで待つ。
    public func run() throws {
        try start()
        print("Swift Video Server を起動しました")
        print("  待受        : 0.0.0.0:\(config.port) (平文 HTTP / TLS 兼用)")
        print("  サーバ名    : \(config.serverName)")
        print("  設定        : \(Configuration.configURL.path)")
        for share in config.shares {
            print("  共有フォルダ: \(share.displayName) -> \(share.path)")
        }
        print("停止は Ctrl-C")

        try waitUntilStopped()
    }

    /// HTTP のパイプラインを組む。平文と TLS で共通。
    private func configureHTTP(channel: Channel, secure: Bool) -> EventLoopFuture<Void> {
        let httpHandler = HTTPHandler(config: config, library: library, playback: playback,
                                      streamTokens: streamTokens, sessions: sessions,
                                      secure: secure)
        return channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
            channel.pipeline.addHandler(httpHandler)
        }
    }
}
