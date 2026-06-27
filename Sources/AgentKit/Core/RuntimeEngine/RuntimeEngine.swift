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
public struct RuntimeSnapshot: Sendable {
    public let graph: ExecutionGraph
    public let timeline: [ExecutionNode]
    public let pendingApproval: ApprovalRequest?
    public let pendingPlanApproval: PlanApprovalRequest?
    public let latestTodos: [TodoItem]
    /// Token & timing from the most recent model_finished event.
    public let modelStats: ModelStats?
    public let isLive: Bool

    public init(graph: ExecutionGraph, timeline: [ExecutionNode],
                pendingApproval: ApprovalRequest? = nil,
                pendingPlanApproval: PlanApprovalRequest? = nil,
                latestTodos: [TodoItem] = [],
                modelStats: ModelStats? = nil,
                isLive: Bool = false) {
        self.graph = graph
        self.timeline = timeline
        self.pendingApproval = pendingApproval
        self.pendingPlanApproval = pendingPlanApproval
        self.latestTodos = latestTodos
        self.modelStats = modelStats
        self.isLive = isLive
    }

    /// Empty snapshot for initial state.
    public static func empty(sessionID: String) -> RuntimeSnapshot {
        RuntimeSnapshot(graph: ExecutionGraph(), timeline: [])
    }
}

/// Token & timing statistics from a model invocation.
public struct ModelStats: Sendable {
    public let promptTokens: Int
    public let elapsedMs: Int

    public var formattedTokens: String {
        if promptTokens >= 1000 {
            String(format: "%.1fK", Double(promptTokens) / 1000.0)
        } else {
            "\(promptTokens)"
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

    /// Pending plan approval (Plan Mode).
    private var _pendingPlanApproval: PlanApprovalRequest?

    /// Latest todo list from the agent.
    private var _latestTodos: [TodoItem] = []

    /// Stats from the most recent model_finished event.
    private var _modelStats: ModelStats?

    /// Whether the live WebSocket is connected.
    private var isLive: Bool = false

    /// UI continuation for RuntimeSnapshot stream.
    private var continuation: AsyncStream<RuntimeSnapshot>.Continuation?

    /// Coalescing timer for delta events (50ms debounce).
    private var flushTask: Task<Void, Never>?
    private var pendingFlush: Bool = false

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
        // Track pending approval
        if case .approvalRequest(_, let request) = event {
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
        // Track model stats from model_finished
        if case .modelFinished(_, let promptTokens, let elapsedMs, _) = event {
            if let tokens = promptTokens, let ms = elapsedMs, tokens > 0 || ms > 0 {
                _modelStats = ModelStats(promptTokens: tokens, elapsedMs: ms)
            }
        }
        // Clear per-turn state on turn boundary
        if case .turnStarted = event {
            _pendingApproval = nil
            _modelStats = nil
        }

        // Reduce into graph
        let _ = reducer.reduce(event, into: &graph)

        // Notify UI — coalesce deltas, immediate for terminal events
        switch event {
        case .tokenDelta, .thinking, .toolStdout, .toolStderr:
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
        }
        isLive = false
        yieldSnapshot()
    }

    /// Mark the engine as connected to live stream.
    public func markLive() {
        isLive = true
    }

    /// Get current pending approval (for backward compat with ConversationState).
    public func pendingApproval() -> ApprovalRequest? {
        _pendingApproval
    }

    /// Resolve an approval (called by ViewModel when user approves/rejects).
    public func resolveApproval(requestID: String, approved: Bool) {
        _pendingApproval = nil
        let nodeID = "approval_\(requestID)"
        graph.updateNode(nodeID) { node in
            if case .approval(var payload) = node.payload {
                payload.resolved = true
                payload.approved = approved
                node.payload = .approval(payload)
                node.status = .completed
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

    // MARK: - Private

    private func setContinuation(_ c: AsyncStream<RuntimeSnapshot>.Continuation) {
        continuation = c
    }

    private func buildSnapshot() -> RuntimeSnapshot {
        let timeline = timelineProjection.project(graph)
        return RuntimeSnapshot(
            graph: graph,
            timeline: timeline,
            pendingApproval: _pendingApproval,
            pendingPlanApproval: _pendingPlanApproval,
            latestTodos: _latestTodos,
            modelStats: _modelStats,
            isLive: isLive
        )
    }

    private func yieldSnapshot() {
        let snapshot = buildSnapshot()
        continuation?.yield(snapshot)
        pendingFlush = false
    }

    private func scheduleFlush() {
        guard !pendingFlush else { return }
        pendingFlush = true
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 16_000_000) // 16ms ≈ 60fps debounce
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
