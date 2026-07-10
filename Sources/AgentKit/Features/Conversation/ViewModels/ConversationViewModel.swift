//
//  ConversationViewModel.swift
//  AgentKit
//
//  Thin subscriber to RuntimeEngine.
//  ViewModel does NOT reduce — it only subscribes to RuntimeEngine.stateStream().
//  Primary UI data source: `snapshot: RuntimeSnapshot`.
//  `state: ConversationState` kept as deprecated backward-compat for approval/todo.
//

import SwiftUI

// MARK: - ConversationViewModel

@MainActor
@Observable
public final class ConversationViewModel {

    // ── v2: Runtime Engine (primary data source) ──

    /// The event-sourced runtime engine for this session.
    private var engine: RuntimeEngine?

    /// Latest snapshot from the engine — primary UI data source.
    public private(set) var snapshot: RuntimeSnapshot = .empty(sessionID: "")

    /// Current turn ID (from turn_started) — used by cancelTurn.
    private var currentTurnID: String?

    // ── Session identity ──

    /// 当前会话引用。
    public private(set) var conversation: ConversationRef?

    /// P5.0 — 本会话绑定的工作区（创建时锁定，不可变）。
    public let workspace: Workspace?

    /// 是否已连接事件流。
    public private(set) var isConnected = false

    /// 会话概要（来自 `GET /v1/conversations/{id}`）。
    public private(set) var detail: ConversationDetail?

    /// v1.2 lifecycle status for the currently selected session.
    public private(set) var lifecycleStatus: String?

    /// When the current session was marked paused.
    public private(set) var pausedAt: Date?

    /// 对话主干（来自 `GET /v1/conversations/{id}/messages`）。
    public private(set) var messages: [Message] = []

    /// 本会话选择的模型 ID（Gateway 原生 ID，如 `"deepseek-v4-pro"`）。
    /// 每个对话独立跟踪自己的模型，不是全局设置。
    public var selectedModel: String

