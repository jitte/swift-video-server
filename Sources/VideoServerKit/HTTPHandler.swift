import Foundation
import NIOCore
import NIOHTTP1
import NIOFoundationCompat
import VideoServerCore

/// HTTP リクエストを処理する中心。
///
/// 平文側と TLS 側で同じものを使う。平文で受けるのは、端末に信頼させる前の
/// CA 証明書 (/cert.crt) の配布だけで、それ以外は HTTPS へ転送する。
final class HTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let config: Configuration
    private let library: Library
    private let streamTokens: StreamTokens
    private let sessions: PlaybackSessions
    /// TLS で受けた接続か。
    private let secure: Bool
    /// ブラウザ版クライアント用の API。
    private let web: WebAPI

    private var head: HTTPRequestHead?
    private var body: ByteBuffer?

    init(config: Configuration, library: Library, playback: PlaybackService,
         streamTokens: StreamTokens, sessions: PlaybackSessions, secure: Bool) {
        self.secure = secure
        self.config = config
        self.library = library
        self.streamTokens = streamTokens
        self.sessions = sessions
        self.web = WebAPI(config: config, library: library, streamTokens: streamTokens,
                          sessions: sessions, playback: playback)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            head = h
            body = context.channel.allocator.buffer(capacity: 0)
        case .body(var chunk):
            body?.writeBuffer(&chunk)
        case .end:
            guard let head else { return }
            let bodyData = body.flatMap { $0.getData(at: $0.readerIndex, length: $0.readableBytes) } ?? Data()
            self.head = nil
            self.body = nil
            route(context: context, head: head, body: bodyData)
        }
    }

    // MARK: ルーティング

    private func route(context: ChannelHandlerContext, head: HTTPRequestHead, body: Data) {
        let uri = head.uri
        // クライアントが何を要求しているかを追えるようにする。
        let peer = context.channel.remoteAddress?.description ?? "?"
        let range = head.headers.first(name: "Range").map { " Range=\($0)" } ?? ""
        Log.request("\(head.method) \(uri)\(range) from \(peer)")
        let path = String(uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        let query = Self.parseQuery(uri)

        // 平文で来たものは HTTPS へ回す。姿勢センサーなどは secure context でしか
        // 使えないうえ、PIN の Cookie を平文で流したくない。
        // CA 証明書だけは、まだ信頼させていない端末が取りに来るので平文で返す。
        if !secure, path != "/cert.crt" {
            // 転送先は Host から組み立てる。無ければ (HTTP/1.0 など) 案内できない。
            if let host = head.headers.first(name: "Host"), !host.isEmpty {
                redirect(context: context, head: head, to: "https://\(host)\(uri)")
            } else {
                respond(context: context, head: head, status: .badRequest,
                        contentType: "text/plain", body: Array("use https\n".utf8))
            }
            return
        }

        switch path {
        case "/cert.crt":
            // 端末に信頼させるためのローカル CA 証明書。
            // iOS の Safari でこの URL を開くと構成プロファイルとして
            // 取り込める (取り込んだあと、証明書信頼設定での有効化も要る)。
            if let pem = CertificateStore.caCertificatePEM() {
                respond(context: context, head: head, status: .ok,
                        contentType: "application/x-x509-ca-cert", body: Array(pem))
            } else {
                respond(context: context, head: head, status: .notFound,
                        contentType: "text/plain", body: Array("no certificate".utf8))
            }

        default:
            if path.hasPrefix("/api/") {
                // 初めて開く NAS 上のフォルダの走査や、再生開始時の
                // キーフレーム走査 (1GB を超える動画では数十秒) を待つことがある。
                // イベントループで待つと、同じスレッドに載った他の接続まで止まる。
                let channel = context.channel
                let web = self.web
                let cookie = head.headers.first(name: "Cookie")
                Self.offload(channel: channel, head: head) {
                    let reply = web.handle(path: path, query: query, body: body,
                                           method: head.method, cookie: cookie)
                    var extra = HTTPHeaders()
                    if let c = reply.setCookie { extra.add(name: "Set-Cookie", value: c) }
                    return (reply.status, reply.contentType, reply.body, extra)
                }
                return
            }
            // 配信も PIN を入力した端末にだけ返す。<video> や HLS のセグメント取得は
            // ブラウザが自前で出す要求だが、同じオリジンなので Cookie が付いてくる。
            if path.hasPrefix(Self.streamPrefix) || path.hasPrefix(Playlist.prefix),
               !BrowserAuth.shared.isValid(
                   token: BrowserAuth.token(fromCookieHeader: head.headers.first(name: "Cookie")),
                   config: config) {
                respond(context: context, head: head, status: .forbidden,
                        contentType: "text/plain", body: Array("PIN が必要です\n".utf8))
                return
            }
            if path.hasPrefix(Self.streamPrefix) {
                handleDirectStream(context: context, head: head,
                                   token: String(path.dropFirst(Self.streamPrefix.count)))
                return
            }
            if path.hasPrefix(Playlist.prefix) {
                handleHLS(context: context, head: head, path: path)
                return
            }
            // 残りはブラウザ版クライアントの静的ファイル。
            handleStatic(context: context, head: head, path: path)
        }
    }

    /// 処理をイベントループの外で行い、応答はイベントループに戻って書く。
    ///
    /// 接続上で次の要求が先に処理されることはない。NIO の HTTP パイプラインが
    /// 応答を書き終えるまで次の要求を渡さないため。
    private static func offload(
        channel: Channel, head: HTTPRequestHead,
        _ work: @escaping () -> (HTTPResponseStatus, String, Data, HTTPHeaders)
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let (status, contentType, body, extra) = work()
            channel.eventLoop.execute {
                var headers = extra
                headers.add(name: "Content-Type", value: contentType)
                headers.add(name: "Content-Length", value: "\(body.count)")
                headers.add(name: "Date", value: httpDate())
                headers.add(name: "Connection", value: head.isKeepAlive ? "keep-alive" : "close")
                let h = HTTPResponseHead(version: head.version, status: status, headers: headers)
                channel.write(HTTPServerResponsePart.head(h), promise: nil)
                if !body.isEmpty {
                    var buf = channel.allocator.buffer(capacity: body.count)
                    buf.writeBytes(body)
                    channel.write(HTTPServerResponsePart.body(.byteBuffer(buf)), promise: nil)
                }
                channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
                    if !head.isKeepAlive { channel.close(promise: nil) }
                }
            }
        }
    }

    // MARK: HLS (変換再生)

    /// /hls/<セッション id>/<ファイル>
    private func handleHLS(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) {
        let parts = path.dropFirst(Playlist.prefix.count)
            .split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let session = sessions.lookup(parts[0]) else {
            respond(context: context, head: head, status: .notFound,
                    contentType: "text/plain", body: Array("no session".utf8))
            return
        }
        switch parts[1] {
        case "index.m3u8":
            respond(context: context, head: head, status: .ok,
                    contentType: "application/vnd.apple.mpegurl",
                    body: Array(Playlist.index(for: session).utf8))
        case "media.m3u8":
            respond(context: context, head: head, status: .ok,
                    contentType: "application/vnd.apple.mpegurl",
                    body: Array(Playlist.media(for: session).utf8))
        case let file where file.hasSuffix(".ts"):
            guard let index = Int(file.dropLast(3)), index >= 0, index < session.segmentCount else {
                respond(context: context, head: head, status: .notFound,
                        contentType: "text/plain", body: Array("bad segment".utf8))
                return
            }
            sendSegment(context: context, head: head, session: session, index: index)
        default:
            respond(context: context, head: head, status: .notFound,
                    contentType: "text/plain", body: Array("not found".utf8))
        }
    }

    private func sendSegment(context: ChannelHandlerContext, head: HTTPRequestHead,
                             session: PlaybackSession, index: Int) {
        // ffmpeg は時間がかかるので、イベントループを止めないよう別スレッドで動かす。
        let channel = context.channel
        let keepAlive = head.isKeepAlive
        let version = head.version
        DispatchQueue.global(qos: .userInitiated).async {
            let began = Date()
            // ffmpeg が書き出すのを待って読む。
            let data = session.segmentData(index)
            let elapsed = Date().timeIntervalSince(began)
            Log.info(String(format: "セグメント%d 生成 %.2f秒 %@",
                            index, elapsed, data.map { "\($0.count)バイト" } ?? "失敗"))

            channel.eventLoop.execute {
                guard let data else {
                    var headers = HTTPHeaders()
                    headers.add(name: "Content-Length", value: "0")
                    let h = HTTPResponseHead(version: version, status: .internalServerError, headers: headers)
                    channel.writeAndFlush(HTTPServerResponsePart.head(h), promise: nil)
                    channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
                        if !keepAlive { channel.close(promise: nil) }
                    }
                    return
                }
                var headers = HTTPHeaders()
                headers.add(name: "Content-Type", value: "video/MP2T")
                headers.add(name: "Content-Length", value: "\(data.count)")
                headers.add(name: "Date", value: Self.httpDate())
                headers.add(name: "Connection", value: keepAlive ? "keep-alive" : "close")
                let h = HTTPResponseHead(version: version, status: .ok, headers: headers)
                channel.write(HTTPServerResponsePart.head(h), promise: nil)
                var buf = channel.allocator.buffer(capacity: data.count)
                buf.writeBytes(data)
                channel.write(HTTPServerResponsePart.body(.byteBuffer(buf)), promise: nil)
                channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
                    if !keepAlive { channel.close(promise: nil) }
                }
            }
        }
    }

    // MARK: ブラウザ版クライアントの静的ファイル

    private func handleStatic(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) {
        guard let file = StaticFiles.lookup(path: path) else {
            respond(context: context, head: head, status: .notFound,
                    contentType: "text/plain", body: Array("not found".utf8))
            return
        }

        // キャッシュの指定が無いとブラウザが独自の判断で古いものを使い続ける。
        // 再ビルドで index.html と app.js の版が食い違うと、片方にしか無い
        // 要素をもう片方が触って画面が動かなくなるため、必ず確認させる。
        // no-cache は「使う前に毎回確認する」であって「保存しない」ではないので、
        // 変わっていなければ 304 で本文を省ける。
        var headers = HTTPHeaders()
        headers.add(name: "ETag", value: file.etag)
        headers.add(name: "Cache-Control", value: "no-cache")

        if head.headers.first(name: "If-None-Match") == file.etag {
            writeHead(context: context, head: head, status: .notModified, headers: headers)
            writeEnd(context: context, head: head)
            return
        }

        headers.add(name: "Content-Type", value: file.contentType)
        headers.add(name: "Content-Length", value: "\(file.data.count)")
        writeHead(context: context, head: head, status: .ok, headers: headers)

        // どれも数十 KB 程度でローカルにあるため、
        // 動画のように別スレッドへ逃がさずそのまま返す。
        if head.method != .HEAD, !file.data.isEmpty {
            var buf = context.channel.allocator.buffer(capacity: file.data.count)
            buf.writeBytes(file.data)
            context.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
        }
        writeEnd(context: context, head: head)
    }

    // MARK: 直接ストリーム (Range 対応)

    /// ダイレクト再生の置き場所。後ろに /api/play が発行した鍵が付く。
    static let streamPrefix = "/stream/"

    private func handleDirectStream(context: ChannelHandlerContext, head: HTTPRequestHead, token: String) {
        guard let item = streamTokens.lookup(token),
              let url = library.resolve(item),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let total = attrs[.size] as? Int
        else {
            respond(context: context, head: head, status: .notFound,
                    contentType: "text/plain", body: Array("not found".utf8))
            return
        }

        // Range: bytes=start-end を解釈する。iOS のプレーヤーは必ず付けてくる。
        let rangeHeader = head.headers.first(name: "Range")
        let (start, end) = Self.parseRange(rangeHeader, total: total)
        guard start <= end, start >= 0, end < total else {
            var headers = HTTPHeaders()
            headers.add(name: "Content-Range", value: "bytes */\(total)")
            writeHead(context: context, head: head, status: .rangeNotSatisfiable, headers: headers)
            writeEnd(context: context, head: head)
            return
        }

        let length = end - start + 1
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: Self.contentType(forVideo: url.pathExtension.lowercased()))
        headers.add(name: "Content-Length", value: "\(length)")
        headers.add(name: "Accept-Ranges", value: "bytes")
        headers.add(name: "ETag", value: "\"\(token)\"")
        if rangeHeader != nil {
            headers.add(name: "Content-Range", value: "bytes \(start)-\(end)/\(total)")
        }

        let status: HTTPResponseStatus = rangeHeader != nil ? .partialContent : .ok
        writeHead(context: context, head: head, status: status, headers: headers)

        if head.method == .HEAD {
            writeEnd(context: context, head: head)
            return
        }

        sendFileChunks(context: context, head: head, url: url, start: start, length: length)
    }

    /// 直接再生で返す Content-Type。
    /// ブラウザに渡すのは mp4 / m4v / mov だけだが、他も素直な値を返す。
    static func contentType(forVideo ext: String) -> String {
        switch ext {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "avi": return "video/x-msvideo"
        case "ts", "m2ts": return "video/mp2t"
        default: return "application/octet-stream"
        }
    }

    /// ファイルを分割して書き出す。
    /// 巨大な動画を一度に読むとメモリを食い潰すため、
    /// 書き込み完了を待ちながら次のチャンクを送る (背圧をかける)。
    private func sendFileChunks(
        context: ChannelHandlerContext,
        head: HTTPRequestHead,
        url: URL,
        start: Int,
        length: Int
    ) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            writeEnd(context: context, head: head)
            return
        }
        do { try handle.seek(toOffset: UInt64(start)) } catch {
            try? handle.close()
            writeEnd(context: context, head: head)
            return
        }

        let chunkSize = 256 * 1024
        let channel = context.channel
        let keepAlive = head.isKeepAlive

        func writeNext(remaining: Int) {
            guard remaining > 0, channel.isActive else {
                try? handle.close()
                let end = HTTPServerResponsePart.end(nil)
                _ = channel.writeAndFlush(end).always { _ in
                    if !keepAlive { channel.close(promise: nil) }
                }
                return
            }
            let want = min(chunkSize, remaining)
            let data = (try? handle.read(upToCount: want)) ?? Data()
            guard !data.isEmpty else {
                writeNext(remaining: 0)
                return
            }
            var buf = channel.allocator.buffer(capacity: data.count)
            buf.writeBytes(data)
            let part = HTTPServerResponsePart.body(.byteBuffer(buf))
            channel.writeAndFlush(part).whenComplete { result in
                switch result {
                case .success:
                    writeNext(remaining: remaining - data.count)
                case .failure:
                    try? handle.close()
                    channel.close(promise: nil)
                }
            }
        }
        writeNext(remaining: length)
    }

    // MARK: 応答の下請け

    private func writeHead(context: ChannelHandlerContext, head: HTTPRequestHead,
                           status: HTTPResponseStatus, headers: HTTPHeaders) {
        var headers = headers
        headers.add(name: "Date", value: Self.httpDate())
        if head.isKeepAlive {
            headers.add(name: "Connection", value: "keep-alive")
        } else {
            headers.add(name: "Connection", value: "close")
        }
        let responseHead = HTTPResponseHead(version: head.version, status: status, headers: headers)
        context.writeAndFlush(wrapOutboundOut(.head(responseHead)), promise: nil)
    }

    private func writeEnd(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let channel = context.channel
        let keepAlive = head.isKeepAlive
        context.writeAndFlush(wrapOutboundOut(.end(nil))).always { _ in
            if !keepAlive { channel.close(promise: nil) }
        }.whenFailure { _ in }
    }

    private func redirect(context: ChannelHandlerContext, head: HTTPRequestHead, to location: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Location", value: location)
        respond(context: context, head: head, status: .found,
                contentType: "text/plain", body: Array("\(location)\n".utf8),
                extraHeaders: headers)
    }

    private func respond(context: ChannelHandlerContext, head: HTTPRequestHead,
                         status: HTTPResponseStatus, contentType: String, body: [UInt8],
                         extraHeaders: HTTPHeaders = HTTPHeaders()) {
        var headers = extraHeaders
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(body.count)")
        writeHead(context: context, head: head, status: status, headers: headers)
        if !body.isEmpty {
            var buf = context.channel.allocator.buffer(capacity: body.count)
            buf.writeBytes(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
        }
        writeEnd(context: context, head: head)
    }

    // MARK: 補助

    static func parseQuery(_ uri: String) -> [String: String] {
        guard let q = uri.firstIndex(of: "?") else { return [:] }
        let query = uri[uri.index(after: q)...]
        var out: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            out[key] = value
        }
        return out
    }

    /// "bytes=start-end" を解釈する。end 省略は最後まで。
    static func parseRange(_ header: String?, total: Int) -> (Int, Int) {
        guard let header, header.hasPrefix("bytes=") else { return (0, total - 1) }
        let spec = header.dropFirst("bytes=".count)
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return (0, total - 1) }

        if parts[0].isEmpty, parts.count > 1, let suffix = Int(parts[1]) {
            // "bytes=-N" は末尾 N バイト。
            let start = max(0, total - suffix)
            return (start, total - 1)
        }
        let start = Int(parts[0]) ?? 0
        let end = (parts.count > 1 && !parts[1].isEmpty) ? (Int(parts[1]) ?? total - 1) : total - 1
        return (start, min(end, total - 1))
    }

    static func httpDate() -> String { httpDate(Date()) }

    static func httpDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.string(from: date)
    }
}
