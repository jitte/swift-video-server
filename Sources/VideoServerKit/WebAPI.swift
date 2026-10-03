import Foundation
import NIOHTTP1
import VideoServerCore

/// ブラウザ版クライアント用の JSON API。
///
/// 一覧やメディア情報は Library / DirectoryCache / MediaInfoCache / SnapshotStore
/// から取り出し、ブラウザ向けの素直な形に詰め替えて返す。
struct WebAPI: Sendable {
    let config: Configuration
    let library: Library
    let streamTokens: StreamTokens
    let sessions: PlaybackSessions
    let playback: PlaybackService

    struct Reply {
        var status: HTTPResponseStatus = .ok
        var contentType: String = "application/json"
        var body: Data
        /// 認証したときだけ入る。HTTPHandler が Set-Cookie として載せる。
        var setCookie: String?
    }

    // MARK: 入口

    func handle(path: String, query: [String: String], body: Data,
                method: HTTPMethod, cookie: String?) -> Reply {
        // 認証の入口と状態問い合わせは、認証前でも通す必要がある。
        switch path {
        case "/api/session":
            return Self.json(.object([
                "pinRequired": .bool(BrowserAuth.isEnabled(config)),
                "authenticated": .bool(
                    BrowserAuth.shared.isValid(
                        token: BrowserAuth.token(fromCookieHeader: cookie), config: config)),
            ]))

        case "/api/auth":
            guard method == .POST else { return Self.error(.methodNotAllowed, "POST のみ") }
            return authenticate(body: body)

        case "/api/logout":
            var reply = Self.json(.object(["ok": .bool(true)]))
            reply.setCookie = BrowserAuth.clearCookieValue()
            return reply

        default:
            break
        }

        // ここから先は PIN が設定されていれば認証済みであることを要求する。
        guard BrowserAuth.shared.isValid(
            token: BrowserAuth.token(fromCookieHeader: cookie), config: config)
        else {
            return Self.error(.unauthorized, "認証が必要です")
        }

        switch path {
        case "/api/shares":
            // 共有フォルダの一覧。ブラウザ側の出発点。
            return Self.json(.object([
                "serverName": .string(config.serverName),
                "items": .array(library.topLevelEntries().map(Self.browserItem)),
            ]))

        case "/api/list":
            guard let item = query["item"].flatMap(ItemID.init(token:)),
                  let entry = library.entry(for: item)
            else { return Self.error(.notFound, "item not found") }
            return Self.json(.object([
                "item": Self.browserItem(entry),
                "children": .array(library.open(entry).map(Self.browserItem)),
            ]))

        case "/api/snapshot":
            return snapshot(query: query)

        case "/api/diagnose":
            return diagnose(query: query)

        case "/api/diagnose/check":
            guard method == .POST else { return Self.error(.methodNotAllowed, "POST のみ") }
            return startCheck(body: body)

        case "/api/playback/status":
            guard let id = query["playbackId"], let session = sessions.lookup(id)
            else { return Self.error(.notFound, "そのセッションはありません") }
            return Self.json(session.status())

        case "/api/preview":
            return preview(query: query)

        case "/api/preview/sheet":
            return previewSheet(query: query)

        case "/api/play":
            guard method == .POST else { return Self.error(.methodNotAllowed, "POST のみ") }
            return play(body: body)

        case "/api/stop":
            guard method == .POST else { return Self.error(.methodNotAllowed, "POST のみ") }
            let req = try? JSONDecoder().decode(JSONValue.self, from: body)
            if let id = req?["playbackId"]?.stringValue {
                if let s = sessions.lookup(id) { PreviewStore.shared.cancel(url: s.url) }
                sessions.remove(id)
                Log.info("再生セッション終了 \(id) (ブラウザ)")
            }
            // ダイレクト再生にはセッションが無いので、動画の指定でも止められるようにする。
            // スプライトは再生中しか使わないため、止めたら作るのをやめる。
            if let item = req?["item"]?.stringValue.flatMap(ItemID.init(token:)),
               let url = library.resolve(item) {
                PreviewStore.shared.cancel(url: url)
            }
            return Self.json(.object(["ok": .bool(true)]))

        default:
            return Self.error(.notFound, "不明なエンドポイント")
        }
    }

