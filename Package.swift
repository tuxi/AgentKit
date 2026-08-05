// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AgentKit",
    platforms: [
         .iOS(.v18),
         .macOS(.v15)
     ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "AgentKit",
            targets: ["AgentKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/tuxi/ClientToolProtocol", branch: "main"),
        .package(url: "https://github.com/swiftlang/swift-markdown", branch: "main"),
    ],
    targets: [
        .binaryTarget(
            name: "CodeAgentRuntime",
            url: "https://github.com/tuxi/code-agent-releases/releases/download/1.4.9/CodeAgentRuntime.xcframework.zip",
            checksum: "4d97d4e0559529497fdf10cc3478047f6f79fd25f3b22698b1a9a6f1bf588d6d"
        ),
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "AgentKit",
            dependencies: [
                .product(name: "ClientToolProtocol", package: "ClientToolProtocol"),
                .product(name: "Markdown", package: "swift-markdown"),
                .target(name: "CodeAgentRuntime", condition: .when(platforms: [.iOS, .macOS])),
            ],
            path: "Sources/AgentKit",
            resources: [
                // iOS 内嵌 runtime 的默认 settings 文档（settings.File JSON 形状，
                // 经 MobileStart 的 settingsJSON 参数注入）。
                .copy("Resources/settings.json"),
                .copy("Resources/skills"),   // 从 build/skills/ 拷贝到 app bundle
                .copy("Resources/ConversationWeb"),
                .process("Resources/Localizable.xcstrings"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "AgentKitTests",
            dependencies: ["AgentKit"],
            path: "Tests/AgentKitTests"
        ),
    ]
)
