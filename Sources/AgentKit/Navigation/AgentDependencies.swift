//
//  AgentDependencies.swift
//  AgentKit
//
//  UI 层依赖容器。ViewModel 通过此结构拿到协议实例，不感知具体实现。
//
//  Protocol: AgentKit Runtime Protocol v1.1
//

import Foundation

/// UI 层依赖容器。ViewModel 通过此结构拿到协议实例，不感知具体实现。
public struct AgentDependencies {
    /// 与 Agent Runtime 通信的客户端（agent-wire v1）。
    public let client: RuntimeClient

    /// 客户端工具注册表。服务端声明 `executor: "client"` 的工具调用在此查找并执行。
    /// 默认空（不注册任何工具），由 app 层注入。
    public let toolRegistry: ToolRegistry

    /// Host-owned additions to the generic conversation Timeline.
    public let timelineExtensions: [any TimelineExtension]

    public init(
        client: RuntimeClient,
        toolRegistry: ToolRegistry = ToolRegistry(),
        timelineExtensions: [any TimelineExtension] = []
    ) {
        self.client = client
        self.toolRegistry = toolRegistry
        self.timelineExtensions = timelineExtensions
    }
}
