//
//  AppContainer.swift
//  CodeAgent
//
//  轻量示例：演示 AgentKit 最小集成模式。
//  完整功能版（含账号/用户/订阅）见独立 CodeAgent 仓库。
//

import Foundation
import AgentKit

@MainActor
@Observable
final class AppContainer {

    /// 模型管理 —— 本地偏好，模型列表由宿主 App 注入。
    let modelSettings: ModelSettingsStore

    /// 客户端工具注册表。
    let toolRegistry: ToolRegistry

    /// Product-specific Timeline extensions.
    let timelineExtensions: [any TimelineExtension]

    init() {
        self.modelSettings = ModelSettingsStore()
        self.toolRegistry = ToolRegistry()

        // 注入凭证存储：启动时将 KeychainCredentialStore 设置为全局 store。
        // 完整 App 可替换为基于 AuthManager 的实现，不依赖 Keychain。
        CredentialSettings.store = KeychainCredentialStore()

#if os(macOS)
        self.timelineExtensions = [DesktopControlEvidenceTimeline()]
#else
        self.timelineExtensions = []
#endif

        registerClientTools()
    }

    private func registerClientTools() {
        Task {
            await toolRegistry.register(DeviceInfoTool())
            await toolRegistry.register(CameraCaptureTool())
            await toolRegistry.register(DownloadFileTool())
#if os(macOS)
            await toolRegistry.register(ScreenshotTool())
#endif
        }
    }

    /// 创建 Runtime 客户端。
    /// - macOS: 连接本地 CodeAgent server (127.0.0.1:8797)
    /// - iOS: 内嵌 Runtime
    func makeAgentClient() -> RuntimeClient {
#if os(iOS)
        return DefaultAgentClient.fromRuntime()
#else
        let env = RuntimeEnvironment(host: "127.0.0.1", port: 8797)
        return DefaultAgentClient(environment: env)
#endif
    }

    func makeAgentDependencies() -> AgentDependencies {
        AgentDependencies(
            client: makeAgentClient(),
            toolRegistry: toolRegistry,
            timelineExtensions: timelineExtensions,
            onAuthExpired: nil
        )
    }
}
