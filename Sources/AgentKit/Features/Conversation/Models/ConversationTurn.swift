//
//  ConversationTurn.swift
//  AgentKit
//
//  Turn → Block model. A turn renders as one continuous message:
//  user prompt + ordered blocks (text / thinking / tool group) + a footer.
//  Lifecycle events (model invoked/finished) are NOT blocks — they fold into
//  the footer. See docs/conversation_turn_ui_design.md.
//

import Foundation

// MARK: - ConversationTurn

/// One round of conversation: a user prompt and the assistant activity it
/// triggered, presented as a single continuous message.
public struct ConversationTurn: Identifiable, Sendable, Equatable {
    public let id: String                  // = turnID
    public let userPrompt: MessageNodePayload?
    public let blocks: [TurnBlock]
    public let plans: [TurnPlan]
    /// The latest task checklist produced while this turn was active. It is
    /// owned by the turn (not the conversation) so later turns cannot move an
    /// old checklist into a global sticky header.
    public let todos: [TodoItem]
    public let footer: TurnStats?          // nil while no model_finished yet
    public let isLive: Bool                // this turn is still streaming
    /// Per-invocation trajectory: one `ModelInvocation` per model call in this
    /// turn, grouped by `invocation_id` (since v1.4 `model_request`). Empty for
    /// streams that predate the event — the timeline renders exactly as before.
    public let invocations: [ModelInvocation]
    /// Monotonic content version assigned by the incremental projection layer.
    /// Incremented whenever the turn is re-projected with changed content.
    /// `0` means "never projected" (hand-built turns in tests/shares) — Web
    /// consumers treat it as "unknown, fall back to deep equality".
    public let contentVersion: UInt64
    /// Wall-clock start of the turn (`turn_started`). Server-stamped for
    /// replayed history, ingest time for the live stream. Drives the
    /// "used 24分40秒" summary line, not the model-only footer timing.
    public let startedAt: Date?
    /// Wall-clock end of the turn (`turn_finished` / failed / cancelled).
    /// Nil while the turn is still streaming.
    public let finishedAt: Date?
    /// What the turn wrote, as reported by the Runtime on the terminal event.
    /// Nil for turns that wrote nothing, and for every event recorded before
    /// the Runtime started emitting `diffstat` — absence means "unknown", never
    /// "edited 0 files".
    public let changes: TurnChanges?

    public init(id: String, userPrompt: MessageNodePayload?,
                blocks: [TurnBlock], plans: [TurnPlan] = [], todos: [TodoItem] = [],
                footer: TurnStats?, isLive: Bool, invocations: [ModelInvocation] = [],
                contentVersion: UInt64 = 0,
                startedAt: Date? = nil, finishedAt: Date? = nil,
                changes: TurnChanges? = nil) {
        self.id = id
        self.userPrompt = userPrompt
        self.blocks = blocks
        self.plans = plans
        self.todos = todos
        self.footer = footer
        self.isLive = isLive
        self.invocations = invocations
        self.contentVersion = contentVersion
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.changes = changes
    }

    /// Nothing worth rendering — skip (e.g. a stray leading run with only
    /// demoted meta events).
    public var isEmpty: Bool {
        userPrompt == nil && blocks.isEmpty && plans.isEmpty && todos.isEmpty && footer == nil
    }

    /// Returns a copy with an updated content version (content is unchanged).
    /// Used by the incremental projection layer to stamp stable turns.
    public func withContentVersion(_ version: UInt64) -> ConversationTurn {
        ConversationTurn(
            id: id, userPrompt: userPrompt, blocks: blocks, plans: plans,
            todos: todos, footer: footer, isLive: isLive, invocations: invocations,
            contentVersion: version, startedAt: startedAt, finishedAt: finishedAt,
            changes: changes
        )
    }

    // MARK: - Wall clock

    /// Whole seconds the turn occupied, or nil while it is still running / the
    /// timestamps are unknown.
    public var elapsedSeconds: Int? {
        guard let startedAt, let finishedAt else { return nil }
        let interval = finishedAt.timeIntervalSince(startedAt)
        guard interval.isFinite, interval >= 0 else { return nil }
        return max(1, Int(interval.rounded()))
    }

    /// Compact human duration — "48秒" / "24分40秒" / "1小时5分" / "2小时".
    /// Matches the Codex turn summary ("用时 24分40秒").
    public var formattedDuration: String? {
        guard let seconds = elapsedSeconds else { return nil }
        return TurnDurationText.string(seconds: seconds)
    }

