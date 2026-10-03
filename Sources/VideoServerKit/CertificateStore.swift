import Foundation
import NIOSSL

/// TLS 証明書の生成と保管。
///
/// ローカル CA を 1 つ作り、それでサーバ証明書に署名する 2 段構成にする。
/// 自己署名の 1 枚を「信頼させるルート」と「サーバが提示する証明書」に
/// 兼用させると、用途 (basicConstraints / keyUsage) が噛み合わず
/// ブラウザに拒まれやすい。分けておけば、CA を一度端末に入れたあとは
/// サーバ証明書を作り直しても入れ直さずに済む。
///
public enum CertificateStore {
    static var caCertURL: URL { Configuration.supportDirectory.appendingPathComponent("ca.pem") }
    static var caKeyURL: URL { Configuration.supportDirectory.appendingPathComponent("ca-key.pem") }
    /// 署名に使う通し番号の控え。
    /// 置き場所を明示しないと openssl が独自の規則で決め、
    /// プロセスの作業ディレクトリに置かれることがある。
    static var caSerialURL: URL { Configuration.supportDirectory.appendingPathComponent("ca.srl") }
    static var certURL: URL { Configuration.supportDirectory.appendingPathComponent("cert.pem") }
    static var keyURL: URL { Configuration.supportDirectory.appendingPathComponent("key.pem") }

    /// サーバ証明書の有効期間 (日)。
    ///
    /// Apple の信頼評価は長すぎるサーバ証明書を拒む。10 年で作ったものが
    /// CSSMERR_TP_CERT_SUSPENDED で弾かれることを security verify-cert で
    /// 確認した (825 日は通ったが、iOS は 398 日で運用されているため
    /// その内側に収める)。手動で信頼させたルート配下でも適用される。
    static let serverCertificateDays = 397

    /// 残りがこれを切ったら作り直す (日)。
    static let renewBeforeDays = 30

    /// 無ければ作り、あれば読み込む。
    ///
    /// 返す鎖はサーバ証明書と CA の順。CA を一緒に送っておくと、
    /// 端末に CA が入っていれば経路をたどれる。
    public static func loadOrCreate() throws -> (chain: [NIOSSLCertificateSource],
                                                 key: NIOSSLPrivateKeySource) {
        let fm = FileManager.default
        try fm.createDirectory(at: Configuration.supportDirectory, withIntermediateDirectories: true)

        // 旧方式 (CA 無しの自己署名 1 枚) からの移行もここで拾う。
        // ca.pem が無ければ作り直す。
        // CA とサーバ証明書は別々に判断する。サーバ証明書だけを作り直したい
        // ときに CA まで変えてしまうと、端末への取り込みからやり直しになる。
        let caMissing = [caCertURL, caKeyURL].contains { !fm.fileExists(atPath: $0.path) }
        let leafMissing = [certURL, keyURL].contains { !fm.fileExists(atPath: $0.path) }

        if caMissing {
            try generateCA()
        }
        if caMissing || leafMissing {
            try generateServerCertificate()
        } else if serverCertificateExpiringSoon() {
            // 期限は 1 年強しか取れないので、切れる前に作り直す。
            // CA は変えないため端末への取り込みはやり直さずに済む。
            Log.info("サーバ証明書の期限が近いため作り直します")
            try generateServerCertificate()
        }

        // fromPEMFile は PEM に入っている証明書をすべて返す。
        // ここはどちらも 1 枚だけのファイルなので先頭を取る。
        // (init(file:format:) は非推奨。秘密鍵側にその印は無いのでそのまま使う)
        guard let leaf = try NIOSSLCertificate.fromPEMFile(certURL.path).first,
              let ca = try NIOSSLCertificate.fromPEMFile(caCertURL.path).first
        else {
            throw ServerError.message("証明書を読み込めませんでした")
        }
        let key = try NIOSSLPrivateKey(file: keyURL.path, format: .pem)
        return ([.certificate(leaf), .certificate(ca)], .privateKey(key))
    }

    /// 端末に取り込ませるための CA 証明書 (PEM)。
    public static func caCertificatePEM() -> Data? {
        try? Data(contentsOf: caCertURL)
    }

    /// 証明書を作り直す。
    ///
    /// IP アドレスが変わって subjectAltName と合わなくなったときに使う。
    /// CA は変えないので端末への取り込みは不要。
    public static func regenerateServerCertificate() throws {
        try generateServerCertificate()
    }

    // MARK: 生成

    static func generate() throws {
        try generateCA()
        try generateServerCertificate()
    }

