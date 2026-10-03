import Foundation

/// HLS 変換の共通設定。変換そのものは TranscodeJob が行う。
public enum Transcoder {
    /// セグメント長 (秒)。
    ///
    /// 無変換の詰め替えでは元の高いビットレートがそのまま出るため、
    /// 長いと 1 本が数 MB になり、シーク後の再開が遅い
    /// (プレイヤーは再開前に数本まとめて取得する)。
    /// 短くすると 1 本あたりの転送量が減り、再開が早くなる。
    /// 短すぎるとプレイリストが長くなり要求の回数も増えるので 3 秒にしている。
    public static let segmentLength = 3.0

    static func locateFFmpeg() -> URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}