    /// `HH:mm` of the moment the turn ended — the timestamp Codex puts under a
    /// completed answer.
    public var finishedAtClock: String? {
        guard let finishedAt else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.hour, .minute], from: finishedAt)
        guard let hour = parts.hour, let minute = parts.minute else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }

    /// Start of the turn as epoch milliseconds. The Web renderer anchors the
    /// live "已处理 …" header on this and ticks it locally, so the number keeps
    /// moving without asking the Runtime for a snapshot every second.
    public var startedAtMilliseconds: Int64? {
        guard let startedAt else { return nil }
        let milliseconds = (startedAt.timeIntervalSince1970 * 1_000).rounded()
        guard milliseconds.isFinite else { return nil }
        return Int64(milliseconds)
    }
}

// MARK: - TurnWallClock

/// Server-stamped wall-clock boundaries of one turn, captured while decoding
/// the wire frames (`turn_started.at` → `turn_finished.at`). Replayed history
/// arrives in a burst, so ingest-time timestamps cannot reproduce the real
/// duration — this is the only faithful source for "用时".
public struct TurnWallClock: Sendable, Equatable {
    public let startedAt: Date?
    public let finishedAt: Date?

    public init(startedAt: Date? = nil, finishedAt: Date? = nil) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var isEmpty: Bool { startedAt == nil && finishedAt == nil }

    /// Merge two observations of the same turn (history page + live stream).
    /// Earliest start and latest end win so a partially observed turn still
    /// reports the widest known span.
    public func merging(_ other: TurnWallClock) -> TurnWallClock {
        TurnWallClock(
            startedAt: Self.earlier(startedAt, other.startedAt),
            finishedAt: Self.later(finishedAt, other.finishedAt)
        )
    }

    private static func earlier(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (let lhs?, let rhs?): return min(lhs, rhs)
        case (let lhs?, nil): return lhs
        case (nil, let rhs?): return rhs
        case (nil, nil): return nil
        }
    }

    private static func later(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (let lhs?, let rhs?): return max(lhs, rhs)
        case (let lhs?, nil): return lhs
        case (nil, let rhs?): return rhs
        case (nil, nil): return nil
        }
    }
}

// MARK: - ModelInvocation

/// One model invocation inside a turn — the DSH-style trajectory unit.
/// Built by `TimelineProjection` by folding `model_request` (request shape) +
/// `thinking` + `model_finished` (usage) on the shared `invocation_id`.
/// `index` is the 1-based arrival order within the turn, so `#3` in the UI
/// maps to the third model call even when `invocation_id` is absent.
public struct ModelInvocation: Identifiable, Sendable, Equatable {
    /// Stable identity = `invocation_id` when present, else "inv\(index)".
    public let id: String
    /// 1-based arrival order within the turn.
    public let index: Int
    /// Request envelope (since v1.4). Nil for streams that predate `model_request`.
    public var request: ModelRequestInfo?
    /// Tools this invocation actually executed, in arrival order, deduplicated.
    /// Aggregated from `tool` nodes stamped with the same `invocation_id`.
    public var executedTools: [String]
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?
    public var billingUnits: Int64?
    public var cachedPromptTokens: Int?
    public var elapsedMs: Int?
    public var err: String?
    /// Authoritative thinking snapshot (latest non-empty `thinking` of this invocation).
    public var thinkingText: String?

    public init(id: String, index: Int, request: ModelRequestInfo? = nil,
                executedTools: [String] = [],
                promptTokens: Int? = nil, completionTokens: Int? = nil,
                totalTokens: Int? = nil, billingUnits: Int64? = nil,
                cachedPromptTokens: Int? = nil, elapsedMs: Int? = nil,
                err: String? = nil, thinkingText: String? = nil) {
        self.id = id
        self.index = index
        self.request = request
        self.executedTools = executedTools
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.billingUnits = billingUnits
        self.cachedPromptTokens = cachedPromptTokens
        self.elapsedMs = elapsedMs
        self.err = err
        self.thinkingText = thinkingText
    }

    /// 4 位可读计数。nil 不显示。
    public var formattedPromptTokens: String { Self.format(promptTokens) }
    public var formattedCompletionTokens: String { Self.format(completionTokens) }
    public var formattedTotalTokens: String { Self.format(totalTokens) }
    public var formattedCachedTokens: String { Self.format(cachedPromptTokens) }

    private static func format(_ value: Int?) -> String {
        guard let value else { return "" }
        return value >= 1000
            ? String(format: "%.1fK", Double(value) / 1000.0)
            : "\(value)"
    }

