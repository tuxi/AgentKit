// swift-tools-version: 6.1
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
            url: "https://github.com/tuxi/code-agent-releases/releases/download/1.6.7/CodeAgentRuntime.xcframework.zip",
            checksum: "99f1794d4b5339914f726d02a3ed6ed925ec398b9e1495fa8243a7a9ddb61a4b"
        ),
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "AgentKit",
            dependencies: [
                .product(name: "ClientToolProtocol", package: "ClientToolProtocol"),
                .product(name: "Markdown", package: "swift-markdown"),
                .target(name: "CodeAgentRuntime", condition: .when(platforms: [.iOS])),
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
