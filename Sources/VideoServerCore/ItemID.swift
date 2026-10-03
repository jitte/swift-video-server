import Foundation

/// 共有フォルダの中の 1 項目 (フォルダか動画) を指す。
///
/// 実ファイルのパスではなく「どの共有フォルダの、どの相対パスか」で持つ。
/// 共有フォルダの場所を移しても、共有フォルダの id が同じなら指す先は変わらない。
public struct ItemID: Sendable, Hashable {
    /// 共有フォルダの id (設定ファイルの shares[].id)。
    public var share: String
    /// 共有フォルダからの相対パス。共有フォルダそのものは空文字。
    public var path: String

    public init(share: String, path: String) {
        self.share = share
        self.path = path
    }

    /// 子の項目。
    public func appending(_ name: String) -> ItemID {
        ItemID(share: share, path: path.isEmpty ? name : path + "/" + name)
    }

    /// URL やブラウザとの受け渡しに使う文字列。
    ///
    /// "<共有フォルダ id>/<相対パス>" を base64url にしたもの。
    /// 共有フォルダ id は GUID なので "/" を含まず、最初の "/" で分けられる。
    /// パスをそのまま query に載せると、日本語や記号のエスケープで読みにくくなる。
    public var token: String {
        Data((share + "/" + path).utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(token: String) {
        var b64 = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let text = String(data: data, encoding: .utf8),
              let slash = text.firstIndex(of: "/")
        else { return nil }
        let share = String(text[..<slash])
        guard !share.isEmpty else { return nil }
        self.init(share: share, path: String(text[text.index(after: slash)...]))
    }
}