    public var formattedElapsed: String {
        guard let elapsedMs else { return "" }
        return elapsedMs >= 1000
            ? String(format: "%.1fs", Double(elapsedMs) / 1000.0)
            : "\(elapsedMs)ms"
    }

    /// 一次调用是否已结束（有 usage 或 err）。
    public var isFinished: Bool {
        promptTokens != nil || completionTokens != nil || totalTokens != nil
            || billingUnits != nil || err != nil
    }
}

public struct TurnPlan: Identifiable, Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case pending
        case approved
        case rejected
    }

    public let id: String
    public let requestID: String?
    public let title: String
    public let content: String
    public let status: Status

    public init(id: String, requestID: String? = nil, title: String = "Plan",
                content: String, status: Status) {
        self.id = id
        self.requestID = requestID
        self.title = title
        self.content = content
        self.status = status
    }
}

// MARK: - TurnBlock

/// One ordered block inside a turn. Text can repeat (interleaved with tools).
/// `thinking` blocks carry the model's reasoning/thinking content and render as
/// collapsible cards, distinct from the assistant's spoken reply (`text` blocks).
public enum TurnBlock: Identifiable, Sendable, Equatable {
    case text(id: String, MessageNodePayload)
    case thinking(id: String, ThinkingNodePayload)
    case toolGroup(ToolGroup)
    case artifact(id: String, ArtifactNode)
    case system(id: String, SystemNodePayload)   // observation / reflection / error only
    case childStream(id: String, ChildStreamNodePayload)  // task 子agent / 后台 job 入口卡
    case workflow(id: String, WorkflowNodePayload)        // v1.3 Flux DAG 入口卡

    public var id: String {
        switch self {
        case .text(let id, _): return id
        case .thinking(let id, _): return id
        case .toolGroup(let g): return g.id
        case .artifact(let id, _): return id
        case .system(let id, _): return id
        case .childStream(let id, _): return id
        case .workflow(let id, _): return id
        }
    }
}

// MARK: - ToolGroup

/// A run of consecutive same-name tool calls, rendered as one stable, compact
/// block (eager merge): completed tools fold into a count, the running one shows
/// a single inline status line, details on tap. See ToolGroupView.
public struct ToolGroup: Identifiable, Sendable, Equatable {
    public let id: String                  // = first tool's callID
    public let tools: [ToolNodePayload]

    public init(id: String, tools: [ToolNodePayload]) {
        self.id = id
        self.tools = tools
    }

    /// Collapsed label: "grep" / "read_file ×3".
    public var summary: String {
        guard let first = tools.first else { return "" }
        return tools.count == 1 ? first.toolName : "\(first.toolName) ×\(tools.count)"
    }
}

// MARK: - TurnStats

/// Turn footer: aggregated from the turn's model_finished events.
public struct TurnStats: Sendable, Equatable {
    public let contextTokens: Int          // last invocation's prompt size
    public let totalTokens: Int            // accumulated provider tokens
    public let usageUnits: Int64           // accumulated billed units
    public let hasUsageUnits: Bool
    public let elapsedMs: Int              // summed across invocations
    public let invocationCount: Int
    /// Last invocation's cache-hit tokens (subset of prompt). 0 = no cached
    /// usage reported (pre-v1.4 streams or provider without caching).
    public let cachedContextTokens: Int

    public init(contextTokens: Int, totalTokens: Int, usageUnits: Int64 = 0,
                hasUsageUnits: Bool = false, elapsedMs: Int, invocationCount: Int,
                cachedContextTokens: Int = 0) {
        self.contextTokens = contextTokens
        self.totalTokens = totalTokens
        self.usageUnits = usageUnits
        self.hasUsageUnits = hasUsageUnits
        self.elapsedMs = elapsedMs
        self.invocationCount = invocationCount
        self.cachedContextTokens = cachedContextTokens
    }

    public var formattedContextTokens: String { format(contextTokens) }
    public var formattedTotalTokens: String { format(totalTokens) }
    public var formattedUsageUnits: String { format(usageUnits) }
    public var formattedCachedTokens: String { format(cachedContextTokens) }

    /// 该 turn 是否有可展示的缓存命中（>0 且 <= 上下文）。
    public var hasCachedTokens: Bool { cachedContextTokens > 0 }

    private func format<T: BinaryInteger>(_ value: T) -> String {
        value >= 1000 ? String(format: "%.1fK", Double(value) / 1000.0) : "\(value)"
    }

    public var formattedElapsed: String {
        elapsedMs >= 1000
            ? String(format: "%.1fs", Double(elapsedMs) / 1000.0)
            : "\(elapsedMs)ms"
    }
}