    private let client: RuntimeClient
    private let toolRegistry: ToolRegistry
    let timelineExtensions: [any TimelineExtension]
    private var streamTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        client: RuntimeClient,
        toolRegistry: ToolRegistry = ToolRegistry(),
        workspace: Workspace? = nil,
        model: String = "",
        timelineExtensions: [any TimelineExtension] = []
    ) {
        self.client = client
        self.toolRegistry = toolRegistry
        self.workspace = workspace
        self.selectedModel = model
        self.timelineExtensions = timelineExtensions
    }

    /// 本会话用于展示的工作区标签。
    public var workspaceDisplayName: String? {
        if let anchor = workspaceAnchor {
            return anchor.displayName
        }
        if let workspace { return workspace.name }
        if let path = detail?.workspacePath, !path.isEmpty {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return nil
    }

    /// Structured workspace anchor from the runtime contract.
    public var workspaceAnchor: WorkspaceAnchor? {
        detail?.workspace ?? conversation?.workspace
    }

    /// Structured assets discovered from the current runtime snapshot.
    public var assetRefs: [AgentAssetRef] {
        var assets: [AgentAssetRef] = []
        for node in snapshot.timeline {
            guard case .tool(let tool) = node.kind else { continue }
            assets.append(contentsOf: tool.assets)
        }
        return AgentAssetDisplayIndex.unique(assets)
    }

    // MARK: - Public API

    /// 连接指定会话：先拉历史回放，再连 WS 收增量。
    /// v2 流程：
    ///   Phase 1: HTTP fetch history → RuntimeEngine.importHistory()
    ///   Phase 2: WebSocket stream → RuntimeEngine.ingest() per event
    ///   UI subscribes to RuntimeEngine.stateStream() for snapshots
    public func connect(to conversation: ConversationRef) async {
        self.conversation = conversation
        self.snapshot = .empty(sessionID: conversation.id)
        currentTurnID = nil
        detail = nil
        lifecycleStatus = conversation.turnStatus
        pausedAt = conversation.pausedDate
        messages = []

        // Create engine for this session
        let eng = RuntimeEngine(sessionID: conversation.id)
        self.engine = eng

        // Subscribe to state stream BEFORE importing history
        let stream = eng.stateStream()
        snapshotTask = Task { [weak self] in
            for await snap in stream {
                guard let self else { return }
                self.snapshot = snap
            }
        }

        // Phase 1: 拉取历史数据 → import into engine。
        // 返回值 = 历史批最大 seq（v1.2 §4 续传游标）。
        let sinceCursor = await fetchHistory(conversationID: conversation.id, engine: eng)

        // Phase 2: 连接实时流 → feed to engine
        do {
            // P1: 必须在 connect() 之前注册工具（onHandshake 闭包在 attach 时捕获 pendingTools）
            let toolInfos = await toolRegistry.registeredToolInfos
            if !toolInfos.isEmpty {
                await client.registerTools(toolInfos)
            }

            // 把历史游标 seed 给传输层：直播流对 seq <= cursor 的帧去重（§2 恢复流程），
            // 且每次（重）连后传输层先 GET /events?since=<已收最大 seq> 补缺口再放行直播帧
            // ——断线重连对本 stream 透明，不再整页重放历史。
            let eventStream = try await client.connect(conversationID: conversation.id, since: sinceCursor)
            isConnected = true
            await eng.markLive()

            streamTask = Task { [weak self] in
                guard let self else { return }
                for await event in eventStream {
                    await self.handleEvent(event, engine: eng)
                }
                await self.setDisconnected()
            }
        } catch {
            isConnected = false
        }
    }

    /// 发送结构化输入，驱动一轮对话。
    public func send(input: AgentInput) async {
        await client.send(input: input)
    }

    /// 发送消息，驱动一轮对话。
    @available(*, deprecated, message: "Use send(input: .text(...))")
    public func sendMessage(_ text: String) async {
        await client.send(input: .text(text))
    }

    /// 回复审批请求（两态兼容）。
    public func approve(id: String, approved: Bool) async {
        await client.sendApproval(id: id, approved: approved)
        await engine?.resolveApproval(requestID: id, approved: approved)
    }

    /// 回复审批请求（v1.2 三态）。
    /// - Parameters:
    ///   - decision: "once" | "always" | "deny"
    ///   - scope: "local"（默认）或 "user"，仅 decision="always" 时有效
    public func approve(id: String, decision: String, scope: String? = nil) async {
        await client.sendApproval(id: id, decision: decision, scope: scope)
        await engine?.resolveApproval(requestID: id, approved: decision != "deny")
    }

    /// 回复计划审批请求。
    public func approvePlan(id: String, approved: Bool) async {
        await client.sendPlanApproval(id: id, approved: approved)
        await engine?.resolvePlanApproval(requestID: id, approved: approved)
    }

    /// 取消当前 turn。
    public func cancelTurn() async {
        await client.cancelTurn()
        currentTurnID = nil
        lifecycleStatus = nil
        
    }

    /// Optimistically reflect that ResumeSession was accepted by the host wrapper.
    public func markResumeRequested() {
        lifecycleStatus = "resuming"
        pausedAt = nil
    }

    /// 断开连接。
    public func disconnect() async {
        streamTask?.cancel()
        streamTask = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        engine = nil
        await client.disconnect()
        isConnected = false
        conversation = nil
    }

    // MARK: - History

    /// - Returns: v1.2 §4 续传游标 = 历史批最大 `seq`（`AgentEventBatch.nextSince`），
    ///   传给 `connect(conversationID:since:)` 衔接直播流。历史拉取失败时返回 0（从头）。
    private func fetchHistory(conversationID: String, engine: RuntimeEngine) async -> Int {
        async let detailTask = try? client.getConversationDetail(id: conversationID)
        async let messagesTask = try? client.getMessages(conversationID: conversationID)
        // 用 getEventBatch 而非 getEvents：除事件外还带 nextSince（= 最大 seq）游标。
        async let eventsTask = try? client.getEventBatch(conversationID: conversationID, since: 0)

        let (detailResult, messagesResult, eventsResult) = await (detailTask, messagesTask, eventsTask)

        self.detail = detailResult
        if let detailResult {
            lifecycleStatus = detailResult.turnStatus ?? lifecycleStatus
            pausedAt = detailResult.pausedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? pausedAt
        }
        self.messages = messagesResult ?? []

        var sinceCursor = 0
        if let batch = eventsResult {
            sinceCursor = batch.nextSince

            // v2: import into engine (replays through reducer → projects timeline)
            await engine.importHistory(batch.events)
            for event in batch.events {
                await forwardToTimelineExtensions(event)
            }
        }
        return sinceCursor
    }

    // MARK: - Event handling

    /// v2: delegate to engine. ViewModel does NOT reduce.
    private func handleEvent(_ event: AgentEvent, engine: RuntimeEngine) async {
        updateLifecycle(from: event)
        await engine.ingest(event)
        await forwardToTimelineExtensions(event)

        // P1: 拦截客户端工具执行
        if case .toolStarted(_, let callID, let tool) = event,
           tool.executor == .client {
            Task { await executeClientTool(callID: callID, tool: tool) }
        }
    }

    private func forwardToTimelineExtensions(_ event: AgentEvent) async {
        for timelineExtension in timelineExtensions {
            await timelineExtension.handle(event)
        }
    }

    private func updateLifecycle(from event: AgentEvent) {
        switch event {
        case .turnStarted(let turnID, _):
            currentTurnID = turnID
            lifecycleStatus = "running"
            pausedAt = nil
        case .turnFinished:
            lifecycleStatus = "done"
            pausedAt = nil
        case .turnPaused:
            lifecycleStatus = "paused"
            pausedAt = Date()
        case .turnResumed:
            lifecycleStatus = "resuming"
            pausedAt = nil
        case .turnFailed:
            lifecycleStatus = "failed"
            pausedAt = nil
        default:
            break
        }
    }

    // MARK: - Client tool execution

    /// 在本地执行客户端工具，并将结果回传给服务端。
    private func executeClientTool(callID: String, tool: ToolCall) async {
        // 查找已注册的本地工具
        guard let clientTool = await toolRegistry.find(name: tool.toolName) else {
            await client.send(input: .toolResult(ToolResultContent(
                toolUseID: callID,
                content: "No local handler registered for tool: \(tool.toolName)",
                isError: true
            )))
            return
        }

        // 执行
        let result: ClientToolExecutionResult
        do {
            if let structuredTool = clientTool as? any StructuredClientTool {
                result = try await structuredTool.executeResult(args: tool.toolArgs)
            } else {
                result = ClientToolExecutionResult(
                    content: try await clientTool.execute(args: tool.toolArgs)
                )
            }
        } catch {
            result = ClientToolExecutionResult(
                content: error.localizedDescription,
                isError: true
            )
        }

        // 回传
        await client.send(input: .toolResult(ToolResultContent(
            toolUseID: callID,
            content: result.content,
            isError: result.isError,
            output: result.output,
            assets: result.assets
        )))
    }

    private func setDisconnected() async {
        isConnected = false
    }
}
