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
    public let pendingApproval: ApprovalRequest? // 保留兼容：取队列第一个
    public let pendingApprovals: [ApprovalRequest]  // 新增：完整审批队列
    public let pendingPlanApproval: PlanApprovalRequest?
    public let pendingAskUser: AskUserRequest?  // 保留兼容：取队列第一个
    public let pendingAskUsers: [AskUserRequest]  // 完整 ask_user 队列
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
    /// Latest plan state-machine state (`plan_state_changed`). `.none` when no
    /// plan is in progress.
    public let planState: PlanState
    /// Active model retry state (ephemeral, live-only).
    public let modelRetrying: ModelRetryState?
  
    public init(timeline: [ExecutionNode],
                turns: [ConversationTurn] = [],
                pendingApprovals: [ApprovalRequest] = [],
                pendingPlanApproval: PlanApprovalRequest? = nil,
                pendingAskUsers: [AskUserRequest] = [],
                latestTodos: [TodoItem] = [],
                modelStats: ModelStats? = nil,
                isLive: Bool = false,
                generation: UInt64 = 0,
                modelStartedAt: Date? = nil,
                turnStartedAt: Date? = nil,
                planState: PlanState = .none,
                modelRetrying: ModelRetryState? = nil) {
        self.timeline = timeline
        self.turns = turns
        self.pendingApproval = pendingApprovals.first
        self.pendingApprovals = pendingApprovals
        self.pendingPlanApproval = pendingPlanApproval
        self.pendingAskUser = pendingAskUsers.first
        self.pendingAskUsers = pendingAskUsers
        self.latestTodos = latestTodos
        self.modelStats = modelStats
        self.isLive = isLive
        self.generation = generation
        self.modelStartedAt = modelStartedAt
        self.turnStartedAt = turnStartedAt
        self.planState = planState
        self.modelRetrying = modelRetrying
    }

    /// Empty snapshot for initial state.
    public static func empty(sessionID: String) -> RuntimeSnapshot {
        RuntimeSnapshot(timeline: [])
    }
}

/// Active model retry state (ephemeral, live-only).
public struct ModelRetryState: Sendable, Equatable, Codable {
    public let attempt: Int
    public let maxAttempts: Int
    public let retryDelayMs: Int
    public let retryFallback: Bool
    public let err: String?
    public let invocationID: String?
    /// When this retry sequence started (epoch ms). JSON-friendly for Web bridge.
    public let startedAtMilliseconds: Int64
    
    public init(attempt: Int, maxAttempts: Int, retryDelayMs: Int, retryFallback: Bool, err: String?, invocationID: String?, startedAtMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.retryDelayMs = retryDelayMs
        self.retryFallback = retryFallback
        self.err = err
        self.invocationID = invocationID
        self.startedAtMilliseconds = startedAtMilliseconds
    }
    
    public var progress: Double { Double(attempt) / Double(maxAttempts) }
    public var isFallback: Bool { retryFallback }
    public var delaySeconds: Double { Double(retryDelayMs) / 1000.0 }
    /// Total elapsed time since first retry attempt.
    public var elapsed: TimeInterval {
        Date().timeIntervalSince1970 - Double(startedAtMilliseconds) / 1000.0
    }
    /// Convenience Date for SwiftUI consumers.
    public var startedAt: Date {
        Date(timeIntervalSince1970: Double(startedAtMilliseconds) / 1000.0)
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
    /// Incremental turn projection cache. Re-projects only changed turns so
    /// per-event cost scales with the change, not the whole conversation.
    private var projectionCache: TurnProjectionCache
    /// Older pages live outside the streaming graph so a prepend cannot reset
    /// live node revisions, content versions, or the forward replay cursor.
    private var olderEvents: [AgentEvent] = []
    /// A hard page limit can cut through the oldest tail turn. Keep the tail
    /// fragment so it can be replayed with its `turn_started` from an older page.
    private var leadingTailEvents: [AgentEvent] = []
    private var capturesLeadingTail = false
    private var firstFullTailTurnID: String?
    private var hasRejoinedLeadingTurn = false
    private var olderGraph = ExecutionGraph()
    private var olderReducer = ExecutionReducer()
    private var olderProjectionCache: TurnProjectionCache
    private var olderTimeline: [ExecutionNode] = []
    private var olderTurns: [ConversationTurn] = []

    /// Pending approval queue. Order reflects arrival order from the server;
    /// the protocol guarantees serial tool execution, so concurrent approvals
    /// are not expected. First-in-first-out via `pendingApproval()`.
    private var _pendingApprovals: [ApprovalRequest] = []

    /// v1.2 三态审批去重：已回复过的审批请求 ID（重连后直接忽略）。
    private var resolvedApprovalIDs: Set<String> = []

    /// Pending plan approval (Plan Mode).
    private var _pendingPlanApproval: PlanApprovalRequest?

    /// Pending ask_user queue. Dictionary keyed by request.id for O(1) dedup.
    /// Model may call ask_user multiple times in one turn.
    private var _pendingAskUsers: [String: AskUserRequest] = [:]

    /// ask_user 去重：已回复过的请求 ID（重连后直接忽略）。
    private var resolvedAskUserIDs: Set<String> = []

    /// Latest todo list from the agent.
    private var _latestTodos: [TodoItem] = []
    private struct PendingTodoToolUpdate {
        let turnID: String?
        let items: [TodoItem]
        let canonicalRevisionAtStart: UInt64
    }
    private var pendingTodoToolUpdates: [String: PendingTodoToolUpdate] = [:]
    private var canonicalTodoRevision: UInt64 = 0

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

    /// Latest plan state-machine state (`plan_state_changed`).
    private var _planState: PlanState = .none
    /// Active model retry state (ephemeral, live-only).
    private var _modelRetryState: ModelRetryState?

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
        self.projectionCache = TurnProjectionCache(mergePolicy: mergePolicy)
        self.olderProjectionCache = TurnProjectionCache(mergePolicy: mergePolicy)
    }

