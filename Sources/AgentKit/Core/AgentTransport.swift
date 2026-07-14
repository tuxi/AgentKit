//
//  AgentTransport.swift
//  AgentKit
//
//  Agent Runtime Boundary — the single protocol boundary between
//  AgentKit UI and any backend runtime.
//
//  This is NOT an "HTTP/WS abstraction". It is the Agent Runtime Boundary —
//  all communication between UI and backend flows through this protocol.
//
//  Protocol: AgentKit Runtime Protocol v1.1 §AgentTransport
//

import Foundation

// MARK: - AgentTransport

/// Agent Runtime Boundary 协议。
///
/// 这是 UI 层与任何 backend runtime 之间的**唯一边界**。
/// 实现方可替换：`CodeAgentTransport` / `DreamAITransport` / `MockTransport`。
///
/// ## 三层语义
/// - **Session lifecycle**: `createConversation` / `attach` / `disconnect`
/// - **Input plane**: `send(input:)`
/// - **Control plane**: `approve` / `cancelTurn`
/// - **History plane**: `getEvents` / `getMessages` / `getConversationDetail`
/// - **Capability discovery**: `capabilities()`
///
/// ## Session model
/// ```
/// ConversationRef  = server-owned runtime identity
/// attach(sessionID) = bind to existing server session (NOT create)
/// disconnect()      = release transport binding (session lives on server)
/// ```
public protocol AgentTransport: Sendable {
    /// Session 标识类型。默认为 `String`（`ConversationRef.id`）。
    associatedtype SessionID = String

    // MARK: - Session lifecycle

    /// Create an independently retained control channel for one session.
    func makeSessionChannel(sessionID: String) -> any RuntimeSessionChannel
    func runtimeCapabilities() async throws -> RuntimeCapabilitySnapshot
    func activitySnapshot() async throws -> RuntimeActivitySnapshot
    func activitySnapshot(sinceSequence: Int64?) async throws -> RuntimeActivitySnapshot

    /// 在 backend 创建新的 runtime session。
    /// - Returns: server-assigned `ConversationRef`（含 `id`）。
    func createConversation(workspacePath: String) async throws -> ConversationRef
    func createConversation(request: CreateConversationRequest) async throws -> ConversationRef

    /// 列出 backend 内存中的活跃 session。
    func listConversations() async throws -> [ConversationRef]
    func listArchivedConversations() async throws -> [ConversationRef]
    func archiveConversation(id: String) async throws -> ConversationArchiveResponse
    func restoreConversation(id: String) async throws -> ConversationArchiveResponse

    /// 修改会话名称。
    func renameConversation(id: String, name: String) async throws -> ConversationRef
    func removeManagedWorktree(
        conversationID: String,
        request: ManagedWorktreeRemoveRequest
    ) async throws -> ManagedWorktreeRemoveResponse
    func deleteConversation(id: String) async throws

    /// 绑定到已存在的 server-owned session，返回事件流。
    ///
    /// - Important: `attach` 不是创建新 session。
    ///   `sessionID` 必须是 `createConversation()` 返回的 server-assigned id。
    ///
    /// - Parameter sessionID: server-assigned session identifier。
    /// - Parameter since: 续传游标 = 调用方已回放事件里最大的 `seq`
    ///   （`getEventBatch` 返回的 `nextSince`；0 = 无历史）。实现方据此对直播流
    ///   按 seq 去重，并在（重）连后先补 `since` 之后的缺口再放行直播帧（v1.2 §4）。
    /// - Returns: `AsyncStream<AgentEvent>` — 持续产出事件直到连接断开。
    func attach(sessionID: String, since: Int) async throws -> AsyncStream<AgentEvent>

    /// 释放传输层绑定。session 仍在 server 端存活。
    func disconnect() async

    // MARK: - Repos

    /// clone 一个公开 GitHub 仓库到 backend 的 workspace 根下，返回其工作区路径。
    /// 默认实现抛 `unsupported`（mock / 不支持的 backend）。
    func cloneRepo(url: String, ref: String?) async throws -> ClonedRepo

    // MARK: - Session state

    /// 当前是否已连接到 backend session。
    var isConnected: Bool { get }

    /// 当前绑定的 session ID，未连接时为 `nil`。
    var activeSessionID: String? { get }

    // MARK: - Input

    /// 发送结构化输入到 backend。
    func send(input: AgentInput) async

    // MARK: - Control plane

    /// 回复工具审批请求（两态兼容）。`id` 对应 `approval_request.id`。
    func approve(id: String, value: Bool) async

    /// 回复工具审批请求（v1.2 三态）。
    /// - Parameters:
    ///   - decision: "once" | "always" | "deny"
    ///   - scope: "local"（默认）或 "user"，仅 decision="always" 时有效
    func approve(id: String, decision: String, scope: String?) async

    /// 回复 Plan Mode 审批请求。`id` 对应 `plan_approval_request.id`。
    func approvePlan(id: String, value: Bool) async

    /// 取消当前正在执行的 turn。
    func cancelTurn() async

    // MARK: - History plane

    /// 会话概要（由已记录事件派生）。
    func getConversationDetail(id: String) async throws -> ConversationDetail

