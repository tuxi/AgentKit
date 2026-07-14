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
    /// Create a control channel whose complete lifetime is bound to `conversationID`.
    /// New UI code must prefer this over the legacy current-session methods below.
    func makeSessionChannel(conversationID: String) -> any RuntimeSessionChannel

    /// Runtime-wide, versioned capabilities. 404/unsupported must safely degrade.
    func runtimeCapabilities() async throws -> RuntimeCapabilitySnapshot

    /// Ownership-filtered snapshot of sessions with live work.
    func activitySnapshot() async throws -> RuntimeActivitySnapshot

    /// Cursor-based incremental attention snapshot. Backends without delta
    /// support may ignore the cursor and return a full snapshot.
    func activitySnapshot(sinceSequence: Int64?) async throws -> RuntimeActivitySnapshot

    /// 在 backend 创建新的 runtime session。
    /// - Parameter workspacePath: 工作区路径。
    /// - Returns: 包含 server-assigned `id` 的 `ConversationRef`。
    func createConversation(workspacePath: String) async throws -> ConversationRef

    /// Create a session with an explicit Runtime workspace execution policy.
    func createConversation(request: CreateConversationRequest) async throws -> ConversationRef

    /// 列出 backend 内存中的活跃 session。
    func listConversations() async throws -> [ConversationRef]

    /// List the Runtime-owned archived partition. Never synthesized locally.
    func listArchivedConversations() async throws -> [ConversationRef]

    /// Move an idle conversation into the durable archived partition.
    func archiveConversation(id: String) async throws -> ConversationArchiveResponse

    /// Restore an archived conversation to the default active list.
    func restoreConversation(id: String) async throws -> ConversationArchiveResponse

    /// 修改会话名称。
    func renameConversation(id: String, name: String) async throws -> ConversationRef

    /// Explicitly remove a Runtime-managed worktree. This never deletes the
    /// conversation and never escalates to force on its own.
    func removeManagedWorktree(
        conversationID: String,
        request: ManagedWorktreeRemoveRequest
    ) async throws -> ManagedWorktreeRemoveResponse

    /// Permanently delete conversation state. Managed worktrees must be handled
    /// explicitly before this call; Runtime intentionally does not remove them.
    func deleteConversation(id: String) async throws

    /// 绑定到已存在的 server-owned session，返回事件流。
    ///
    /// ⚠️ `connect` = attach to server-owned session, NOT create session.
    ///
    /// - Parameter conversationID: server-assigned session id。
    /// - Parameter since: 续传游标 = 已回放历史里最大的 `seq`（v1.2 §4；
    ///   即 `getEventBatch(since: 0)` 返回的 `nextSince`，0 = 无历史）。
    ///   实现方对直播流按 seq 去重，并在每次（重）连后先补 `since` 之后的缺口
    ///   再放行直播帧 —— 断线重连对上层流透明，不再需要整页重放历史。
    /// - Returns: `AsyncStream<AgentEvent>` — 持续产出事件直到连接断开。
    func connect(conversationID: String, since: Int) async throws -> AsyncStream<AgentEvent>

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

    /// 审批回复 — 对应某条 `approval_request`（两态兼容）。
    func sendApproval(id: String, approved: Bool) async

    /// 审批回复 — v1.2 三态（decision + scope）。
    /// - Parameters:
    ///   - decision: "once" | "always" | "deny"
    ///   - scope: "local"（默认）或 "user"，仅 decision="always" 时有效
    func sendApproval(id: String, decision: String, scope: String?) async

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

    // MARK: - Job 子流（P8.7 §4 Phase C）

    /// 后台 job 子流 backlog（`GET /v1/jobs/{id}/events`）。job 分区 seq 独立于父会话。
    func getJobEventBatch(jobID: String, since: Int) async throws -> AgentEventBatch

    /// 后台 job 子流实时只读流（`GET /v1/jobs/{id}/stream`）：backlog + 直播、seq 去重。
    func openJobStream(jobID: String) -> AsyncStream<AgentEvent>

    // MARK: - Assets

    /// Structured asset preview derived from persisted conversation events.
    func getAssetPreview(conversationID: String, assetID: String) async throws -> AgentAssetPreviewResponse

    /// Full text content for workspace-scoped text assets.
    func getAssetContent(conversationID: String, assetID: String) async throws -> AgentAssetContentResponse

    /// Resolve a runtime-relative URL such as `/v1/.../blob` against the active backend.
    func resolveRuntimeURL(_ value: String) -> URL?

    // MARK: - Repos

    /// clone 一个公开 GitHub 仓库到 backend 的 workspace 根下，返回其工作区路径。
    /// 默认实现抛 `unsupported`（mock backend）。
    func cloneRepo(url: String, ref: String?) async throws -> ClonedRepo
}

