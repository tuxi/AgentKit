//
//  AppContainer.swift
//  CodeAgent
//
//  Example app dependency container.
//  Demonstrates: client tool registration for P1 client tool execution.
//

import Foundation
import AgentKit

@Observable
final class AppContainer {

    let wsClient: WebSocketClient

    /// 客户端工具注册表 — 注册本地可执行工具。
    let toolRegistry: ToolRegistry

    init(wsClient: WebSocketClient) {
        self.wsClient = wsClient
        self.toolRegistry = ToolRegistry()

        // P1: 注册客户端工具（Go 服务端无法执行的本地工具）
        registerClientTools()
    }

    private func registerClientTools() {
        Task {
            await toolRegistry.register(DeviceInfoTool())
            await toolRegistry.register(CameraCaptureTool())
            await toolRegistry.register(DownloadFileTool())
#if os(macOS)
            // ScreenshotTool 仅 macOS 可用（依赖 ScreenCaptureKit）
            await toolRegistry.register(ScreenshotTool())
#endif
        }
    }

    func makeAgentClient() -> RuntimeClient {
        #if os(iOS)
        // iOS: 内嵌 CodeAgent Runtime，从 AgentRuntime.shared 读取动态端口
        return DefaultAgentClient.fromRuntime()
        #else
        // macOS: 连接独立运行的 CodeAgent server
        let env = RuntimeEnvironment(host: "127.0.0.1", port: 8787)
        return DefaultAgentClient(environment: env)
        #endif
    }

    func makeAgentDependencies() -> AgentDependencies {
        AgentDependencies(client: makeAgentClient(), toolRegistry: toolRegistry)
    }
}
