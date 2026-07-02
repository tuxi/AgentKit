//
//  RuntimeClient.swift
//  AgentKit
//
//  RuntimeClient 协议 — AgentKit UI 消费 Agent Runtime 的唯一入口。
//  ViewModel 只依赖此协议，不直接接触 HTTP / WebSocket / WireFrame。
//
//  Protocol: AgentKit Runtime Protocol v1.1 §RuntimeClient
//
//  架构分层：
//     UI → RuntimeClient (facade protocol)
//        → AgentTransport (runtime boundary protocol)
//        → CodeAgentTransport / DreamAITransport / MockTransport
//

import Foundation

// MARK: - RuntimeClient protocol

public protocol RuntimeClient: Sendable {
    /// 在 backend 创建新的 runtime session。
    /// - Parameter workspacePath: 工作区路径。
    /// - Returns: 包含 server-assigned `id` 的 `ConversationRef`。
    func createConversation(workspacePath: String) async throws -> ConversationRef

    /// 列出 backend 内存中的活跃 session。
    func listConversations() async throws -> [ConversationRef]

    /// 修改会话名称。
    func renameConversation(id: String, name: String) async throws -> ConversationRef

    /// 绑定到已存在的 server-owned session，返回事件流。
    ///
    /// ⚠️ `connect` = attach to server-owned session, NOT create session.
    ///
    /// - Parameter conversationID: server-assigned session id。
    /// - Returns: `AsyncStream<AgentEvent>` — 持续产出事件直到连接断开。
    func connect(conversationID: String) async throws -> AsyncStream<AgentEvent>

    /// 发送结构化输入到 backend runtime。
    ///
    /// 替代 `sendMessage(String)`。输入语义：execution graph continuation edge。
    ///
    /// ```swift
    /// await client.send(input: .text("Hello"))
    /// await client.send(input: .toolResult(ToolResultContent(toolUseID: "call_1", content: "...")))
    /// ```
    func send(input: AgentInput) async

    /// 向服务端注册客户端可执行工具。
    /// 应在连接建立后调用，服务端据此知道哪些工具可委托给客户端。
    func registerTools(_ tools: [ClientToolInfo]) async

    /// 审批回复 — 对应某条 `approval_request`。
    func sendApproval(id: String, approved: Bool) async

    /// 计划审批回复 — 对应某条 `plan_approval_request`。
    func sendPlanApproval(id: String, approved: Bool) async

    /// 取消当前正在执行的 turn。
    func cancelTurn() async

    /// 断开当前连接。session 仍在 server 端存活。
    func disconnect() async

    // MARK: - 历史读取

    /// 会话概要（由已记录事件派生）。
    func getConversationDetail(id: String) async throws -> ConversationDetail

    /// 对话主干消息（user/assistant）。
    func getMessages(conversationID: String) async throws -> [Message]

    /// 历史事件 — 用于 Timeline 回放。
    /// 推荐恢复流程：先调此方法渲染历史，再调 `connect()` 收增量。
    func getEvents(conversationID: String) async throws -> [AgentEvent]

    /// 事件增量读取（P8.7 子流轮询）。`since` 是不透明游标（0 = 从头，CodeAgent
    /// backend 的游标 = 最大 `seq`），下一次调用传返回值里的 `nextSince`。
    /// 子流（job/subagent）id 可直接作为 `conversationID` —— 该端点按 id
    /// 直读事件日志，不要求是根会话。
    func getEventBatch(conversationID: String, since: Int) async throws -> AgentEventBatch

    // MARK: - Assets

    /// Structured asset preview derived from persisted conversation events.
    func getAssetPreview(conversationID: String, assetID: String) async throws -> AgentAssetPreviewResponse

    /// Full text content for workspace-scoped text assets.
    func getAssetContent(conversationID: String, assetID: String) async throws -> AgentAssetContentResponse

    // MARK: - Repos

    /// clone 一个公开 GitHub 仓库到 backend 的 workspace 根下，返回其工作区路径。
    /// 默认实现抛 `unsupported`（mock backend）。
    func cloneRepo(url: String, ref: String?) async throws -> ClonedRepo
}

// MARK: - Backward compatibility

extension RuntimeClient {
    /// 向后兼容：纯文本消息发送。
    /// - Deprecated: 使用 `send(input: .text(...))` 替代。
    @available(*, deprecated, message: "Use send(input: .text(...))")
    public func sendMessage(_ text: String) async {
        await send(input: .text(text))
    }

    /// 默认不支持 clone（mock backend）。`DefaultAgentClient` 覆盖。
    public func cloneRepo(url: String, ref: String?) async throws -> ClonedRepo {
        throw RuntimeHTTPError.unsupported
    }

    public func getAssetPreview(conversationID: String, assetID: String) async throws -> AgentAssetPreviewResponse {
        throw RuntimeHTTPError.unsupported
    }

    public func getAssetContent(conversationID: String, assetID: String) async throws -> AgentAssetContentResponse {
        throw RuntimeHTTPError.unsupported
    }

    /// 默认实现：全量拉取后切尾（mock backend）。`DefaultAgentClient` 覆盖为 transport 直达。
    public func getEventBatch(conversationID: String, since: Int) async throws -> AgentEventBatch {
        let events = try await getEvents(conversationID: conversationID)
        let tail = since < events.count ? Array(events[since...]) : []
        return AgentEventBatch(events: tail, nextSince: max(since, events.count))
    }
}
