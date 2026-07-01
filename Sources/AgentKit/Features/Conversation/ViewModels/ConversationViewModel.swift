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

    // ── v1 (deprecated): kept for backward-compat during transition ──

    /// Legacy state machine. Prefer `snapshot` for new code.
    @available(*, deprecated, message: "Use snapshot.timeline instead of state.orderedTurns")
    public private(set) var state = ConversationState()

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

    private let client: RuntimeClient
    private let toolRegistry: ToolRegistry
    private var streamTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?

    // MARK: - Init

    public init(client: RuntimeClient, toolRegistry: ToolRegistry = ToolRegistry(), workspace: Workspace? = nil) {
        self.client = client
        self.toolRegistry = toolRegistry
        self.workspace = workspace
    }

    /// 本会话用于展示的工作区标签。
    public var workspaceDisplayName: String? {
        if let workspace { return workspace.name }
        if let path = detail?.workspacePath, !path.isEmpty {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return nil
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
        state = ConversationState()
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
                // Also mirror to legacy state for backward compat
                self.mirrorToLegacyState(snap)
            }
        }

        // Phase 1: 拉取历史数据 → import into engine
        await fetchHistory(conversationID: conversation.id, engine: eng)

        // Phase 2: 连接实时流 → feed to engine
        do {
            // P1: 必须在 connect() 之前注册工具（onHandshake 闭包在 attach 时捕获 pendingTools）
            let toolInfos = await toolRegistry.registeredToolInfos
            if !toolInfos.isEmpty {
                await client.registerTools(toolInfos)
            }

            let eventStream = try await client.connect(conversationID: conversation.id)
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

    /// 回复审批请求。
    public func approve(id: String, approved: Bool) async {
        await client.sendApproval(id: id, approved: approved)
        state.resolveApproval(id: id, approved: approved)
        await engine?.resolveApproval(requestID: id, approved: approved)
    }

    /// 回复计划审批请求。
    public func approvePlan(id: String, approved: Bool) async {
        await client.sendPlanApproval(id: id, approved: approved)
        await engine?.resolvePlanApproval(requestID: id, approved: approved)
    }

    /// 取消当前 turn。
    public func cancelTurn() async {
        await client.cancelTurn()
        if let id = state.currentTurnID {
            state.turns[id]?.status = .cancelled
            state.currentTurnID = nil
        }
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

    private func fetchHistory(conversationID: String, engine: RuntimeEngine) async {
        async let detailTask = try? client.getConversationDetail(id: conversationID)
        async let messagesTask = try? client.getMessages(conversationID: conversationID)
        async let eventsTask = try? client.getEvents(conversationID: conversationID)

        let (detailResult, messagesResult, eventsResult) = await (detailTask, messagesTask, eventsTask)

        self.detail = detailResult
        if let detailResult {
            lifecycleStatus = detailResult.turnStatus ?? lifecycleStatus
            pausedAt = detailResult.pausedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? pausedAt
        }
        self.messages = messagesResult ?? []

        if let events = eventsResult {
            // v2: import into engine (replays through reducer → projects timeline)
            await engine.importHistory(events)

            // Also replay into legacy state for backward compat
            for event in events {
                state.reduce(event)
            }
        }
        state.historyReplayed = true
    }

    // MARK: - Event handling

    /// v2: delegate to engine. ViewModel does NOT reduce.
    private func handleEvent(_ event: AgentEvent, engine: RuntimeEngine) async {
        updateLifecycle(from: event)
        state.reduce(event)
        await engine.ingest(event)

        // P1: 拦截客户端工具执行
        if case .toolStarted(_, let callID, let tool) = event,
           tool.executor == .client {
            Task { await executeClientTool(callID: callID, tool: tool) }
        }
    }

    private func updateLifecycle(from event: AgentEvent) {
        switch event {
        case .turnStarted:
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
        let result: String
        let isError: Bool
        do {
            result = try await clientTool.execute(args: tool.toolArgs)
            isError = false
        } catch {
            result = error.localizedDescription
            isError = true
        }

        // 回传
        await client.send(input: .toolResult(ToolResultContent(
            toolUseID: callID,
            content: result,
            isError: isError
        )))
    }

    /// Mirror engine snapshot to legacy ConversationState for backward compat.
    private func mirrorToLegacyState(_ snap: RuntimeSnapshot) {
        // Keep pending approval in sync
        if let approval = snap.pendingApproval {
            state.pendingApproval = approval
        }
        // Note: full TurnGroup mirror is not needed — legacy state is only
        // used for quick-access fields (pendingApproval, latestTodos) during transition.
        // Timeline UI reads exclusively from snapshot.
    }

    private func setDisconnected() async {
        isConnected = false
    }
}