    /// ローカル CA。これを端末に「信頼するルート」として取り込ませる。
    /// 作り直すと端末への取り込みからやり直しになるため、長めに取る。
    static func generateCA() throws {
        try run([
            "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", caKeyURL.path,
            "-out", caCertURL.path,
            "-days", "3650",
            "-nodes", "-sha256",
            "-subj", "/C=JP/O=Swift Video Server/CN=Swift Video Server Local CA",
            "-addext", "basicConstraints=critical,CA:TRUE",
            "-addext", "keyUsage=critical,keyCertSign,cRLSign",
            // 鍵識別子。端末は取り込み済みのルートをこれで突き合わせる。
            // openssl は自動では付けないが、無いと iOS が連鎖をたどれず
            // 「信頼されていません」になる。
            "-addext", "subjectKeyIdentifier=hash",
        ])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: caKeyURL.path)
        Log.info("ローカル CA を作成しました: \(caCertURL.path)")
    }

    /// サーバ証明書。CA で署名し、宛先を subjectAltName に並べる。
    ///
    /// ブラウザは証明書に書かれていない宛先での接続を拒むため、
    /// 案内しうる宛先 (LAN の IP、機械名、.local、localhost) を
    /// すべて入れておく。
    static func generateServerCertificate() throws {
        let ips = ["127.0.0.1"] + NetworkInterfaces.localIPv4Addresses()
        let names = NetworkInterfaces.localHostNames()

        var sanParts = ips.map { "IP:\($0)" }
        sanParts += names.map { "DNS:\($0)" }
        let san = sanParts.joined(separator: ",")

        let primary = NetworkInterfaces.localIPv4Addresses().first ?? "localhost"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-video-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let csr = tmp.appendingPathComponent("csr.pem")
        let ext = tmp.appendingPathComponent("ext.cnf")

        // x509 -req には -addext が無いので拡張はファイルで渡す。
        // authorityKeyIdentifier は署名した CA の鍵を指す。
        // これが無いと、端末は取り込み済みのルートと結び付けられない。
        try """
        basicConstraints=critical,CA:FALSE
        keyUsage=critical,digitalSignature,keyEncipherment
        extendedKeyUsage=serverAuth
        subjectKeyIdentifier=hash
        authorityKeyIdentifier=keyid,issuer
        subjectAltName=\(san)
        """.write(to: ext, atomically: true, encoding: .utf8)

        try run([
            "req", "-new", "-newkey", "rsa:2048", "-nodes", "-sha256",
            "-keyout", keyURL.path,
            "-out", csr.path,
            "-subj", "/C=JP/O=Swift Video Server/CN=\(primary)",
        ])

        try run([
            "x509", "-req", "-sha256",
            "-in", csr.path,
            "-CA", caCertURL.path,
            "-CAkey", caKeyURL.path,
            // 置き場所を明示する。省くと起動した場所に .srl が落ちる。
            "-CAserial", caSerialURL.path,
            "-CAcreateserial",
            "-out", certURL.path,
            "-days", "\(serverCertificateDays)",
            "-extfile", ext.path,
        ])

        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: keyURL.path)
        Log.info("サーバ証明書を作成しました (宛先: \(sanParts.joined(separator: ", ")))")
    }

    // MARK: openssl

    static func locateOpenSSL() -> URL? {
        ["/usr/bin/openssl", "/opt/homebrew/bin/openssl", "/usr/local/bin/openssl"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// サーバ証明書の期限が近いか。
    ///
    /// openssl x509 -checkend は、指定した秒数以内に切れるとき
    /// 終了コード 1 を返す。判定できないときは作り直さない
    /// (openssl が無い環境で毎回失敗し続けるのを避けるため)。
    static func serverCertificateExpiringSoon() -> Bool {
        let seconds = renewBeforeDays * 24 * 3600
        return runStatus(["x509", "-in", certURL.path, "-noout", "-checkend", "\(seconds)"]) == 1
    }

    /// 終了コードだけを見たいとき用。失敗しても投げない。
    static func runStatus(_ arguments: [String]) -> Int32 {
        guard let openssl = locateOpenSSL() else { return -1 }
        let p = Process()
        p.executableURL = openssl
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func run(_ arguments: [String]) throws {
        guard let openssl = locateOpenSSL() else {
            throw ServerError.message("openssl が見つからないため証明書を生成できません")
        }
        let p = Process()
        p.executableURL = openssl
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        p.standardError = errPipe
        try p.run()
        // 先に読み切らないと、出力が多いときに詰まる。
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let text = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ServerError.message(
                "証明書の生成に失敗しました (openssl \(arguments.first ?? "") "
                + "終了コード \(p.terminationStatus)): \(text)")
        }
    }
}

public enum ServerError: Error, CustomStringConvertible {
    case message(String)
    public var description: String {
        switch self { case .message(let m): return m }
    }
}