    /// 对话主干消息（user/assistant）。
    func getMessages(conversationID: String) async throws -> [Message]

    /// 历史事件 — 用于 Timeline 回放。
    func getEvents(conversationID: String) async throws -> [AgentEvent]

    /// 事件增量读取（P8.7 子流轮询）。`since` 是不透明游标（0 = 从头），
    /// 下一次调用传返回值里的 `nextSince`。CodeAgent backend 的游标 = 最大 `seq`。
    func getEventBatch(conversationID: String, since: Int) async throws -> AgentEventBatch

    // MARK: - Job 子流（P8.7 §4 Phase C）

    /// 后台 job 子流的 backlog 增量读取（`GET /v1/jobs/{id}/events?since=`）。
    /// job 分区 seq 独立于父会话，`since` 只用 job 自己的游标。
    func getJobEventBatch(jobID: String, since: Int) async throws -> AgentEventBatch

    /// 后台 job 子流的实时只读流（`GET /v1/jobs/{id}/stream`）：先 backlog 后直播、
    /// seq 去重，收到 `job_finished` 即终态。流被取消 / consumer 退出时自动断开。
    func openJobStream(jobID: String) -> AsyncStream<AgentEvent>

    // MARK: - Assets

    /// Structured asset preview derived from persisted conversation events.
    func getAssetPreview(conversationID: String, assetID: String) async throws -> AgentAssetPreviewResponse

    /// Full text content for workspace-scoped text assets.
    func getAssetContent(conversationID: String, assetID: String) async throws -> AgentAssetContentResponse

    /// Resolve a runtime-relative URL such as `/v1/.../blob` against the active backend.
    func resolveRuntimeURL(_ value: String) -> URL?

    // MARK: - Tool registration

    /// 向服务端注册客户端可执行工具。
    /// 应在连接建立后（handshake 完成后）尽快调用。
    func registerTools(_ tools: [ClientToolInfo]) async

    // MARK: - Capability discovery

    /// Backend runtime 能力声明。
    ///
    /// `async` 语义：未来可能 server-driven / dynamic feature gating。
    /// UI 据此决定渲染策略，不写死 backend 能力判断。
    func capabilities() async -> AgentCapabilityFlags
}

// MARK: - Default impls

extension AgentTransport {
    /// Compatibility adapter for transports that still expose only a current-session
    /// binding. It is intentionally not used by `CodeAgentTransport`.
    public func makeSessionChannel(sessionID: String) -> any RuntimeSessionChannel {
        LegacyAgentTransportSessionChannel(sessionID: sessionID, transport: self)
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

    /// 便捷入口：不带续传游标的 attach（等价 `since: 0`，即无已回放历史）。
    public func attach(sessionID: String) async throws -> AsyncStream<AgentEvent> {
        try await attach(sessionID: sessionID, since: 0)
    }

    /// 默认不支持 clone（mock / 旧 backend）。CodeAgentTransport 覆盖。
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

    /// 默认实现：全量拉取后按已转换事件数切尾（mock / 不支持 `since` 的 backend）。
    /// 此实现的游标是"已转换事件计数" —— CodeAgentTransport 覆盖为真实的 seq 游标。
    public func getEventBatch(conversationID: String, since: Int) async throws -> AgentEventBatch {
        let events = try await getEvents(conversationID: conversationID)
        let tail = since < events.count ? Array(events[since...]) : []
        return AgentEventBatch(events: tail, nextSince: max(since, events.count))
    }

    /// 默认实现：不支持 job 端点（mock / 非 CodeAgent backend）。
    public func getJobEventBatch(jobID: String, since: Int) async throws -> AgentEventBatch {
        throw RuntimeHTTPError.unsupported
    }

    /// 默认实现：无 job 实时流，返回立即结束的空流。
    public func openJobStream(jobID: String) -> AsyncStream<AgentEvent> {
        AsyncStream { $0.finish() }
    }
}

/// Source-compatible fallback for third-party transports.
private final class LegacyAgentTransportSessionChannel: RuntimeSessionChannel, @unchecked Sendable {
    let sessionID: String
    private let transport: any AgentTransport

    init(sessionID: String, transport: any AgentTransport) {
        self.sessionID = sessionID
        self.transport = transport
    }

    var isConnected: Bool {
        transport.activeSessionID == sessionID && transport.isConnected
    }

    func connect(since: Int) async throws -> AsyncStream<AgentEvent> {
        try await transport.attach(sessionID: sessionID, since: since)
    }
    func send(input: AgentInput) async { await transport.send(input: input) }
    func registerTools(_ tools: [ClientToolInfo]) async { await transport.registerTools(tools) }
    func sendApproval(id: String, approved: Bool) async {
        await transport.approve(id: id, value: approved)
    }
    func sendApproval(id: String, decision: String, scope: String?) async {
        await transport.approve(id: id, decision: decision, scope: scope)
    }
    func sendPlanApproval(id: String, approved: Bool) async {
        await transport.approvePlan(id: id, value: approved)
    }
    func cancelTurn() async { await transport.cancelTurn() }
    func disconnect() async { await transport.disconnect() }
    func capabilities() async -> AgentCapabilityFlags { await transport.capabilities() }
}
