// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "swift-video-server",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "swift-video-server", targets: ["VideoServerCLI"]),
        .executable(name: "VideoServerApp", targets: ["VideoServerApp"]),
        .library(name: "VideoServerCore", targets: ["VideoServerCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.26.0"),
    ],
    targets: [
        .target(
            name: "VideoServerCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "VideoServerKit",
            dependencies: [
                "VideoServerCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            // ブラウザ版クライアントの静的ファイル。
            resources: [.copy("Resources/Public")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // メニューバー常駐アプリ (Swift Video Server.app の中身)。
        .executableTarget(
            name: "VideoServerApp",
            dependencies: ["VideoServerKit", "VideoServerCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // コマンドライン版。実行ファイル名は swift-video-server。
        .executableTarget(
            name: "VideoServerCLI",
            dependencies: ["VideoServerKit", "VideoServerCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
