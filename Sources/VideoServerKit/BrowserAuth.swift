import Foundation
import CryptoKit

/// ブラウザ版クライアントの PIN 認証。
///
/// 受け渡しに Cookie を使う。`<video>` や `<img>`、HLS のセグメント取得は
/// ブラウザが自前で要求を出すため、fetch のヘッダでは持ち回せない。
///
/// 対象は `/api` と配信 (`/stream`、`/hls`)。配信の URL はもともと推測できない
/// 鍵やセッション id を持つが、URL が漏れても PIN を知らない端末では再生できない。
/// ブラウザ版の画面 (静的ファイル) と `/cert.crt` は対象外。入力画面そのものが
/// 開けなくなるのと、証明書を取り込む前は HTTPS が使えないため。
///
/// トークンはメモリにだけ置く。ディスクに秘密を残さずに済み、
/// サーバを止めれば全員入り直しになる。
final class BrowserAuth: @unchecked Sendable {
    static let shared = BrowserAuth()

    static let cookieName = "svs_session"
    /// 発行したトークンの寿命。毎回入力させるのは煩わしいので長めに取る。
    static let lifetime: TimeInterval = 60 * 60 * 24 * 30

    private struct Entry {
        var expires: Date
        /// 発行時の PIN の指紋。PIN を変えたら既存のセッションを無効にするため。
        var pinFingerprint: String
    }

    private let lock = NSLock()
    private var tokens: [String: Entry] = [:]

    /// 連続して間違えたときの足止め。
    private var failures = 0
    private var lockedUntil: Date?
    private static let maxFailures = 10
    private static let lockoutSeconds: TimeInterval = 60

    private init() {}

    // MARK: 判定

    /// この設定で認証が要るか。
    static func isEnabled(_ config: Configuration) -> Bool {
        guard let pin = config.browserPIN else { return false }
        return !pin.isEmpty
    }

    /// Cookie のトークンが今の設定で有効か。
    func isValid(token: String?, config: Configuration) -> Bool {
        guard Self.isEnabled(config), let pin = config.browserPIN else {
            // PIN 無しなら誰でも通す。
            return true
        }
        guard let token, !token.isEmpty else { return false }

        lock.lock(); defer { lock.unlock() }
        guard let entry = tokens[token] else { return false }
        if entry.expires < Date() {
            tokens.removeValue(forKey: token)
            return false
        }
        // PIN が変わっていたら、発行済みのものも通さない。
        return entry.pinFingerprint == Self.fingerprint(pin)
    }

    /// PIN を検証し、合っていればトークンを発行する。
    /// 合っていなければ nil。連続失敗中は常に nil。
    func authenticate(pin: String, config: Configuration) -> String? {
        guard let expected = config.browserPIN, !expected.isEmpty else { return nil }

        lock.lock()
        if let until = lockedUntil {
            if until > Date() {
                lock.unlock()
                Log.warn("PIN の入力が連続して失敗しているため受け付けません")
                return nil
            }
            lockedUntil = nil
            failures = 0
        }
        lock.unlock()

        guard Self.constantTimeEquals(pin, expected) else {
            lock.lock()
            failures += 1
            if failures >= Self.maxFailures {
                lockedUntil = Date().addingTimeInterval(Self.lockoutSeconds)
                Log.warn("PIN の入力を \(failures) 回間違えたため "
                         + "\(Int(Self.lockoutSeconds)) 秒受け付けません")
            }
            lock.unlock()
            return nil
        }

        let token = Self.newToken()
        lock.lock()
        failures = 0
        lockedUntil = nil
        // 期限切れをここで掃除する。数が少ないので全走査でよい。
        let now = Date()
        tokens = tokens.filter { $0.value.expires > now }
        tokens[token] = Entry(expires: now.addingTimeInterval(Self.lifetime),
                              pinFingerprint: Self.fingerprint(expected))
        lock.unlock()
        Log.info("ブラウザ版クライアントの認証に成功しました")
        return token
    }

    /// 発行済みをすべて無効にする。
    func revokeAll() {
        lock.lock(); tokens.removeAll(); lock.unlock()
    }

    // MARK: 下請け

    /// Cookie ヘッダから自分のトークンを取り出す。
    static func token(fromCookieHeader header: String?) -> String? {
        guard let header else { return nil }
        for pair in header.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces)
            if key == cookieName {
                return kv[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// 応答に載せる Set-Cookie の値。
    ///
    /// Secure を付け、HTTPS の通信にしか載らないようにする
    /// (平文 HTTP は /cert.crt 以外を HTTPS へ転送している)。
    static func setCookieValue(_ token: String) -> String {
        "\(cookieName)=\(token); Path=/; Max-Age=\(Int(lifetime)); HttpOnly; Secure; SameSite=Lax"
    }

    static func clearCookieValue() -> String {
        "\(cookieName)=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax"
    }

    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// PIN そのものは保存せず、変化の検出にだけ使う。
    static func fingerprint(_ pin: String) -> String {
        SHA256.hash(data: Data(pin.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 長さと内容の比較にかかる時間を入力に依存させない。
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        let n = max(x.count, y.count)
        for i in 0..<n {
            let xi = i < x.count ? x[i] : 0
            let yi = i < y.count ? y[i] : 0
            diff |= xi ^ yi
        }
        return diff == 0
    }
}