    // MARK: 認証

    private func authenticate(body: Data) -> Reply {
        guard BrowserAuth.isEnabled(config) else {
            // そもそも要求していない。
            return Self.json(.object(["ok": .bool(true)]))
        }
        guard let req = try? JSONDecoder().decode(JSONValue.self, from: body),
              let pin = req["pin"]?.stringValue,
              let token = BrowserAuth.shared.authenticate(pin: pin, config: config)
        else {
            return Self.error(.unauthorized, "PIN が違います")
        }
        var reply = Self.json(.object(["ok": .bool(true)]))
        reply.setCookie = BrowserAuth.setCookieValue(token)
        return reply
    }

    // MARK: サムネイル

    /// 動画の大きさと更新日。一覧を作ったときの控えがあればそれを使う。
    ///
    /// サムネイルもスプライトも 1 画面で何十件と要求が来る。そのたびに
    /// NAS を stat すると、NAS が変換や生成で混んでいるときは 1 件で
    /// 数百ミリ秒かかり、一覧の表示がそのぶん遅くなる。
    /// 控えが無い (一覧を経ずに直接叩かれた) ときだけ実際に読む。
    private static func fileAttributes(of url: URL) -> (size: Int, modified: Date)? {
        if let cached = DirectoryCache.shared.attributes(forFile: url.path) { return cached }
        guard let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        return (values.fileSize ?? 0, values.contentModificationDate ?? Date())
    }

    private func snapshot(query: [String: String]) -> Reply {
        guard let item = query["item"].flatMap(ItemID.init(token:)),
              let url = library.resolve(item),
              let attrs = Self.fileAttributes(of: url)
        else { return Self.error(.notFound, "まだ用意できていません") }
        let file = (url: url, size: attrs.size, modified: attrs.modified)

        // 保存済みの画像を縮小して返すだけなので、動画は読まない。
        if let jpeg = SnapshotStore.shared.deliveryImage(
            for: file.url, size: file.size, modified: file.modified,
            maxWidth: query["w"].flatMap(Int.init), quality: query["q"].flatMap(Int.init)) {
            return Reply(contentType: "image/jpeg", body: jpeg)
        }
        // 画面に出ているのに無い。これを最優先で作らせる。
        SnapshotStore.shared.request([file], scope: "item:\(url.path)", lane: .foreground)
        return Self.error(.notFound, "まだ用意できていません")
    }

    // MARK: 診断

    /// 動画の形式の詳細と、直接再生できるかの見立て、検査の状態を返す。
    /// 検査は時間がかかるので、状態だけを載せて別に走らせる。
    private func diagnose(query: [String: String]) -> Reply {
        guard let item = query["item"].flatMap(ItemID.init(token:)),
              let url = library.resolve(item),
              let attrs = Self.fileAttributes(of: url)
        else { return Self.error(.notFound, "item not found") }

        var out = Diagnostics.details(url: url, size: attrs.size, modified: attrs.modified)
        out["check"] = DiagnoseStore.shared.state(for: url)
        return Self.json(.object(out))
    }

    /// 壊れていないかの検査を始める。深さは quick (既定) か deep。
    private func startCheck(body: Data) -> Reply {
        guard let req = try? JSONDecoder().decode(JSONValue.self, from: body),
              let item = req["item"]?.stringValue.flatMap(ItemID.init(token:)),
              let url = library.resolve(item)
        else { return Self.error(.badRequest, "item がありません") }

        // 画面を閉じたときは走っている検査を止める。
        if req["cancel"]?.boolValue == true {
            DiagnoseStore.shared.cancel(url: url)
            return Self.json(.object(["state": .string("none")]))
        }

        let depth = Diagnostics.Depth(rawValue: req["depth"]?.stringValue ?? "quick") ?? .quick
        // 尺が分かっていれば渡す。短い動画は先頭と末尾に分けずまるごと見る。
        let duration = Self.fileAttributes(of: url).flatMap {
            MediaInfoCache.shared.lookup(url: url, size: $0.size, modified: $0.modified)
        }?.durationSeconds ?? 0
        DiagnoseStore.shared.start(url: url, depth: depth, duration: duration)
        Log.info("検査を開始 (\(depth.rawValue)) \(url.lastPathComponent)")
        return Self.json(DiagnoseStore.shared.state(for: url))
    }

