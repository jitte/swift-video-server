import SwiftUI
import AppKit
import ServiceManagement
import VideoServerKit

/// 設定画面。
///
/// 動かない項目を並べると誤解を招くので、実装済みの設定だけを出す。
struct PreferencesView: View {
    @ObservedObject var controller: ServerController

    @State private var portText: String = ""
    @State private var useCustomPort: Bool = false
    @State private var selection: String?
    @State private var startAtLogin: Bool = false
    @State private var pinText: String = ""
    @State private var usePIN: Bool = false
    @State private var usage: [Maintenance.Entry] = []

    private static let defaultPort = Configuration.defaultPort

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                sharedFolders
                otherOptions
                storage
                if let error = controller.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(20)
        }
        .frame(width: 620, height: 560)
        .onAppear { load() }
    }

    // MARK: 共有フォルダ

    private var sharedFolders: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("共有フォルダ").font(.headline)
            shareTable
            shareButtons
        }
    }

    /// Table の式は型推論が重くなりやすいので、
    /// 選択の Binding を別に切り出して分割してある。
    private var selectionBinding: Binding<Set<String>> {
        Binding(
            get: { selection.map { Set([$0]) } ?? Set<String>() },
            set: { newValue in selection = newValue.first }
        )
    }

    private var shareTable: some View {
        Table(controller.config.shares, selection: selectionBinding) {
            TableColumn("表示名") { (share: Configuration.Share) in
                ShareNameField(controller: controller, share: share)
            }
            .width(min: 120, ideal: 160)
            TableColumn("パス") { (share: Configuration.Share) in
                Text(share.path).foregroundStyle(.secondary)
            }
        }
        .frame(height: 160)
    }

    private var shareButtons: some View {
        HStack(spacing: 6) {
            Button { chooseFolder() } label: { Image(systemName: "plus") }
            Button {
                if let id = selection { controller.removeShare(id: id) }
                selection = nil
            } label: { Image(systemName: "minus") }
            .disabled(selection == nil)
            Spacer()
            Text("表示名が同じフォルダはクライアント側で1つにまとまります。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: その他

    private var otherOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("その他").font(.headline)

            Toggle("ログイン時に起動", isOn: Binding(
                get: { startAtLogin },
                set: { setStartAtLogin($0) }
            ))

            HStack {
                Toggle("カスタムポートを使う", isOn: Binding(
                    get: { useCustomPort },
                    set: { on in
                        useCustomPort = on
                        if !on {
                            portText = String(Self.defaultPort)
                            applyPort()
                        }
                    }
                ))
                TextField("", text: $portText)
                    .frame(width: 80)
                    .disabled(!useCustomPort)
                    .onSubmit { applyPort() }
                Button("適用") { applyPort() }
                    .disabled(!useCustomPort)
                Spacer()
            }

            Text("既定は \(Self.defaultPort)。変更すると、ブラウザで開くアドレスも変わります。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Toggle("ブラウザ版に PIN を要求する", isOn: Binding(
                    get: { usePIN },
                    set: { on in
                        usePIN = on
                        if !on {
                            pinText = ""
                            applyPIN()
                        }
                    }
                ))
                TextField("4〜8 桁", text: $pinText)
                    .frame(width: 90)
                    .disabled(!usePIN)
                    .onSubmit { applyPIN() }
                Button("適用") { applyPIN() }
                    .disabled(!usePIN)
                Spacer()
            }

            Text("ブラウザで開いたときに入力を求めます。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("設定フォルダを開く") {
                    NSWorkspace.shared.open(Configuration.supportDirectory)
                }
                Spacer()
            }
        }
    }

    // MARK: ログとキャッシュ

    /// 消しても作り直せるものだけを並べる。
    /// 設定と証明書は消すとクライアントの登録がやり直しになるので出さない。
    private var storage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ログとキャッシュ").font(.headline)
                Spacer()
                Button("再計算") { refreshUsage() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }

            ForEach(usage) { entry in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title)
                        Text(entry.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Self.formatBytes(entry.bytes))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .trailing)
                    Button("削除") {
                        Maintenance.clear(entry.kind)
                        refreshUsage()
                    }
                    .disabled(entry.bytes == 0)
                }
            }

            Divider()

            HStack {
                Text("合計").font(.callout)
                Spacer()
                Text(Self.formatBytes(usage.reduce(0) { $0 + $1.bytes }))
                    .monospacedDigit()
                    .frame(width: 90, alignment: .trailing)
                Button("すべて削除") {
                    Maintenance.clearAll()
                    refreshUsage()
                }
                .disabled(usage.allSatisfy { $0.bytes == 0 })
            }

            Text("設定と証明書は削除しません。消すとクライアント側の登録が"
                 + "やり直しになるためです。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshUsage() {
        usage = Maintenance.usage()
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes == 0 { return "—" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    // MARK: 操作

    private func load() {
        portText = String(controller.config.port)
        useCustomPort = controller.config.port != Self.defaultPort
        startAtLogin = SMAppService.mainApp.status == .enabled
        pinText = controller.config.browserPIN ?? ""
        usePIN = !pinText.isEmpty
        refreshUsage()
    }

    /// PIN を保存する。空にすると要求しなくなる。
    /// 変更すると、発行済みのセッションはサーバ側で無効になる。
    private func applyPIN() {
        let trimmed = pinText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            controller.config.browserPIN = nil
            controller.applyAndSave()
            return
        }
        guard trimmed.count >= 4, trimmed.count <= 8,
              trimmed.allSatisfy({ $0.isNumber }) else {
            controller.lastError = "PIN は 4〜8 桁の数字で指定してください"
            pinText = controller.config.browserPIN ?? ""
            return
        }
        controller.lastError = nil
        controller.config.browserPIN = trimmed
        controller.applyAndSave()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "共有する"
        if panel.runModal() == .OK {
            for url in panel.urls { controller.addShare(path: url.path) }
        }
    }

    private func applyPort() {
        guard let p = Int(portText), (1...65535).contains(p) else {
            portText = String(controller.config.port)
            return
        }
        guard p != controller.config.port else { return }
        controller.config.port = p
        controller.applyAndSave()
    }

    /// ログイン項目への登録。macOS 13 以降の SMAppService を使う。
    private func setStartAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            startAtLogin = on
        } catch {
            controller.lastError = "ログイン項目の変更に失敗しました: \(error.localizedDescription)"
            startAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}


/// 表示名の編集欄。Table のセル内で使う。
/// 別 View にすることで型推論の負荷を下げている。
private struct ShareNameField: View {
    @ObservedObject var controller: ServerController
    let share: Configuration.Share
    @State private var text: String = ""

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .onAppear { text = share.displayName }
            .onSubmit { controller.renameShare(id: share.id, to: text) }
    }
}
