import SwiftUI
import VideoServerKit

/// サーバ状態画面。動作状況と接続先、直近のログを見せる。
struct StatusView: View {
    @ObservedObject var controller: ServerController
    @State private var lines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(controller.isRunning ? Color.green : Color.secondary)
                    .frame(width: 10, height: 10)
                Text(controller.isRunning ? "動作中" : "停止中")
                    .font(.headline)
                Spacer()
                Button(controller.isRunning ? "停止" : "開始") {
                    controller.isRunning ? controller.stop() : controller.start()
                }
            }

            if controller.isRunning {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ブラウザで開くアドレス")
                        .font(.subheadline)
                    ForEach(controller.listenAddresses, id: \.self) { addr in
                        Text(addr)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            Divider()
            Text("ログ").font(.subheadline)

            // 直近のやり取り。クライアントの挙動を確認するのに使う。
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(4)
            }
            .frame(minHeight: 200)
            .border(Color.secondary.opacity(0.3))
        }
        .padding(20)
        .frame(width: 560, height: 460)
        .onAppear {
            lines = Log.recent().suffix(200)
            Log.observe { line in
                Task { @MainActor in
                    lines.append(line)
                    if lines.count > 300 { lines.removeFirst(lines.count - 300) }
                }
            }
        }
    }
}
