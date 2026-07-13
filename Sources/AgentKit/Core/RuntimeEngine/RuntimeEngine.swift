//
//  RuntimeEngine.swift
//  AgentKit
//
//  Actor — single owner of runtime state.
//  ViewModel subscribes. ViewModel does NOT reduce.
//  Ingest v1 AgentEvent → reduce → project → publish RuntimeSnapshot.
//

import Foundation

// MARK: - RuntimeSnapshot

/// Pure snapshot published to UI. Immutable. Contains pre-computed timeline.
/// Deliberately does NOT carry the ExecutionGraph: the engine keeps mutating
/// its graph after each yield, so a graph captured here would force a full
/// CoW dictionary copy on every subsequent mutation (~60Hz while streaming).
public struct RuntimeSnapshot: Sendable {
    public let timeline: [ExecutionNode]
    /// Turn → Block projection consumed by the timeline UI. Projected once
    /// per snapshot on the engine actor — views must not re-project.
    public let turns: [ConversationTurn]
    public let pendingApproval: ApprovalRequest?
    public let pendingPlanApproval: PlanApprovalRequest?
    public let latestTodos: [TodoItem]
    /// Aggregated token, billing, and timing statistics for the active turn.
    public let modelStats: ModelStats?
    public let isLive: Bool
    /// Monotonic counter — increments on every snapshot yield.
    /// UI uses this to trigger auto-scroll during streaming.
    public let generation: UInt64
    /// When the current model invocation started. Non-nil = model is actively thinking.
    public let modelStartedAt: Date?
    /// When the current turn started (turn_started → turn_finished). Non-nil =
    /// the agent is actively working on a turn. Drives the live working indicator.
    public let turnStartedAt: Date?
  
    public init(timeline: [ExecutionNode],
                turns: [ConversationTurn] = [],
                pendingApproval: ApprovalRequest? = nil,
                pendingPlanApproval: PlanApprovalRequest? = nil,
                latestTodos: [TodoItem] = [],
                modelStats: ModelStats? = nil,
                isLive: Bool = false,
                generation: UInt64 = 0,
                modelStartedAt: Date? = nil,
                turnStartedAt: Date? = nil) {
        self.timeline = timeline
        self.turns = turns
        self.pendingApproval = pendingApproval
        self.pendingPlanApproval = pendingPlanApproval
        self.latestTodos = latestTodos
        self.modelStats = modelStats
        self.isLive = isLive
        self.generation = generation
        self.modelStartedAt = modelStartedAt
        self.turnStartedAt = turnStartedAt
    }

    /// Empty snapshot for initial state.
    public static func empty(sessionID: String) -> RuntimeSnapshot {
        RuntimeSnapshot(timeline: [])
    }
}

/// Aggregated token, billing, and timing statistics for one turn.
public struct ModelStats: Sendable, Equatable {
    /// Prompt size of the most recent invocation — the current context scale.
    public var contextTokens: Int
    /// Provider tokens summed across all invocations in this turn.
    public var totalTokens: Int
    /// Usage units summed across all invocations when the provider supplies them.
    public var usageUnits: Int64
    /// Whether at least one invocation supplied billing units.
    public var hasUsageUnits: Bool
    public var invocationCount: Int
    public var elapsedMs: Int

    public init(contextTokens: Int = 0, totalTokens: Int = 0, usageUnits: Int64 = 0,
                hasUsageUnits: Bool = false, invocationCount: Int = 0, elapsedMs: Int = 0) {
        self.contextTokens = contextTokens
        self.totalTokens = totalTokens
        self.usageUnits = usageUnits
        self.hasUsageUnits = hasUsageUnits
        self.invocationCount = invocationCount
        self.elapsedMs = elapsedMs
    }

    public var formattedContextTokens: String { Self.format(contextTokens) }
    public var formattedTotalTokens: String { Self.format(totalTokens) }
    public var formattedUsageUnits: String { Self.format(usageUnits) }