// MARK: - Backward compatibility

extension RuntimeClient {
    /// Source-compatible fallback for existing backends. This adapter remains
    /// single-session and therefore never advertises multi-session execution.
    public func makeSessionChannel(conversationID: String) -> any RuntimeSessionChannel {
        LegacyRuntimeSessionChannel(sessionID: conversationID, client: self)
    }

    public func runtimeCapabilities() async throws -> RuntimeCapabilitySnapshot {
        throw RuntimeHTTPError.unsupported
    }

    public func activitySnapshot() async throws -> RuntimeActivitySnapshot {
        throw RuntimeHTTPError.unsupported
    }

    public func activitySnapshot(sinceSequence: Int64?) async throws -> RuntimeActivitySnapshot {
        try await activitySnapshot()
    }

    /// Source-compatible fallback for backends that have not adopted execution
    /// policy metadata. Code-Agent overrides this and transmits the full request.
    public func createConversation(request: CreateConversationRequest) async throws -> ConversationRef {
        try await createConversation(workspacePath: request.workspacePath)
    }

    public func removeManagedWorktree(
        conversationID: String,
        request: ManagedWorktreeRemoveRequest
    ) async throws -> ManagedWorktreeRemoveResponse {
        throw RuntimeHTTPError.unsupported
    }

    public func listArchivedConversations() async throws -> [ConversationRef] {
        throw RuntimeHTTPError.unsupported
    }

    public func archiveConversation(id: String) async throws -> ConversationArchiveResponse {
        throw RuntimeHTTPError.unsupported
    }

    public func restoreConversation(id: String) async throws -> ConversationArchiveResponse {
        throw RuntimeHTTPError.unsupported
    }

    public func deleteConversation(id: String) async throws {
        throw RuntimeHTTPError.unsupported
    }

    /// 便捷入口：不带续传游标的 connect（等价 `since: 0`，即无已回放历史）。
    public func connect(conversationID: String) async throws -> AsyncStream<AgentEvent> {
        try await connect(conversationID: conversationID, since: 0)
    }

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

    public func resolveRuntimeURL(_ value: String) -> URL? {
        URL(string: value)
    }

    /// 默认实现：全量拉取后切尾（mock backend）。`DefaultAgentClient` 覆盖为 transport 直达。
    public func getEventBatch(conversationID: String, since: Int) async throws -> AgentEventBatch {
        let events = try await getEvents(conversationID: conversationID)
        let tail = since < events.count ? Array(events[since...]) : []
        return AgentEventBatch(events: tail, nextSince: max(since, events.count))
    }

    /// 默认实现：不支持 job 端点（mock backend）。
    public func getJobEventBatch(jobID: String, since: Int) async throws -> AgentEventBatch {
        throw RuntimeHTTPError.unsupported
    }

    /// 默认实现：无 job 实时流（mock backend）。
    public func openJobStream(jobID: String) -> AsyncStream<AgentEvent> {
        AsyncStream { $0.finish() }
    }
}
