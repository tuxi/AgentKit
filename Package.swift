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
        .package(url: "https://github.com/swiftlang/swift-markdown", branch: "main"),
    ],
    targets: [
        .binaryTarget(
            name: "CodeAgentRuntime",
            url: "https://github.com/tuxi/code-agent-releases/releases/download/0.5.0/CodeAgentRuntime.xcframework.zip",
            checksum: "81651d961c76bb47ba46113aac827c5d3915140e7c07332ee0ae29b0d9bb2f71"
        ),
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "AgentKit",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .target(name: "CodeAgentRuntime", condition: .when(platforms: [.iOS])),
            ],
            path: "Sources/AgentKit",
            resources: [
                // iOS 内嵌 runtime 的默认 config，经 Bundle.module 读取传给 MobileStart。
                .copy("Resources/config.yaml"),
                .copy("Resources/skills"),   // 从 build/skills/ 拷贝到 app bundle
                .copy("Resources/ConversationWeb")
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
