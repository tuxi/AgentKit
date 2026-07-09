//
//  AppContainer.swift
//  CodeAgent
//
//  Example app dependency container.
//  Demonstrates: credential migration, AccountManager wiring,
//  client tool registration for P1 client tool execution.
//

import Foundation
import AgentKit

@Observable
final class AppContainer {

    let wsClient: WebSocketClient

    /// 用户身份管理 —— 登录 / Token 刷新 / 登出。
    let accountManager: AccountManager

    /// 客户端工具注册表 — 注册本地可执行工具。
    let toolRegistry: ToolRegistry

    init(wsClient: WebSocketClient) {
        self.wsClient = wsClient

        // 创建 AccountManager（默认指向本地 Gateway）
        let authClient = URLSessionAuthClient()
        self.accountManager = AccountManager(authClient: authClient)

        self.toolRegistry = ToolRegistry()

        // 从旧 AgentSettings 迁移到新 CredentialStore（仅一次）
        CredentialSettings.migrateFromLegacyIfNeeded()

        // P1: 注册客户端工具（Go 服务端无法执行的本地工具）
        registerClientTools()

        // 从 Keychain 恢复登录态
        Task { await accountManager.restore() }
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

    func makeAgentClient() -> RuntimeClient {
        #if os(iOS)
        // iOS: 内嵌 CodeAgent Runtime。
        // 启动前先注入 credential（AccountManager → CredentialStore → secretsJSON → Runtime）。
        injectCredentialsIntoRuntime()
        return DefaultAgentClient.fromRuntime()
        #else
        // macOS: 连接独立运行的 CodeAgent server（127.0.0.1:8797）。
        // Gateway credential 通过 CredentialStore → Authorization header 注入
        // 每个 HTTP 请求和 WebSocket 握手。BYOK credential 由远端 server 的启动参数传入。
        let env = RuntimeEnvironment(host: "127.0.0.1", port: 8797)
        let credentialStore = KeychainCredentialStore()
        return DefaultAgentClient(environment: env, credentialStore: credentialStore)
        #endif
    }

    func makeAgentDependencies() -> AgentDependencies {
        AgentDependencies(client: makeAgentClient(), toolRegistry: toolRegistry)
    }

    // MARK: - Credential Injection (iOS)

    /// 在 Runtime 启动前注入 credential。
    /// 如果用户已登录 → 注入 Gateway JWT + BYOK keys。
    /// 如果未登录 → 回退到旧 AgentSettings.secretsJSON()。
    private func injectCredentialsIntoRuntime() {
        #if os(iOS)
        Task {
            // 启动前先尝试恢复（如果 Task init 中的 restore 还没完成）
            if case .anonymous = accountManager.state {
                await accountManager.restore()
            }

            // 获取最新的 credential（含 lazy refresh）
            if let _ = try? await accountManager.gatewayCredential() {
                // 用户已登录 → 用 CredentialStore 启动
                try? await AgentRuntime.shared.launch(with: KeychainCredentialStore())
            } else {
                // 未登录 → 回退旧路径（AgentSettings.secretsJSON()）
                try? AgentRuntime.shared.ensureStarted()
            }
        }
        #endif
    }
}