    // MARK: スクラブ用プレビュー

    /// スプライトシートの割り付け情報。
    ///
    /// まだ生成できていないときもエラーにはせず ready:false で返す。
    /// クライアントにとっては「そのうち出る」状態であって失敗ではないため。
    private func preview(query: [String: String]) -> Reply {
        guard let encoded = query["item"],
              let item = ItemID(token: encoded),
              let url = library.resolve(item),
              let attrs = Self.fileAttributes(of: url)
        else { return Self.json(.object(["ready": .bool(false)])) }
        let size = attrs.size
        let modified = attrs.modified

        let sheet = PreviewStore.shared.sheet(for: url, size: size, modified: modified)
        // 無いか途中までなら、続きを最優先で作らせる (実行中なら何も起きない)。
        // 尺が分からなければ先に調べさせる。
        if sheet == nil || sheet?.isComplete == false, let info = Self.mediaInfo(for: url) {
            PreviewStore.shared.request(url: url, size: size, modified: modified, info: info)
        }
        guard let sheet else { return Self.json(.object(["ready": .bool(false)])) }

        return Self.json(.object([
            "ready": .bool(true),
            "interval": .double(sheet.interval),
            "columns": .int(sheet.columns),
            "rows": .int(sheet.rows),
            "count": .int(sheet.count),
            "tileWidth": .int(sheet.tileWidth),
            "tileHeight": .int(sheet.tileHeight),
            // この倍数番のコマが揃っている。クライアントは一番近いものを出す。
            "stride": .int(sheet.stride ?? 1),
            "complete": .bool(sheet.isComplete),
            // 段階が進むと画像が変わる。取り直しの目印にする。
            "version": .string(sheet.hash),
        ]))
    }

    private func previewSheet(query: [String: String]) -> Reply {
        guard let item = query["item"].flatMap(ItemID.init(token:)),
              let url = library.resolve(item),
              let data = PreviewStore.shared.image(for: url)
        else { return Self.error(.notFound, "まだ用意できていません") }
        return Reply(contentType: "image/jpeg", body: data)
    }

    // MARK: 再生開始

    private func play(body: Data) -> Reply {
        guard let req = try? JSONDecoder().decode(JSONValue.self, from: body),
              let item = req["item"]?.stringValue.flatMap(ItemID.init(token:)),
              let url = library.resolve(item)
        else { return Self.error(.badRequest, "item がありません") }

        // auto (既定) / direct / remux / transcode。auto 以外は動作確認用。
        let mode = req["mode"]?.stringValue ?? "auto"

        // ダイレクト再生。ブラウザがそのまま扱える組み合わせのときだけ選ぶ。
        if mode == "direct" || (mode == "auto" && Self.canPlayDirectly(url: url)) {
            let token = streamTokens.issue(for: item)
            Log.info("ダイレクト再生 \(url.lastPathComponent) (ブラウザ)")
            return Self.json(.object([
                "kind": .string("direct"),
                "url": .string(HTTPHandler.streamPrefix + token),
            ]))
        }

        // それ以外は HLS に変換する。
        // まずは無変換の詰め替えを選ぶ (再エンコードより軽い)。
        //
        // ただし詰め替えは容器を変えるだけなので、映像が 4:2:2 や 10bit の
        // ままではブラウザは描けず、ダイレクトと同じ黒画面になる。
        // 描けない映像のときだけ再エンコードに倒す。
        let v = Self.mediaInfoNow(for: url)?.videoStreams.first
        let plan: VideoPlan
        switch mode {
        case "remux":
            plan = .remux
        case "transcode":
            plan = .transcode(kbps: v.map(Self.reencodeBitrateKbps) ?? 3000)
        default:
            if let v, !Diagnostics.browserCanDecode(v) {
                plan = .transcode(kbps: Self.reencodeBitrateKbps(for: v))
                Log.info("映像を再エンコードして配ります (\(v.codec) \(v.pixelFormat)"
                         + "\(v.profile.isEmpty ? "" : " \(v.profile)")) " + url.lastPathComponent)
            } else {
                plan = .remux
            }
        }
        guard let session = playback.startPlayback(item: item, video: plan)
        else { return Self.error(.notFound, "item not found") }

        return Self.json(.object([
            "kind": .string("hls"),
            "url": .string(Playlist.indexURL(for: session)),
            "playbackId": .string(session.id),
        ]))
    }

