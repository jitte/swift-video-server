import Foundation

/// 背景処理 (動画情報・サムネイル・スプライト) の待ち行列。
///
/// 方針:
/// - 新しく来た仕事は先頭に入れる。まとめて来た仕事は順序を保って先頭に入れる
///   (フォルダを開いたら画面の上から処理される)。
/// - 待っている仕事がもう一度要求されたら先頭へ繰り上げる。
/// - 今見ているもの (前景) は、背景の仕事の後ろに並ばせない。
///   前景の枠が背景の仕事に貸し出されていたら、それを取り消して譲らせる。
/// - 子プロセスは優先度を付けて起動し、取り消されたら止める。
///
/// 1GB を超える動画も普通にあるため、1 件が数十秒かかる前提で作る。
final class WorkQueue: @unchecked Sendable {
    static let shared = WorkQueue()

    enum Lane { case foreground, background }

    final class Job: @unchecked Sendable {
        let key: String
        /// 同じ種類の「今見ているもの」を判定するための括り (例: "folder:/path")。
        let scope: String
        fileprivate(set) var lane: Lane
        fileprivate let work: (Job) -> Void
        private let lock = NSLock()
        private var cancelled = false
        /// 1 つの仕事が並列に子プロセスを走らせることがある (スプライトのコマ取り)。
        private var processes: [ObjectIdentifier: Process] = [:]

        fileprivate init(key: String, scope: String, lane: Lane, work: @escaping (Job) -> Void) {
            self.key = key; self.scope = scope; self.lane = lane; self.work = work
        }

        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

        /// 直近に走らせた子プロセスの終了コードと標準エラー。
        /// 失敗したときに「何がいけなかったか」を残すために持つ。
        private var lastStatusValue: Int32 = 0
        private var lastErrorValue = ""
        var lastStatus: Int32 { lock.lock(); defer { lock.unlock() }; return lastStatusValue }
        var lastErrorText: String { lock.lock(); defer { lock.unlock() }; return lastErrorValue }

        fileprivate func cancel() {
            lock.lock()
            cancelled = true
            let running = Array(processes.values)
            lock.unlock()
            for p in running where p.isRunning { p.terminate() }
        }

        /// 子プロセスを実行して標準出力を返す。取り消されたら止めて nil。
        func run(_ executable: URL, _ arguments: [String]) -> Data? {
            let p = Process()
            p.executableURL = executable
            p.arguments = arguments
            // 前景は利用者の操作に応えるもの、背景は後回しでよいもの。
            p.qualityOfService = (lane == .foreground) ? .userInitiated : .utility
            let pipe = Pipe()
            let errPipe = Pipe()
            p.standardOutput = pipe
            // 標準エラーは捨てずに取っておく。失敗の理由はここにしか出ない。
            p.standardError = errPipe
            p.standardInput = FileHandle.nullDevice

            let id = ObjectIdentifier(p)
            lock.lock()
            if cancelled { lock.unlock(); return nil }
            processes[id] = p
            lock.unlock()

            do { try p.run() } catch {
                lock.lock(); processes[id] = nil; lock.unlock()
                return nil
            }
            // 登録してから起動するまでの間に取り消されると、取り消し側の
            // terminate は「まだ動いていない」ので空振りし、この後で起動した
            // プロセスが生き残る。起動直後にもう一度確かめて止める。
            if isCancelled, p.isRunning { p.terminate() }
            // 読み切ってから終了を待つ (逆だとパイプが詰まる)。
            // 標準出力と標準エラーは並行して読む。片方を待っている間に
            // もう片方が埋まると、子プロセスが書き込みで止まる。
            var errData = Data()
            let reader = DispatchQueue(label: "swift-video-server.job.stderr")
            let done = DispatchSemaphore(value: 0)
            reader.async {
                errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                done.signal()
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.wait()
            p.waitUntilExit()

            lock.lock()
            processes[id] = nil
            lastStatusValue = p.terminationStatus
            lastErrorValue = String(decoding: errData, as: UTF8.self)
            lock.unlock()
            guard !isCancelled, p.terminationStatus == 0 else { return nil }
            return data
        }
    }

    /// 前景の同時実行数。NAS の I/O 待ちが主なので少し並べる。
    private let foregroundSlots = 3
    /// 背景だけに割り当てる枠。前景が空いていれば前景の枠も借りる。
    private let backgroundSlots = 1

