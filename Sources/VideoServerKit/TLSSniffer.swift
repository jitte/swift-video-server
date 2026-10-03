import NIOCore
import NIOSSL

/// 同一ポートで平文 HTTP と TLS の両方を受けるためのハンドラ。
///
/// 端末に信頼させる CA 証明書 (/cert.crt) は、信頼させる前の端末でも
/// 取れるよう平文で配る。ブラウザ版クライアント本体は HTTPS で開く
/// (姿勢センサーに secure context が要る)。どちらも 1 つのポートで受ける。
///
/// 判別は先頭 1 バイトで足りる。TLS レコードは必ず 0x16 (handshake) で始まり、
/// 平文 HTTP はメソッド名の ASCII ("G","P" など) で始まるため衝突しない。
///
/// 判別できるまで受信データを溜め、パイプラインを組み替えてから
/// 溜めた分をパイプラインの先頭に流し直す。
final class TLSSniffingHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let tlsConfiguration: TLSConfiguration
    private let configurePlain: (Channel) -> EventLoopFuture<Void>
    private let configureTLS: (Channel) -> EventLoopFuture<Void>

    private var pending: ByteBuffer?
    private var decided = false

    init(
        tlsConfiguration: TLSConfiguration,
        configurePlain: @escaping (Channel) -> EventLoopFuture<Void>,
        configureTLS: @escaping (Channel) -> EventLoopFuture<Void>
    ) {
        self.tlsConfiguration = tlsConfiguration
        self.configurePlain = configurePlain
        self.configureTLS = configureTLS
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        if pending == nil {
            pending = incoming
        } else {
            pending!.writeBuffer(&incoming)
        }

        // 切替処理の実行中に届いた分は pending に溜まり、完了時にまとめて流す。
        guard !decided else { return }
        guard let first = pending!.getInteger(at: pending!.readerIndex, as: UInt8.self) else {
            return  // まだ 1 バイトも無い
        }

        decided = true
        let isTLS = (first == 0x16)
        let channel = context.channel

        let setup: EventLoopFuture<Void>
        if isTLS {
            do {
                let sslContext = try NIOSSLContext(configuration: tlsConfiguration)
                // 自分より前段に TLS 復号を挿す。
                try channel.pipeline.syncOperations.addHandler(
                    NIOSSLServerHandler(context: sslContext),
                    position: .before(self)
                )
            } catch {
                channel.close(promise: nil)
                return
            }
            setup = configureTLS(channel)
        } else {
            setup = configurePlain(channel)
        }

        setup.flatMap {
            channel.pipeline.removeHandler(self)
        }.whenComplete { result in
            switch result {
            case .success:
                // 溜めた分をパイプラインの先頭から流し直す。
                // TLS の場合はここで挿した NIOSSLServerHandler が最初に受ける。
                if let buffered = self.pending {
                    self.pending = nil
                    // NIOAny で包むと非推奨の多重定義が選ばれる。
                    // ByteBuffer は Sendable なので、そのまま渡せば新しい方が使われる。
                    channel.pipeline.fireChannelRead(buffered)
                    channel.pipeline.fireChannelReadComplete()
                }
            case .failure:
                channel.close(promise: nil)
            }
        }
    }

    /// 判別前の readComplete は後段へ伝えない (まだ後段が無い)。
    func channelReadComplete(context: ChannelHandlerContext) {
        if !decided { return }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
