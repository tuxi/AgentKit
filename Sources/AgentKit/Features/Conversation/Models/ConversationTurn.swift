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

    public init(id: String, userPrompt: MessageNodePayload?,
                blocks: [TurnBlock], plans: [TurnPlan] = [], todos: [TodoItem] = [],
                footer: TurnStats?, isLive: Bool, invocations: [ModelInvocation] = [],
                contentVersion: UInt64 = 0) {
        self.id = id
        self.userPrompt = userPrompt
        self.blocks = blocks
        self.plans = plans
        self.todos = todos
        self.footer = footer
        self.isLive = isLive
        self.invocations = invocations
        self.contentVersion = contentVersion
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
            contentVersion: version
        )
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
