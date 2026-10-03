import Foundation

/// 実装中はクライアントの挙動を追うのが最重要なので、
/// 簡素だが即座に出力されるログを用意する。
///
/// GUI からも直近のログを見たいので、リングバッファに保持し
/// 追加時に購読者へ通知する。
public enum Log {
    private static let lock = NSLock()
    private static var buffer: [String] = []
    private static var observers: [(String) -> Void] = []
    private static let capacity = 500

    /// 標準出力にも出すか (コマンドライン実行時は真)。
    nonisolated(unsafe) public static var echoToStandardOutput = true

    /// ログの書き出し先。常駐アプリでは画面にしか出ないため、
    /// あとから原因を追えるようファイルにも残す。
    public static var fileURL: URL {
        Configuration.supportDirectory.appendingPathComponent("swift-video-server.log")
    }

    private static var handle: FileHandle?

    /// ファイルへ 1 行追記する。肥大したら作り直す。
    private static func appendToFile(_ line: String) {
        let fm = FileManager.default
        let url = fileURL
        if handle == nil {
            try? fm.createDirectory(at: Configuration.supportDirectory,
                                    withIntermediateDirectories: true)
            // O_APPEND で開く。書き込みは常にその時点の末尾へ行くので、
            // 同じログを開いているインスタンスが 2 つあっても行が壊れない。
            // FileHandle(forWritingTo:) は自分のオフセットを持ち続けるため、
            // 2 つ目のインスタンスが 1 つ目の行を上書きして消していた。
            let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            handle = fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
        }
        guard let handle else { return }
        // 5MB を超えたら切り詰める。
        if (try? handle.offset()).map({ $0 > 5_000_000 }) == true {
            try? handle.truncate(atOffset: 0)
        }
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    public static func request(_ message: String) { emit("REQ", message) }
    public static func warn(_ message: String) { emit("WARN", message) }
    public static func info(_ message: String) { emit("INFO", message) }

    /// 画面の控えとファイルの両方を空にする。
    public static func clear() {
        lock.lock()
        buffer.removeAll()
        if let handle {
            // 開いている間に消すと書き込み先を見失うので、切り詰めるだけにする。
            try? handle.truncate(atOffset: 0)
        } else {
            try? FileManager.default.removeItem(at: fileURL)
        }
        lock.unlock()
    }

    /// 直近のログ行を古い順に返す。
    public static func recent() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    /// 新しい行が来るたびに呼ばれる購読を登録する。
    public static func observe(_ handler: @escaping (String) -> Void) {
        lock.lock(); observers.append(handler); lock.unlock()
    }

    private static func emit(_ level: String, _ message: String) {
        let line = "\(timeFormatter.string(from: Date())) [\(level)] \(message)"
        lock.lock()
        buffer.append(line)
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
        let snapshot = observers
        let echo = echoToStandardOutput
        lock.unlock()

        if echo {
            print(line)
            fflush(stdout)
        }
        lock.lock()
        appendToFile(line)
        lock.unlock()
        for o in snapshot { o(line) }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
