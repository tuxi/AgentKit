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

    /// auth 恢复钩子。收到 `turn_failed(code: auth_expired)` 时由 ViewModel 调用。
    /// Host 在此实现「刷新 token → Reconfigure Runtime」（credential-injection-v1 §5.2）。
    public let onAuthExpired: (@MainActor () async -> Void)?

    /// GUI-owned persistence for terminal read/notified cursors.
    public let attentionReadStore: any ConversationAttentionReadStore

    /// GUI-owned durable composer/model/read state. Hosts may inject an encrypted
    /// implementation; the default uses Application Support SQLite.
    public let localStateStore: any ConversationLocalStateStore

    /// Host hook for local notifications or other out-of-conversation alerts.
    public let onAttentionEvent: (@MainActor (ConversationAttentionEvent) -> Void)?

    public init(
        client: RuntimeClient,
        toolRegistry: ToolRegistry = ToolRegistry(),
        timelineExtensions: [any TimelineExtension] = [],
        onAuthExpired: (@MainActor () async -> Void)? = nil,
        localStateStore: any ConversationLocalStateStore = SQLiteConversationLocalStateStore.shared,
        attentionReadStore: (any ConversationAttentionReadStore)? = nil,
        onAttentionEvent: (@MainActor (ConversationAttentionEvent) -> Void)? = nil
    ) {
        self.client = client
        self.toolRegistry = toolRegistry
        self.timelineExtensions = timelineExtensions
        self.onAuthExpired = onAuthExpired
        self.localStateStore = localStateStore
        self.attentionReadStore = attentionReadStore
            ?? ConversationLocalStateAttentionReadStore(localStateStore: localStateStore)
        self.onAttentionEvent = onAttentionEvent
    }
}
