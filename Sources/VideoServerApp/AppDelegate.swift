import AppKit
import Combine
import SwiftUI
import VideoServerKit

/// メニューバー常駐アプリ本体。
/// Dock にはアイコンを出さず、メニューバーだけに常駐する
/// (Info.plist の LSUIElement で指定)。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let controller = ServerController()
    private var preferencesWindow: NSWindow?
    private var statusWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement なのでメニューバーに File が出ないが、
        // ⌘W は mainMenu の Close に結ばないと効かない。
        installKeyMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "play.rectangle.on.rectangle",
                                   accessibilityDescription: "Swift Video Server")
            button.image?.isTemplate = true
        }
        statusItem.menu = buildMenu()

        // メニュー以外 (サーバ状態の窓など) から開始・停止しても追従させる。
        // @Published は変更の直前に流れるので、controller ではなく流れてきた値を使う。
        controller.$isRunning
            .combineLatest(controller.$config.map(\.port).removeDuplicates())
            .sink { [weak self] running, port in self?.updateStatusIcon(running: running, port: port) }
            .store(in: &cancellables)

        // 起動と同時に待受を開始する。
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let about = NSMenuItem(title: "Swift Video Server について", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let prefs = NSMenuItem(title: "設定...", action: #selector(showPreferences), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        let status = NSMenuItem(title: "サーバ状態", action: #selector(showStatus), keyEquivalent: "")
        status.target = self
        menu.addItem(status)

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "サーバを停止", action: #selector(toggleServer), keyEquivalent: "")
        toggle.target = self
        toggle.tag = 100
        menu.addItem(toggle)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    // MARK: 表示の更新

    private func updateStatusIcon(running: Bool, port: Int) {
        guard let button = statusItem.button else { return }
        // 動作中かどうかが一目で分かるようにする。
        button.appearsDisabled = !running
        button.toolTip = running
            ? "Swift Video Server 動作中 (ポート \(port))"
            : "Swift Video Server 停止中"
    }

    // MARK: メニュー操作

    @objc private func toggleServer() {
        controller.isRunning ? controller.stop() : controller.start()
    }

    /// 窓は使い回すが、閉じた状態から開くときは中身を作り直す。
    /// 使い回した窓では onAppear が再び走らず、キャッシュの使用量などが
    /// 最初に開いたときの値のまま残るため。
    @objc private func showPreferences() {
        let view = AnyView(PreferencesView(controller: controller))
        if let window = preferencesWindow {
            if !window.isVisible {
                window.contentViewController = NSHostingController(rootView: view)
            }
        } else {
            preferencesWindow = makeWindow(title: "Swift Video Server 設定", content: view)
        }
        present(preferencesWindow)
    }

    @objc private func showStatus() {
        if statusWindow == nil {
            statusWindow = makeWindow(title: "Swift Video Server サーバ状態",
                                      content: AnyView(StatusView(controller: controller)))
        }
        present(statusWindow)
    }

    @objc private func showAbout() {
        let view = AnyView(AboutView(addresses: controller.listenAddresses))
        if let window = aboutWindow {
            window.contentViewController = NSHostingController(rootView: view)
            present(window)
        } else {
            aboutWindow = makeWindow(title: "Swift Video Server について", content: view)
            present(aboutWindow)
        }
    }

    @objc private func quit() {
        controller.stop()
        NSApp.terminate(nil)
    }

    // MARK: ウィンドウ

    /// ⌘W と編集系のキー割り当て用。画面には出さない。
    ///
    /// AppKit はキー割り当てもメニュー由来なので、File / Edit を置かないと
    /// ⌘W や入力欄の ⌘C / ⌘V などが効かない。
    /// 先頭の submenu はアプリケーションメニュー扱いになるため、
    /// ダミーを 1 つ置いてから File / Edit を続ける。
    private func installKeyMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        appItem.submenu = NSMenu(title: "Swift Video Server")

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "閉じる",
                     action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "w")
        fileItem.submenu = file

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "取り消す", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "やり直す", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        NSApp.mainMenu = main
    }

    private func makeWindow(title: String, content: AnyView) -> NSWindow {
        let hosting = NSHostingController(rootView: content)
        let window = UtilityWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        // 常駐アプリは前面に出ないので、明示的に活性化する。
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Esc で閉じられるユーティリティ窓。
/// テキスト編集中は先に編集キャンセルが食うので、そのときはもう一度押す。
final class UtilityWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

/// 「Swift Video Server について」。アラートだと Esc / ⌘W が効きにくいので窓にする。
struct AboutView: View {
    let addresses: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Swift Video Server").font(.title2.weight(.semibold))
            Text("ブラウザで観る動画サーバ。")
                .foregroundStyle(.secondary)
            Divider()
            BuildInfoView(info: BuildInfo.current)
            Divider()
            Text("ブラウザで開くアドレス")
                .font(.subheadline)
            if addresses.isEmpty {
                Text("ネットワークに接続していないため、アドレスを表示できません。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(addresses, id: \.self) { addr in
                    Text(addr)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
    }
}

/// 動いているものがどれかを見分けるための情報。
///
/// build-app.sh が CFBundleVersion に「コミット-作り方」を埋める
/// (例: 2d5f266-release、未コミットの変更があれば 2d5f266+-debug)。
/// .app に固めずに動かした場合は Info.plist が無いので不明になる。
struct BuildInfo {
    let path: String
    let version: String?
    let commit: String?
    let mode: String?

    static var current: BuildInfo {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        var commit: String?
        var mode: String?
        if let raw = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           let dash = raw.lastIndex(of: "-") {
            commit = String(raw[..<dash])
            mode = String(raw[raw.index(after: dash)...])
        }
        return BuildInfo(path: bundle.bundlePath, version: version, commit: commit, mode: mode)
    }

    /// 作り方ごとの違い。build-app.sh の説明と合わせる。
    var modeDescription: String? {
        switch mode {
        case "release": return "配布・常用向け。最適化あり"
        case "fast": return "開発向け。最適化ありでファイル単位にコンパイル"
        case "debug": return "開発向け。最適化なし (少し遅い)"
        default: return nil
        }
    }
}

struct BuildInfoView: View {
    let info: BuildInfo

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                label("バージョン")
                Text(info.version ?? "不明")
            }
            GridRow {
                label("コミット")
                Text(commitText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            GridRow {
                label("ビルド")
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.mode ?? "不明")
                        .font(.system(.body, design: .monospaced))
                    if let desc = info.modeDescription {
                        Text(desc).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            GridRow {
                label("場所")
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.path)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Finder で表示") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: info.path)])
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var commitText: String {
        guard let commit = info.commit else { return "不明" }
        // 「+」は未コミットの変更を含んだまま作ったことを表す。
        return commit.hasSuffix("+") ? "\(commit) (未コミットの変更あり)" : commit
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // 開くたびに現在の状態に合わせる。
        if let item = menu.item(withTag: 100) {
            item.title = controller.isRunning ? "サーバを停止" : "サーバを開始"
        }
    }
}