    private let lock = NSLock()
    private var foreground: [Job] = []
    private var background: [Job] = []
    /// 実行中。借りた枠かどうかも持つ。
    private var running: [(job: Job, borrowed: Bool)] = []

    // MARK: 投入

    /// 1 件入れる。
    func submit(key: String, scope: String, lane: Lane, work: @escaping (Job) -> Void) {
        submit([(key, work)], scope: scope, lane: lane)
    }

    /// まとめて先頭に入れる。順序は保つ。
    func submit(_ items: [(key: String, work: (Job) -> Void)], scope: String, lane: Lane) {
        guard !items.isEmpty else { return }
        lock.lock()
        let runningKeys = Set(running.map { $0.job.key })
        var fresh: [Job] = []
        for item in items where !runningKeys.contains(item.key) {
            // 待っていれば取り出して繰り上げる。
            removePending(key: item.key)
            fresh.append(Job(key: item.key, scope: scope, lane: lane, work: item.work))
        }
        if lane == .foreground {
            foreground.insert(contentsOf: fresh, at: 0)
        } else {
            background.insert(contentsOf: fresh, at: 0)
        }
        lock.unlock()
        pump()
    }

    /// 今見ているものを切り替える。
    ///
    /// 同じ種類 (scope の接頭辞) で別の対象の前景の仕事は、
    /// 捨てずに背景の先頭へ回す (方針 B: 事前生成は続ける)。
    func focus(kind: String, scope: String) {
        lock.lock()
        let demoted = foreground.filter { $0.scope.hasPrefix(kind) && $0.scope != scope }
        guard !demoted.isEmpty else { lock.unlock(); return }
        foreground.removeAll { $0.scope.hasPrefix(kind) && $0.scope != scope }
        for j in demoted { j.lane = .background }
        background.insert(contentsOf: demoted, at: 0)
        lock.unlock()
    }

    /// 取り消す。待っていれば外し、実行中なら子プロセスを止める。
    func cancel(where match: (Job) -> Bool) {
        lock.lock()
        foreground.removeAll(where: match)
        background.removeAll(where: match)
        let targets = running.map { $0.job }.filter(match)
        lock.unlock()
        for j in targets { j.cancel() }
    }

    // MARK: 実行

    private func removePending(key: String) {
        foreground.removeAll { $0.key == key }
        background.removeAll { $0.key == key }
    }

    private func pump() {
        var toStart: [(Job, Bool)] = []
        var toPreempt: [Job] = []

        lock.lock()
        while true {
            let fgBusy = running.filter { $0.job.lane == .foreground || $0.borrowed }.count
            let bgBusy = running.filter { $0.job.lane == .background && !$0.borrowed }.count

            if !foreground.isEmpty {
                if fgBusy < foregroundSlots {
                    let j = foreground.removeFirst()
                    running.append((j, false)); toStart.append((j, false))
                    continue
                }
                // 前景の枠を背景に貸していたら返してもらう。
                if let i = running.firstIndex(where: { $0.borrowed }) {
                    let victim = running.remove(at: i).job
                    toPreempt.append(victim)
                    // 取り消した仕事は作り直しになるが、背景の先頭に戻して続ける。
                    background.insert(Job(key: victim.key, scope: victim.scope,
                                          lane: .background, work: victim.work), at: 0)
                    continue
                }
            }
            if !background.isEmpty {
                if bgBusy < backgroundSlots {
                    let j = background.removeFirst()
                    running.append((j, false)); toStart.append((j, false))
                    continue
                }
                if foreground.isEmpty, fgBusy < foregroundSlots {
                    let j = background.removeFirst()
                    running.append((j, true)); toStart.append((j, true))
                    continue
                }
            }
            break
        }
        lock.unlock()

        for v in toPreempt { v.cancel() }
        for (job, _) in toStart {
            let qos: DispatchQoS.QoSClass = job.lane == .foreground ? .userInitiated : .utility
            DispatchQueue.global(qos: qos).async { [weak self] in
                if !job.isCancelled { job.work(job) }
                self?.finish(job)
            }
        }
    }

    private func finish(_ job: Job) {
        lock.lock()
        running.removeAll { $0.job === job }
        lock.unlock()
        pump()
    }
}
