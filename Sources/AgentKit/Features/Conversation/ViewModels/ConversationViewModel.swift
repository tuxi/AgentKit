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
    public private(set) var isConnecting = false

    /// A turn-starting input is waiting behind another session because the runtime has
    /// not advertised safe multi-session execution yet.
    public private(set) var isLocallyQueued = false
    public private(set) var isAwaitingTurnAcceptance = false

    public var isTurnActive: Bool {
        isLocallyQueued || isAwaitingTurnAcceptance
            || ["accepted", "queued", "running", "resuming"].contains(lifecycleStatus)
    }

    /// 会话概要（来自 `GET /v1/conversations/{id}`）。
    public private(set) var detail: ConversationDetail?

    /// v1.2 lifecycle status for the currently selected session.
    public private(set) var lifecycleStatus: String?
    public private(set) var queueReason: String?
    public private(set) var queuePosition: Int?

    /// Runtime-owned queue copy. This is intentionally distinct from the local
    /// compatibility FIFO used when multi-session capability is unavailable.
    public var runtimeQueueDescription: String {
        let waitReason: String
        switch queueReason {
        case "workspace_lease": waitReason = "等待工作区可用"
        case "capacity": waitReason = "等待执行槽位"
        default: waitReason = "等待 Runtime 调度"
        }
        if let queuePosition, queuePosition > 0 {
            return "已排队（第 \(queuePosition) 位）— \(waitReason)"
        }
        return "已排队 — \(waitReason)"
    }

    /// When the current session was marked paused.
    public private(set) var pausedAt: Date?

    /// 对话主干（来自 `GET /v1/conversations/{id}/messages`）。
    public private(set) var messages: [Message] = []

    /// 本会话选择的模型 ID（Gateway 原生 ID，如 `"deepseek-v4-pro"`）。
    /// 每个对话独立跟踪自己的模型，不是全局设置。
    public var selectedModel: String

    private let client: RuntimeClient
    private var channel: (any RuntimeSessionChannel)?
    private let turnCoordinator: ConversationTurnCoordinator?
    private let capabilityRegistry: RuntimeCapabilityRegistry?
    private let toolRegistry: ToolRegistry
    let timelineExtensions: [any TimelineExtension]
    private var streamTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var turnDispatchTask: Task<Void, Never>?
    private var queuedTicket: UUID?

    /// Host 注入的 auth 恢复钩子。收到 `turn_failed(code: auth_expired)` 时调用
    /// （契约：credential-injection-v1 §5.2 —— 刷新 token → Reconfigure Runtime）。
    private let onAuthExpired: (@MainActor () async -> Void)?

    /// auth 恢复进行中标记 —— 防止连续 auth_expired 事件触发并发刷新。
    private var isRecoveringAuth = false

    // MARK: - Init

    public init(
        client: RuntimeClient,
        toolRegistry: ToolRegistry = ToolRegistry(),
        workspace: Workspace? = nil,
        model: String = "",
        timelineExtensions: [any TimelineExtension] = [],
        turnCoordinator: ConversationTurnCoordinator? = nil,
        capabilityRegistry: RuntimeCapabilityRegistry? = nil,
        onAuthExpired: (@MainActor () async -> Void)? = nil
    ) {
        self.client = client
        self.toolRegistry = toolRegistry
        self.workspace = workspace
        self.selectedModel = model
        self.timelineExtensions = timelineExtensions
        self.turnCoordinator = turnCoordinator
        self.capabilityRegistry = capabilityRegistry
        self.onAuthExpired = onAuthExpired
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
        if self.conversation?.id == conversation.id, isConnected || isConnecting {
            return
        }
        isConnecting = true
        defer { isConnecting = false }
        self.conversation = conversation
        self.snapshot = .empty(sessionID: conversation.id)
        currentTurnID = nil
        detail = nil
        lifecycleStatus = conversation.turnStatus
        queueReason = nil
        queuePosition = nil
        pausedAt = conversation.pausedDate
        messages = []

        let channel = client.makeSessionChannel(conversationID: conversation.id)
        self.channel = channel

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
                await channel.registerTools(toolInfos)
            }

            // 把历史游标 seed 给传输层：直播流对 seq <= cursor 的帧去重（§2 恢复流程），
            // 且每次（重）连后传输层先 GET /events?since=<已收最大 seq> 补缺口再放行直播帧
            // ——断线重连对本 stream 透明，不再整页重放历史。
            let eventStream = try await channel.connect(since: sinceCursor)
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
        guard let channel else { return }
        guard input.startsNewTurn, let turnCoordinator else {
            await channel.send(input: input)
            return
        }

        turnDispatchTask?.cancel()
        let ticket = await turnCoordinator.enqueue(sessionID: channel.sessionID)
        queuedTicket = ticket
        isLocallyQueued = true

        // Runtime-wide HTTP capabilities are authoritative. A legacy Runtime that only
        // has hello strings remains serialized even if an individual socket is healthy.
        // Refresh at the turn boundary as well as app activation: a local daemon can be
        // restarted with a different max_concurrent_turns while the GUI stays open.
        if let refreshedCapabilities = try? await client.runtimeCapabilities() {
            await capabilityRegistry?.update(refreshedCapabilities)
        }
        let allowsConcurrent = await capabilityRegistry?.current().allowsMultiSessionExecution ?? false

        turnDispatchTask = Task { [weak self, channel, turnCoordinator] in
            while !Task.isCancelled {
                if await turnCoordinator.tryAcquire(
                    ticket: ticket,
                    sessionID: channel.sessionID,
                    allowsConcurrentSessions: allowsConcurrent
                ) {
                    guard !Task.isCancelled else {
                        await turnCoordinator.release(sessionID: channel.sessionID)
                        return
                    }
                    self?.isLocallyQueued = false
                    self?.queuedTicket = nil
                    self?.isAwaitingTurnAcceptance = true
                    await channel.send(input: input)
                    return
                }
                try? await Task.sleep(for: .milliseconds(75))
            }
            await turnCoordinator.cancel(ticket: ticket)
        }
    }

    /// 发送消息，驱动一轮对话。
    @available(*, deprecated, message: "Use send(input: .text(...))")
    public func sendMessage(_ text: String) async {
        await client.send(input: .text(text))
    }

    /// 回复审批请求（两态兼容）。
    public func approve(id: String, approved: Bool) async {
        await channel?.sendApproval(id: id, approved: approved)
        await engine?.resolveApproval(requestID: id, approved: approved)
    }

    /// 回复审批请求（v1.2 三态）。
    /// - Parameters:
    ///   - decision: "once" | "always" | "deny"
    ///   - scope: "local"（默认）或 "user"，仅 decision="always" 时有效
    public func approve(id: String, decision: String, scope: String? = nil) async {
        await channel?.sendApproval(id: id, decision: decision, scope: scope)
        await engine?.resolveApproval(requestID: id, approved: decision != "deny")
    }

    /// 回复计划审批请求。
    public func approvePlan(id: String, approved: Bool) async {
        await channel?.sendPlanApproval(id: id, approved: approved)
        await engine?.resolvePlanApproval(requestID: id, approved: approved)
    }

    /// 取消当前 turn。
    public func cancelTurn() async {
        if let queuedTicket {
            turnDispatchTask?.cancel()
            await turnCoordinator?.cancel(ticket: queuedTicket)
            self.queuedTicket = nil
            isLocallyQueued = false
            isAwaitingTurnAcceptance = false
            return
        }
        // cancel_turn has no guaranteed terminal event, so end the local graph
        // before waiting for transport. This also closes any running tool card.
        await engine?.cancelActiveTurn()
        await channel?.cancelTurn()
        if let sessionID = conversation?.id {
            await turnCoordinator?.release(sessionID: sessionID)
        }
        currentTurnID = nil
        lifecycleStatus = nil
        pausedAt = nil
    }

    /// Optimistically reflect that ResumeSession was accepted by the host wrapper.
    public func markResumeRequested() {
        lifecycleStatus = "resuming"
        pausedAt = nil
    }

    /// 断开连接。
    public func disconnect() async {
        turnDispatchTask?.cancel()
        if let queuedTicket {
            await turnCoordinator?.cancel(ticket: queuedTicket)
        }
        queuedTicket = nil
        isLocallyQueued = false
        isAwaitingTurnAcceptance = false
        streamTask?.cancel()
        streamTask = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        engine = nil
        await channel?.disconnect()
        channel = nil
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
        if lifecycleStatus == "running" || lifecycleStatus == "resuming" {
            await turnCoordinator?.markActive(sessionID: conversationID)
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

        // auth_expired → Host 恢复流程（刷新 token → Reconfigure Runtime）
        if case .turnFailed(_, _, _, let errorCode) = event,
           errorCode == "auth_expired" {
            await recoverFromAuthExpiry()
        }

        // P1: 拦截客户端工具执行
        if case .toolStarted(_, let callID, let tool) = event,
           tool.executor == .client {
            Task { await executeClientTool(callID: callID, tool: tool) }
        }
    }

    private func recoverFromAuthExpiry() async {
        guard let onAuthExpired, !isRecoveringAuth else { return }
        isRecoveringAuth = true
        defer { isRecoveringAuth = false }
        await onAuthExpired()
    }

    private func forwardToTimelineExtensions(_ event: AgentEvent) async {
        for timelineExtension in timelineExtensions {
            await timelineExtension.handle(event)
        }
    }

    private func updateLifecycle(from event: AgentEvent) {
        switch event {
        case .turnAccepted:
            isAwaitingTurnAcceptance = false
            lifecycleStatus = "accepted"
            queueReason = nil
            queuePosition = nil
        case .turnQueued(_, let reason, let position):
            isAwaitingTurnAcceptance = false
            lifecycleStatus = "queued"
            queueReason = reason
            queuePosition = position
        case .turnStarted(let turnID, _):
            isAwaitingTurnAcceptance = false
            currentTurnID = turnID
            lifecycleStatus = "running"
            queueReason = nil
            queuePosition = nil
            pausedAt = nil
            if let sessionID = conversation?.id {
                Task { await turnCoordinator?.markActive(sessionID: sessionID) }
            }
        case .turnFinished:
            isAwaitingTurnAcceptance = false
            lifecycleStatus = "done"
            queueReason = nil
            queuePosition = nil
            pausedAt = nil
            releaseTurnPermit()
        case .turnPaused:
            isAwaitingTurnAcceptance = false
            lifecycleStatus = "paused"
            queueReason = nil
            queuePosition = nil
            pausedAt = Date()
            releaseTurnPermit()
        case .turnResumed:
            lifecycleStatus = "resuming"
            pausedAt = nil
        case .turnFailed:
            isAwaitingTurnAcceptance = false
            lifecycleStatus = "failed"
            queueReason = nil
            queuePosition = nil
            pausedAt = nil
            releaseTurnPermit()
        case .turnCancelled:
            isAwaitingTurnAcceptance = false
            lifecycleStatus = "cancelled"
            queueReason = nil
            queuePosition = nil
            pausedAt = nil
            currentTurnID = nil
            releaseTurnPermit()
        default:
            break
        }
    }

    // MARK: - Client tool execution

    /// 在本地执行客户端工具，并将结果回传给服务端。
    private func executeClientTool(callID: String, tool: ToolCall) async {
        // 查找已注册的本地工具
        guard let clientTool = await toolRegistry.find(name: tool.toolName) else {
            await channel?.send(input: .toolResult(ToolResultContent(
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
        await channel?.send(input: .toolResult(ToolResultContent(
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

    private func releaseTurnPermit() {
        guard let sessionID = conversation?.id else { return }
        Task { await turnCoordinator?.release(sessionID: sessionID) }
    }
}

private extension AgentInput {
    var startsNewTurn: Bool {
        switch kind {
        case .text, .system:
            return true
        case .toolResult, .command:
            return false
        }
    }
}