    // MARK: - Public API

    /// Ingest a v1 AgentEvent from the wire.
    /// Persist → Reduce → Project → Notify UI (coalesced).
    public func ingest(_ event: AgentEvent) {
        if capturesLeadingTail {
            if case .turnStarted = event {
                capturesLeadingTail = false
                if firstFullTailTurnID == nil,
                   case .turnStarted(let turnID, _, _, _) = event {
                    firstFullTailTurnID = "turn_\(turnID)_user"
                }
            } else {
                leadingTailEvents.append(event)
                if !olderEvents.isEmpty {
                    _ = olderReducer.reduce(event, into: &olderGraph)
                    let projected = olderProjectionCache.project(graph: &olderGraph, isLive: isLive)
                    olderTimeline = projected.timeline
                    olderTurns = projected.turns
                }
                if Self.isTurnTerminal(event) { capturesLeadingTail = false }
            }
        }
        // Track pending approval (v1.2 去重：已回复过的 id 忽略)
        if case .approvalRequest(_, let request) = event,
           !resolvedApprovalIDs.contains(request.id) {
            _pendingApprovals.append(request)
        }
        // Track plan approval
        if case .planApprovalRequest(_, let plan) = event {
            _pendingPlanApproval = plan
        }
        if case .planApproved = event { _pendingPlanApproval = nil }
        if case .planRejected = event { _pendingPlanApproval = nil }
        // Track latest plan state-machine state
        if case .planStateChanged(let planState) = event {
            _planState = planState
        }
        // Track ask_user (dedup: skip already resolved IDs)
        if case .askUserRequest(_, let request) = event,
           !resolvedAskUserIDs.contains(request.id) {
            _pendingAskUsers[request.id] = request
        }
        let todoFallback = trackTodoState(event)
        // Track model started
        if case .modelStarted(_, _) = event {
            _modelStartedAt = Date()
        }
        // Track model retrying (ephemeral, live-only)
        if case .modelRetrying(_, let invocationID, let attempt, let maxAttempts,
                               let retryDelayMs, let retryFallback, let err) = event {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            if attempt == 1 {
                _modelRetryState = ModelRetryState(
                    attempt: attempt, maxAttempts: maxAttempts,
                    retryDelayMs: retryDelayMs, retryFallback: retryFallback,
                    err: err, invocationID: invocationID,
                    startedAtMilliseconds: nowMs
                )
            } else {
                // Subsequent retry — preserve original start time if available,
                // otherwise use now (handles reconnect mid-retry).
                let startedAt = _modelRetryState?.startedAtMilliseconds ?? nowMs
                _modelRetryState = ModelRetryState(
                    attempt: attempt, maxAttempts: maxAttempts,
                    retryDelayMs: retryDelayMs, retryFallback: retryFallback,
                    err: err, invocationID: invocationID,
                    startedAtMilliseconds: startedAt
                )
            }
        }
        // Track model stats from model_finished + clear thinking timer + clear retry state
        if case .modelFinished(_, let promptTokens, let completionTokens, let totalTokens,
                               let billingUnits, let elapsedMs, let invocationID, _, _) = event {
            _modelStartedAt = nil
            _modelRetryState = nil  // Clear retry state on model finish (success)
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
        if case .turnStarted(let turnID, _, _, _) = event {
            _pendingApprovals.removeAll()
            _pendingAskUsers.removeAll()
            _modelStats = nil
            countedInvocationIDs.removeAll()
            _modelStartedAt = nil
            _turnStartedAt = Date()
            activeTurnID = turnID
        }
        if case .turnFinished = event {
            _turnStartedAt = nil
            _modelStartedAt = nil
            _modelRetryState = nil
            activeTurnID = nil
        }
        if case .turnPaused = event {
            _turnStartedAt = nil
            _modelStartedAt = nil
            _modelRetryState = nil
        }
        if case .turnFailed = event {
            _turnStartedAt = nil
            _modelStartedAt = nil
            _modelRetryState = nil
            activeTurnID = nil
        }
        if case .turnCancelled = event {
            _turnStartedAt = nil
            _modelStartedAt = nil
            _modelRetryState = nil
            _pendingApprovals.removeAll()
            _pendingPlanApproval = nil
            _pendingAskUsers.removeAll()
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
        if let todoFallback {
            let _ = reducer.reduce(todoFallback, into: &graph)
        }

        // Notify UI — coalesce deltas, immediate for terminal events.
        // `thinking` is a terminal complete snapshot, not a delta — yield immediately.
        // `reasoningDelta` is coalesced like `tokenDelta` for smooth streaming.
        switch event {
        case .tokenDelta, .reasoningDelta, .toolStdout, .toolStderr, .jobOutput,
             .workflowNodeProgress, .workflowTaskProgress, .workflowToolProgress,
             .workflowToolLog, .workflowToolStream:
            scheduleFlush()
        default:
            yieldSnapshot()
        }
    }

    /// Import historical events (from HTTP GET /events).
    /// Replays all events through the reducer, then projects the final graph.
    public func importHistory(_ events: [AgentEvent]) {
        leadingTailEvents = Array(events.prefix { event in
            if case .turnStarted = event { return false }
            return true
        })
        capturesLeadingTail = !leadingTailEvents.isEmpty
            && leadingTailEvents.count == events.count
            && !leadingTailEvents.contains(where: Self.isTurnTerminal)
        firstFullTailTurnID = events.compactMap { event -> String? in
            if case .turnStarted(let turnID, _, _, _) = event {
                return "turn_\(turnID)_user"
            }
            return nil
        }.first
        _latestTodos = []
        pendingTodoToolUpdates.removeAll()
        canonicalTodoRevision = 0
        for event in events {
            let todoFallback = trackTodoState(event)
            let _ = reducer.reduce(event, into: &graph)
            if let todoFallback {
                let _ = reducer.reduce(todoFallback, into: &graph)
            }

            // Track side-effects that ingest() normally handles:
            // pending approvals (tool + plan) must survive conversation switching
            if case .approvalRequest(_, let request) = event,
               !resolvedApprovalIDs.contains(request.id) {
                _pendingApprovals.append(request)
            }
            if case .planApprovalRequest(_, let plan) = event {
                _pendingPlanApproval = plan
            }
            if case .planApproved = event { _pendingPlanApproval = nil }
            if case .planRejected = event { _pendingPlanApproval = nil }
            if case .askUserRequest(_, let request) = event,
               !resolvedAskUserIDs.contains(request.id) {
                _pendingAskUsers[request.id] = request
            }
            if case .turnPaused = event {
                _turnStartedAt = nil
                _modelStartedAt = nil
                _modelRetryState = nil
            }
            if case .turnFailed = event {
                _turnStartedAt = nil
                _modelStartedAt = nil
                _modelRetryState = nil
            }
            if case .turnCancelled = event {
                _turnStartedAt = nil
                _modelStartedAt = nil
                _modelRetryState = nil
                _pendingApprovals.removeAll()
                _pendingPlanApproval = nil
                _pendingAskUsers.removeAll()
                activeTurnID = nil
            }
            if case .turnResumed = event {
                _modelStats = nil
                _modelStartedAt = nil
                _modelRetryState = nil
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
                _pendingApprovals.removeAll { $0.id == payload.requestID }
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
        _pendingApprovals.removeAll()
        _pendingAskUsers.removeAll()
        isLive = false
        yieldSnapshot()
    }

    /// Prepend a turn-aligned page. Rebuild only the historical prefix; the
    /// streaming graph and its incremental projection cache remain untouched.
    public func importOlderHistory(_ events: [AgentEvent]) {
        guard !events.isEmpty else { return }
        olderEvents.insert(contentsOf: events, at: 0)
        if !leadingTailEvents.isEmpty,
           let start = olderEvents.lastIndex(where: { event in
               if case .turnStarted = event { return true }
               return false
           }) {
            hasRejoinedLeadingTurn = !olderEvents.suffix(from: olderEvents.index(after: start))
                .contains(where: Self.isTurnTerminal)
        }
        olderGraph = ExecutionGraph()
        olderReducer = ExecutionReducer()
        olderProjectionCache = TurnProjectionCache(mergePolicy: timelineProjection.mergePolicy)
        for event in olderEvents + leadingTailEvents {
            _ = olderReducer.reduce(event, into: &olderGraph)
        }
        let projected = olderProjectionCache.project(graph: &olderGraph, isLive: isLive && capturesLeadingTail)
        olderTimeline = projected.timeline
        olderTurns = projected.turns
        yieldSnapshot()
    }

    private static func isTurnTerminal(_ event: AgentEvent) -> Bool {
        switch event {
        case .turnFinished, .turnFailed, .turnCancelled: return true
        default: return false
        }
    }

    /// `todo_updated` is authoritative. A successful Todo tool call is used
    /// only when no canonical update arrived while that call was executing.
    private func trackTodoState(_ event: AgentEvent) -> AgentEvent? {
        switch event {
        case .todoUpdated(_, let todos):
            canonicalTodoRevision &+= 1
            _latestTodos = todos
            return nil

        case .toolStarted(let turnID, let callID, let tool):
            guard let items = TodoToolPayload.items(
                toolName: tool.toolName,
                arguments: tool.toolArgs
            ) else { return nil }
            pendingTodoToolUpdates[callID] = PendingTodoToolUpdate(
                turnID: turnID,
                items: items,
                canonicalRevisionAtStart: canonicalTodoRevision
            )
            return nil

        case .toolFinished(_, let callID, let result):
            guard let pending = pendingTodoToolUpdates.removeValue(forKey: callID),
                  result.error?.isEmpty ?? true,
                  pending.canonicalRevisionAtStart == canonicalTodoRevision else { return nil }
            _latestTodos = pending.items
            return .todoUpdated(turnID: pending.turnID, todos: pending.items)

        case .turnFinished, .turnFailed, .turnCancelled:
            pendingTodoToolUpdates.removeAll()
            return nil

        default:
            return nil
        }
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
        _pendingApprovals.first
    }

    /// Resolve an approval (called by ViewModel when user approves/rejects).
    public func resolveApproval(requestID: String, approved: Bool) {
        resolvedApprovalIDs.insert(requestID)
        _pendingApprovals.removeAll { $0.id == requestID }
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
        if let plan = _pendingPlanApproval, plan.id == requestID {
            let resolution: AgentEvent = approved
                ? .planApproved(turnID: plan.turnId, planID: plan.planID)
                : .planRejected(turnID: plan.turnId, planID: plan.planID)
            let _ = reducer.reduce(resolution, into: &graph)
        }
        _pendingPlanApproval = nil
        yieldSnapshot()
    }

    /// Resolve an ask_user request.
    public func resolveAskUser(requestID: String) {
        resolvedAskUserIDs.insert(requestID)
        _pendingAskUsers.removeValue(forKey: requestID)
        yieldSnapshot()
    }

    /// Get current pending ask_user request (for backward compat).
    public func pendingAskUserRequest() -> AskUserRequest? {
        _pendingAskUsers.values.first
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
        _modelRetryState = nil
        _pendingApprovals.removeAll()
        _pendingPlanApproval = nil
        _pendingAskUsers.removeAll()
        yieldSnapshot()
    }

    // MARK: - Private

    private func setContinuation(_ c: AsyncStream<RuntimeSnapshot>.Continuation) {
        continuation = c
    }

    private func buildSnapshot() -> RuntimeSnapshot {
        // Project the graph incrementally — only turns touched since the last
        // yield are re-projected; unchanged turns keep their cached values and
        // content versions. This makes per-event cost scale with the change
        // rather than the whole conversation.
        let (timeline, turns) = projectionCache.project(graph: &graph, isLive: isLive)
        let prefixTurnIDs = Set(olderTurns.map(\.id))
        let joinedLiveTurns: [ConversationTurn]
        if hasRejoinedLeadingTurn {
            if let firstFullTailTurnID,
               let first = turns.firstIndex(where: { $0.id == firstFullTailTurnID }) {
                joinedLiveTurns = Array(turns[first...])
            } else if firstFullTailTurnID == nil {
                joinedLiveTurns = []
            } else {
                joinedLiveTurns = turns
            }
        } else {
            joinedLiveTurns = turns
        }
        let uniqueLiveTurns = joinedLiveTurns.filter { !prefixTurnIDs.contains($0.id) }
        let prefixRawTurnIDs = Set(olderTimeline.map(\.turnID).filter { !$0.isEmpty })
        return RuntimeSnapshot(
            timeline: olderTimeline + timeline.filter { !prefixRawTurnIDs.contains($0.turnID) },
            turns: olderTurns + uniqueLiveTurns,
            pendingApprovals: _pendingApprovals,
            pendingPlanApproval: _pendingPlanApproval,
            pendingAskUsers: Array(_pendingAskUsers.values),
            latestTodos: _latestTodos,
            modelStats: _modelStats,
            isLive: isLive,
            generation: generation,
            modelStartedAt: _modelStartedAt,
            turnStartedAt: _turnStartedAt,
            planState: _planState,
            modelRetrying: _modelRetryState
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
