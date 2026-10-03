import AppKit

// メニューバー常駐アプリの入口。
// main.swift では @main が使えないので手動で組み立てる。
// AppKit は主スレッド前提なので MainActor.assumeIsolated で包む。
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Dock に出さず、メニューバーのみに常駐する。
    app.setActivationPolicy(.accessory)
    // delegate は app が保持しないので、寿命をここで固定する。
    objc_setAssociatedObject(app, "swift-video-server.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