    private static func format<T: BinaryInteger>(_ value: T) -> String {
        if value >= 1000 {
            String(format: "%.1fK", Double(value) / 1000.0)
        } else {
            "\(value)"
        }
    }

    public var formattedElapsed: String {
        if elapsedMs >= 1000 {
            String(format: "%.1fs", Double(elapsedMs) / 1000.0)
        } else {
            "\(elapsedMs)ms"
        }
    }
}

// MARK: - RuntimeEngine

/// Single owner of runtime state for one session.
/// - Ingest v1 AgentEvents → ExecutionReducer → ExecutionGraph
/// - Project graph → timeline via TimelineProjection
/// - Publish RuntimeSnapshot to UI subscribers
///
/// ViewModel is a thin subscriber — it never calls reduce.
public actor RuntimeEngine {

    // MARK: - Identity

    public let sessionID: String

    // MARK: - State

    private var graph: ExecutionGraph
    private var reducer: ExecutionReducer
    private let timelineProjection: TimelineProjection
    private let presenter: ExecutionPresenter

    /// Pending approval (mirrors ConversationState for backward compat).
    private var _pendingApproval: ApprovalRequest?

    /// v1.2 三态审批去重：已回复过的审批请求 ID（重连后直接忽略）。
    private var resolvedApprovalIDs: Set<String> = []

    /// Pending plan approval (Plan Mode).
    private var _pendingPlanApproval: PlanApprovalRequest?

    /// Latest todo list from the agent.
    private var _latestTodos: [TodoItem] = []

    /// Stats aggregated across the active turn's model invocations.
    private var _modelStats: ModelStats?
    /// `model_finished` IDs already included in the current turn. Reconnect
    /// replay may resend persisted events, so IDs must not be counted twice.
    private var countedInvocationIDs: Set<String> = []

    /// When the current model invocation started. Non-nil = model is thinking.
    private var _modelStartedAt: Date?
    /// Set on turn_started, cleared on turn_finished — drives the live working indicator.
    private var _turnStartedAt: Date?
    /// Identity of the in-flight turn. Needed because cancel_turn is allowed
    /// to finish without a corresponding terminal event.
    private var activeTurnID: String?

    /// Whether the live WebSocket is connected.
    private var isLive: Bool = false

    /// UI continuation for RuntimeSnapshot stream.
    private var continuation: AsyncStream<RuntimeSnapshot>.Continuation?

    /// Coalescing timer for delta events (16ms debounce).
    private var flushTask: Task<Void, Never>?
    private var pendingFlush: Bool = false

    /// Monotonic snapshot counter for scroll tracking.
    private var generation: UInt64 = 0

    // MARK: - Init

    public init(sessionID: String, mergePolicy: MergePolicy = DefaultMergePolicy()) {
        self.sessionID = sessionID
        self.graph = ExecutionGraph()
        self.reducer = ExecutionReducer()
        self.timelineProjection = TimelineProjection(mergePolicy: mergePolicy)
        self.presenter = ExecutionPresenter()
    }

    // MARK: - Public API

    /// Ingest a v1 AgentEvent from the wire.
    /// Persist → Reduce → Project → Notify UI (coalesced).
    public func ingest(_ event: AgentEvent) {
        // Track pending approval (v1.2 去重：已回复过的 id 忽略)
        if case .approvalRequest(_, let request) = event,
           !resolvedApprovalIDs.contains(request.id) {
            _pendingApproval = request
        }
        // Track plan approval
        if case .planApprovalRequest(_, let plan) = event {
            _pendingPlanApproval = plan
        }
        // Track todos
        if case .todoUpdated(_, let todos) = event {
            _latestTodos = todos
        }
        // Track model started
        if case .modelStarted(_, _) = event {
            _modelStartedAt = Date()
        }
        // Track model stats from model_finished + clear thinking timer
        if case .modelFinished(_, let promptTokens, let completionTokens, let totalTokens,
                               let billingUnits, let elapsedMs, let invocationID, _) = event {
            _modelStartedAt = nil
            if invocationID == nil || countedInvocationIDs.insert(invocationID!).inserted {
                let invocationTokens = totalTokens ?? ((promptTokens ?? 0) + (completionTokens ?? 0))
                var stats = _modelStats ?? ModelStats()
                stats.contextTokens = promptTokens ?? stats.contextTokens
                stats.totalTokens += invocationTokens
                if let billingUnits {
                    stats.usageUnits += billingUnits
                    stats.hasUsageUnits = true
                }
                stats.invocationCount += 1
                stats.elapsedMs += elapsedMs ?? 0
                _modelStats = stats
            }
        }
        // Turn lifecycle: a turn is "active" from turn_started to turn_finished.
        // Drives the live working indicator (and its turn-level timer).
        if case .turnStarted(let turnID, _) = event {
            _pendingApproval = nil
            _modelStats = nil
            countedInvocationIDs.removeAll()
            _modelStartedAt = nil
            _turnStartedAt = Date()
            activeTurnID = turnID
        }
        if case .turnFinished = event {
            _turnStartedAt = nil
            _modelStartedAt = nil
            activeTurnID = nil
        }
        if case .turnPaused = event {
            _turnStartedAt = nil
            _modelStartedAt = nil
        }
        if case .turnFailed = event {
            _turnStartedAt = nil
            _modelStartedAt = nil
            activeTurnID = nil
        }
        if case .turnResumed = event {
            _modelStats = nil
            countedInvocationIDs.removeAll()
            _modelStartedAt = nil
            _turnStartedAt = Date()
        }

        // Reduce into graph
        let _ = reducer.reduce(event, into: &graph)

        // Notify UI — coalesce deltas, immediate for terminal events
        switch event {
        case .tokenDelta, .thinking, .toolStdout, .toolStderr, .jobOutput:
            scheduleFlush()
        default:
            yieldSnapshot()
        }
    }

    /// Import historical events (from HTTP GET /events).
    /// Replays all events through the reducer, then projects the final graph.
    public func importHistory(_ events: [AgentEvent]) {
        for event in events {
            let _ = reducer.reduce(event, into: &graph)

            // Track side-effects that ingest() normally handles:
            // pending approvals (tool + plan) must survive conversation switching
            if case .approvalRequest(_, let request) = event {
                _pendingApproval = request
            }
            if case .planApprovalRequest(_, let plan) = event {
                _pendingPlanApproval = plan
            }
            if case .turnPaused = event {
                _turnStartedAt = nil
                _modelStartedAt = nil
            }
            if case .turnFailed = event {
                _turnStartedAt = nil
                _modelStartedAt = nil
            }
            if case .turnResumed = event {
                _modelStats = nil
                _modelStartedAt = nil
                _turnStartedAt = Date()
            }
            // Clear on resolution (approval nodes in graph track resolved state)
            if case .approvalRequest = event {} // no-op, handled above
        }

        // Scan graph: if approval nodes are resolved, clear pending state
        // If approval was rejected, mark associated running tool nodes as failed
        for node in graph.nodes.values {
            if case .approval(let payload) = node.payload, payload.resolved {
                resolvedApprovalIDs.insert(payload.requestID)
                _pendingApproval = nil
                if payload.approved == false {
                    for (_, var toolNode) in graph.nodes where toolNode.status == .running {
                        if case .toolCall(let tp) = toolNode.payload, tp.toolName == payload.toolName {
                            toolNode.status = .failed
                            graph.upsertNode(toolNode)
                        }
                    }
                }
            }
        }

        // History events reflect past state — they should not block the UI
        // with a pending approval bar. If an approval is genuinely still pending,
        // the server will re-send it through the live stream after reconnect.
        _pendingApproval = nil
        isLive = false
        yieldSnapshot()
    }

    /// Mark the engine as connected to live stream.
    public func markLive() {
        isLive = true
    }

    /// Mark the stream as finished (child streams: terminal event received).
    public func markFinished() {
        isLive = false
        yieldSnapshot()
    }

    /// Get current pending approval (for backward compat with ConversationState).
    public func pendingApproval() -> ApprovalRequest? {
        _pendingApproval
    }

    /// Resolve an approval (called by ViewModel when user approves/rejects).
    public func resolveApproval(requestID: String, approved: Bool) {
        resolvedApprovalIDs.insert(requestID)
        _pendingApproval = nil
        let approvalNodeID = "approval_\(requestID)"
        var rejectedToolName: String?

        graph.updateNode(approvalNodeID) { node in
            if case .approval(var payload) = node.payload {
                payload.resolved = true
                payload.approved = approved
                rejectedToolName = payload.toolName
                node.payload = .approval(payload)
                node.status = .completed
            }
        }

        // When rejected, mark all running tool nodes with matching name as failed.
        // This prevents stuck spinners after switching conversations and replaying history.
        if !approved, let toolName = rejectedToolName {
            for (_, var node) in graph.nodes where node.status == .running {
                if case .toolCall(let p) = node.payload, p.toolName == toolName {
                    node.status = .failed
                    graph.upsertNode(node)
                }
            }
        }

        yieldSnapshot()
    }

    /// Resolve a plan approval.
    public func resolvePlanApproval(requestID: String, approved: Bool) {
        _pendingPlanApproval = nil
        yieldSnapshot()
    }

    /// Create an AsyncStream of RuntimeSnapshots for the UI.
    /// Only one stream per engine instance.
    public nonisolated func stateStream() -> AsyncStream<RuntimeSnapshot> {
        AsyncStream { continuation in
            Task { await self.setContinuation(continuation) }
        }
    }

    /// Get current snapshot (for initial UI read).
    public func currentSnapshot() -> RuntimeSnapshot {
        buildSnapshot()
    }

    /// Apply the local terminal side of cancel_turn. The wire contract permits
    /// the server to stop streaming without emitting turn_finished/turn_failed.
    public func cancelActiveTurn() {
        guard let activeTurnID else { return }
        reducer.cancelActiveTurn(turnID: activeTurnID, graph: &graph)
        self.activeTurnID = nil
        _turnStartedAt = nil
        _modelStartedAt = nil
        _pendingApproval = nil
        _pendingPlanApproval = nil
        yieldSnapshot()
    }

    // MARK: - Private

    private func setContinuation(_ c: AsyncStream<RuntimeSnapshot>.Continuation) {
        continuation = c
    }

    private func buildSnapshot() -> RuntimeSnapshot {
        // Project the graph exactly once per snapshot; timeline and turns
        // both derive from the same node walk.
        let timeline = timelineProjection.projectNodes(graph)
        let turns = timelineProjection.projectTurns(nodes: timeline, isLive: isLive)
        return RuntimeSnapshot(
            timeline: timeline,
            turns: turns,
            pendingApproval: _pendingApproval,
            pendingPlanApproval: _pendingPlanApproval,
            latestTodos: _latestTodos,
            modelStats: _modelStats,
            isLive: isLive,
            generation: generation,
            modelStartedAt: _modelStartedAt,
            turnStartedAt: _turnStartedAt
        )
    }

    private func yieldSnapshot() {
        generation += 1
        let snapshot = buildSnapshot()
        continuation?.yield(snapshot)
        pendingFlush = false
    }

    private func scheduleFlush() {
        guard !pendingFlush else { return }
        pendingFlush = true
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            // 33ms ≈ 30fps coalescing. Indistinguishable from 60fps for text
            // streaming, halves projection + snapshot + render work.
            try? await Task.sleep(nanoseconds: 33_000_000)
            guard let self, await self.pendingFlush else { return }
            await self.yieldSnapshot()
        }
    }

    /// Cancel the flush task on deinit.
    deinit {
        flushTask?.cancel()
        continuation?.finish()
    }
}