    /// ブラウザに無変換で渡してよい組み合わせか。
    ///
    /// 判定を緩めると「再生できない動画を掴まされて無音の黒画面になる」ため、
    /// 確実に再生できる組み合わせだけを通し、迷ったら変換に倒す。
    static func canPlayDirectly(url: URL) -> Bool {
        guard ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased()) else { return false }
        // 断片化した MP4 は iPad の Safari が再生を始めない。詰め替えに回す。
        guard !MP4Layout.isFragmented(url: url) else { return false }
        guard let info = mediaInfoNow(for: url), let v = info.videoStreams.first
        else { return false }

        // 音声無しは問題にならない。ある場合は AAC のみ許す。
        let audioOK = info.audioStreams.isEmpty
            || info.audioStreams.allSatisfy { $0.codec.lowercased().contains("aac") }
        return Diagnostics.browserCanDecode(v) && audioOK
    }

    /// 解析済みのメディア情報。
    ///
    /// 再生を始めるときは結果が要るので、まだ調べていなければその場で調べる。
    /// 一覧と違って 1 件だけなので、ffprobe 1 回で済む。
    static func mediaInfoNow(for url: URL) -> MediaInfo? {
        guard let attrs = fileAttributes(of: url) else { return nil }
        return MediaInfoCache.shared.fetchNow(url: url, size: attrs.size, modified: attrs.modified)
    }

    /// 再エンコードするときの目標ビットレート。
    /// 元の高さに見合った値にする (一律だと 4K が眠くなり、SD が無駄に太る)。
    static func reencodeBitrateKbps(for v: MediaInfo.VideoStream) -> Int {
        switch v.height {
        case 1440...: return 6000
        case 1000..<1440: return 4500
        case 700..<1000: return 3000
        default: return 1800
        }
    }

    /// 解析済みのメディア情報。無ければ背後で取得を始めて nil を返す。
    /// ここで待つと NAS 上の大量ファイルで応答が返らなくなる。
    static func mediaInfo(for url: URL) -> MediaInfo? {
        guard let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        return MediaInfoCache.shared.cachedOrFetch(
            url: url,
            size: values.fileSize ?? 0,
            modified: values.contentModificationDate ?? Date())
    }

    // MARK: 一覧の項目

    /// 一覧の 1 項目をブラウザ向けの形にする。
    ///
    /// 尺と縦横はメディア情報の取得が済むまで null、サムネイルも作るまでは無い。
    /// その間クライアントは一覧を取り直し、揃ったものから表示を更新する。
    static func browserItem(_ e: LibraryEntry) -> JSONValue {
        var out: [String: JSONValue] = [
            "id": .string(e.item.token),
            "name": .string(e.name),
            "kind": .string(e.kind == .folder ? "folder" : "video"),
            "size": .int(e.size),
            "modified": .string(e.modified.ISO8601Format()),
            "hasSnapshot": .bool(false),
            "duration": .null,
        ]
        guard e.kind == .video else { return .object(out) }

        if let info = MediaInfoCache.shared.lookup(url: e.url, size: e.size, modified: e.modified) {
            out["duration"] = .double(info.durationSeconds)
            if let v = info.videoStreams.first {
                out["width"] = .int(v.width)
                out["height"] = .int(v.height)
            }
        }
        out["hasSnapshot"] = .bool(
            SnapshotStore.shared.hash(for: e.url, size: e.size, modified: e.modified) != nil)
        return .object(out)
    }

    // MARK: 応答の下請け

    static func json(_ v: JSONValue, status: HTTPResponseStatus = .ok) -> Reply {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return Reply(status: status, contentType: "application/json",
                     body: (try? enc.encode(v)) ?? Data())
    }

    static func error(_ status: HTTPResponseStatus, _ message: String) -> Reply {
        json(.object(["error": .string(message)]), status: status)
    }
}
