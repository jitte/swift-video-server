import Foundation

/// この機械が LAN 上で名乗れる宛先を集める。
///
/// 接続先の案内 (メニューバーの表示) と、サーバ証明書の
/// subjectAltName の両方で必要になる。ブラウザは証明書に
/// 書かれていない宛先での接続を拒むため、案内する宛先と
/// 証明書に入れる宛先は必ず同じ材料から作る。
public enum NetworkInterfaces {
    /// LAN の IPv4 アドレスを集める。
    public static func localIPv4Addresses() -> [String] {
        var results: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            guard let addr = cur.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            // ループバックと仮想インタフェースは除く。
            guard name != "lo0", !name.hasPrefix("utun"), !name.hasPrefix("bridge") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.isEmpty, ip != "127.0.0.1" { results.append(ip) }
            }
        }
        return results
    }

    /// この機械の名前。Bonjour 名 (.local) も併せて返す。
    ///
    /// IP は将来変わりうるので、証明書には名前も入れておくと
    /// 作り直しを避けられることがある。
    public static func localHostNames() -> [String] {
        var names: [String] = []
        if let host = Host.current().localizedName, !host.isEmpty {
            // 空白を含む機械名 (例: "MacBook Pro") は DNS 名にならないので詰める。
            let sanitized = host.replacingOccurrences(of: " ", with: "-")
            names.append(sanitized)
            names.append("\(sanitized).local")
        }
        for name in Host.current().names where !name.isEmpty {
            names.append(name)
        }
        names.append("localhost")
        // 重複を除きつつ順序は保つ。
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }
    }
}
