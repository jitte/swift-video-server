import Foundation
import VideoServerKit

/// サーバの起動状態と設定を束ねて、GUI から扱いやすくする。
///
/// 設定を変えたら一度止めて作り直す。VideoServer は
/// 生成時の Configuration を保持する設計なので、
/// 設定変更後は新しいインスタンスに差し替える。
@MainActor
final class ServerController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published var lastError: String?
    @Published var config: Configuration

    private var server: VideoServer?

    init() {
        // GUI ではログを画面に出すので標準出力への複写は止める。
        Log.echoToStandardOutput = false
        do {
            config = try Configuration.load(defaultMediaPath: nil)
        } catch {
            // 読めない場合でも起動はできるように最小構成で続ける。
            config = Configuration(
                serverName: Host.current().localizedName ?? "Swift Video Server",
                port: Configuration.defaultPort, shares: []
            )
            lastError = "設定の読み込みに失敗しました: \(error)"
        }
    }

    func start() {
        guard !isRunning else { return }
        let s = VideoServer(config: config)
        do {
            try s.start()
            server = s
            isRunning = true
            lastError = nil
        } catch {
            lastError = "起動に失敗しました: \(error)"
            Log.warn(lastError!)
        }
    }

    func stop() {
        server?.stop()
        server = nil
        isRunning = false
    }

    func restart() {
        stop()
        start()
    }

    /// 設定を保存し、動作中なら反映のため再起動する。
    func applyAndSave() {
        do {
            try config.save()
        } catch {
            lastError = "設定の保存に失敗しました: \(error)"
            return
        }
        if isRunning { restart() }
    }

    func addShare(path: String) {
        let name = URL(fileURLWithPath: path).lastPathComponent
        // 同じパスが既にあれば足さない。
        guard !config.shares.contains(where: { $0.path == path }) else { return }
        config.shares.append(
            Configuration.Share(id: UUID().uuidString.lowercased(), displayName: name, path: path)
        )
        applyAndSave()
    }

    func renameShare(id: String, to name: String) {
        guard let i = config.shares.firstIndex(where: { $0.id == id }) else { return }
        config.shares[i].displayName = name
        // 入力のたびに再起動すると煩いので、保存だけ行う。
        try? config.save()
    }

    func removeShare(id: String) {
        config.shares.removeAll { $0.id == id }
        applyAndSave()
    }

    /// ブラウザで開いてもらうアドレス。
    var listenAddresses: [String] {
        var out: [String] = []
        for ip in Self.localIPv4Addresses() {
            out.append("https://\(ip):\(config.port)/")
        }
        return out
    }

    /// LAN の IPv4 アドレスを集める。
    ///
    /// 実体は VideoServerKit 側にある。証明書の subjectAltName にも
    /// 同じ一覧が要るため、案内するアドレスと証明書に入れるアドレスが
    /// ずれないよう出どころを 1 つにしてある。
    static func localIPv4Addresses() -> [String] {
        NetworkInterfaces.localIPv4Addresses()
    }
}
