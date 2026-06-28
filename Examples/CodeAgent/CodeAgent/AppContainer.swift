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
#if os(macOS)
            // ScreenshotTool 仅 macOS 可用（依赖 ScreenCaptureKit）
            await toolRegistry.register(ScreenshotTool())
#endif
        }
    }

    func makeAgentClient() -> RuntimeClient {
        return DefaultAgentClient()
    }

    func makeAgentDependencies() -> AgentDependencies {
        AgentDependencies(client: makeAgentClient(), toolRegistry: toolRegistry)
    }
}
