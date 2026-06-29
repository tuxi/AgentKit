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
public struct ConversationTurn: Identifiable, Sendable {
    public let id: String                  // = turnID
    public let userPrompt: MessageNodePayload?
    public let blocks: [TurnBlock]
    public let footer: TurnStats?          // nil while no model_finished yet
    public let isLive: Bool                // this turn is still streaming

    public init(id: String, userPrompt: MessageNodePayload?,
                blocks: [TurnBlock], footer: TurnStats?, isLive: Bool) {
        self.id = id
        self.userPrompt = userPrompt
        self.blocks = blocks
        self.footer = footer
        self.isLive = isLive
    }
}

// MARK: - TurnBlock

/// One ordered block inside a turn. Text can repeat (interleaved with tools).
/// Note: `thinking` events project into `.text` (assistant narration), so there
/// is no separate thinking block — see TimelineProjection.buildTurn.
public enum TurnBlock: Identifiable, Sendable {
    case text(id: String, MessageNodePayload)
    case toolGroup(ToolGroup)
    case artifact(id: String, ArtifactNode)
    case system(id: String, SystemNodePayload)   // observation / reflection / error only

    public var id: String {
        switch self {
        case .text(let id, _): return id
        case .toolGroup(let g): return g.id
        case .artifact(let id, _): return id
        case .system(let id, _): return id
        }
    }
}

// MARK: - ToolGroup

/// Consecutive tool calls folded into one group. Phase C renders each tool;
/// Phase D collapses to a single `×N` line.
public struct ToolGroup: Identifiable, Sendable {
    public let id: String                  // = first tool's callID
    public let tools: [ToolNodePayload]
    /// The callID the parent wants expanded (read-only, owned by projection).
    public let activeToolCallID: String?

    public init(id: String, tools: [ToolNodePayload], activeToolCallID: String?) {
        self.id = id
        self.tools = tools
        self.activeToolCallID = activeToolCallID
    }

    /// Collapsed label: "grep" / "read_file ×3" / "4 tools".
    public var summary: String {
        guard let first = tools.first else { return "" }
        if tools.count == 1 { return first.toolName }
        let names = Set(tools.map { $0.toolName })
        if names.count == 1 { return "\(first.toolName) ×\(tools.count)" }
        return "\(tools.count) tools"
    }
}

// MARK: - TurnStats

/// Turn footer: aggregated from the turn's model_finished events.
public struct TurnStats: Sendable {
    public let promptTokens: Int           // last invocation's prompt size
    public let elapsedMs: Int              // summed across invocations
    public let invocationCount: Int

    public init(promptTokens: Int, elapsedMs: Int, invocationCount: Int) {
        self.promptTokens = promptTokens
        self.elapsedMs = elapsedMs
        self.invocationCount = invocationCount
    }

    public var formattedTokens: String {
        promptTokens >= 1000
            ? String(format: "%.1fK", Double(promptTokens) / 1000.0)
            : "\(promptTokens)"
    }

    public var formattedElapsed: String {
        elapsedMs >= 1000
            ? String(format: "%.1fs", Double(elapsedMs) / 1000.0)
            : "\(elapsedMs)ms"
    }
}
