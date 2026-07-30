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
            url: "https://github.com/tuxi/code-agent-releases/releases/download/1.2.8/CodeAgentRuntime.xcframework.zip",
            checksum: "420ea59b822d90b337739a544f0f66a2be968bd20ce9d60cb3e0a824a5f891f4"
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
                // iOS 内嵌 runtime 的默认 config，经 Bundle.module 读取传给 MobileStart。
                .copy("Resources/config.yaml"),
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
