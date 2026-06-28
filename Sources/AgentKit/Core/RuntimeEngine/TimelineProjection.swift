//
//  TimelineProjection.swift
//  AgentKit
//
//  Reads ExecutionGraph → produces flat [ExecutionNode] for chronological UI rendering.
//  MergePolicy is injected — different platforms can merge differently.
//  This is a PURE projection. It does not mutate the graph.
//

import Foundation

// MARK: - TimelineProjection

/// Projects an ExecutionGraph into a chronologically-ordered list of ExecutionNodes.
/// Merge is applied during projection, not during reduction.
public struct TimelineProjection: Sendable {
    public let mergePolicy: MergePolicy

    public init(mergePolicy: MergePolicy = DefaultMergePolicy()) {
        self.mergePolicy = mergePolicy
    }

    /// Project the graph into nodes in **natural (arrival) order**.
    /// Walks .next edges → GraphNode → ExecutionNode → merge adjacent fragments.
    /// Does NOT apply any reorder pass (thinking-first / assistant-to-end /
    /// model_finished) — callers that need structural ordering (the Turn → Block
    /// projection) consume this so text and tools stay interleaved as they arrived.
    public func projectNodes(_ graph: ExecutionGraph) -> [ExecutionNode] {
        let rawNodes = graph.linearWalk().compactMap { projectNode($0) }
        return applyMerge(rawNodes)
    }

    /// Project the graph into a chronological timeline (legacy flat renderer).
    /// = projectNodes → thinking-first → reorder assistant to turn end → reorder
    /// model_finished → merge again (adjacent fragments may now merge).
    public func project(_ graph: ExecutionGraph) -> [ExecutionNode] {
        let thinkOrdered = prioritizeThinking(projectNodes(graph))
        // Assistant before model_finished: if the assistant must be moved to
        // the turn end (live streaming split), do it before model_finished
        // reorder so that the cost summary ends up after its content.
        let asstOrdered = reorderAssistantToTurnEnd(thinkOrdered)
        let modelOrdered = reorderModelFinished(asstOrdered)
        return applyMerge(modelOrdered)
    }

    // MARK: - Turn → Block projection

    /// Fold the natural-order node stream into `[ConversationTurn]`.
    /// One turn per `turnID`; inside a turn, blocks follow arrival order so text
    /// and tools stay interleaved. Lifecycle (`model invoked/finished`) is not a
    /// block — it folds into the turn footer. `isLive` marks the runtime as
    /// streaming; only the last turn is treated as live.
    public func projectTurns(_ graph: ExecutionGraph, isLive: Bool = false) -> [ConversationTurn] {
        let nodes = projectNodes(graph)
        guard !nodes.isEmpty else { return [] }

        // Split into contiguous per-turn runs (empty turnID attaches to current).
        var runs: [(turnID: String, nodes: [ExecutionNode])] = []
        for node in nodes {
            if var last = runs.last, last.turnID == node.turnID || node.turnID.isEmpty {
                last.nodes.append(node)
                runs[runs.count - 1] = last
            } else {
                runs.append((node.turnID, [node]))
            }
        }

        return runs.enumerated().map { idx, run in
            buildTurn(turnID: run.turnID, nodes: run.nodes,
                      isLive: isLive && idx == runs.count - 1)
        }
    }

    private func buildTurn(turnID: String, nodes: [ExecutionNode], isLive: Bool) -> ConversationTurn {
        var userPrompt: MessageNodePayload?
        var blocks: [TurnBlock] = []
        var pendingTools: [ToolNodePayload] = []
        var footerTokens = 0, footerElapsed = 0, footerCount = 0
        var sawFinished = false

        func flushTools() {
            guard let first = pendingTools.first else { return }
            blocks.append(.toolGroup(ToolGroup(id: first.callID, tools: pendingTools,
                                               activeToolCallID: nil)))
            pendingTools.removeAll()
        }

        for node in nodes {
            switch node.kind {
            case .message(let p) where p.role == .user:
                userPrompt = p
            case .message(let p):
                flushTools()
                blocks.append(.text(id: node.id, p))
            case .thinking(let p):
                flushTools()
                blocks.append(.thinking(id: node.id, p))
            case .tool(let p):
                pendingTools.append(p)
            case .artifact(let p):
                flushTools()
                blocks.append(.artifact(id: node.id, p.node))
            case .system(let p):
                if p.kind == .modelActivity, let phase = p.metadata["phase"] {
                    // Model lifecycle → footer / spinner, never a block.
                    if phase == "finished" {
                        sawFinished = true
                        footerCount += 1
                        if let t = p.metadata["promptTokens"], let v = Int(t) { footerTokens = v }
                        if let e = p.metadata["elapsedMs"], let v = Int(e) { footerElapsed += v }
                    }
                } else if p.kind == .contextCompact || p.kind == .skillLoaded {
                    // Demoted meta — not rendered in the main flow for now.
                    break
                } else {
                    // observation / reflection / error / subagent / approval.
                    flushTools()
                    blocks.append(.system(id: node.id, p))
                }
            }
        }
        flushTools()

        // Decide which tool stays expanded, then inject into every group.
        let active = activeToolCallID(in: blocks, isLive: isLive)
        let finalBlocks: [TurnBlock] = blocks.map { block in
            guard case .toolGroup(let g) = block else { return block }
            return .toolGroup(ToolGroup(id: g.id, tools: g.tools, activeToolCallID: active))
        }

        let footer = sawFinished
            ? TurnStats(promptTokens: footerTokens, elapsedMs: footerElapsed, invocationCount: footerCount)
            : nil
        return ConversationTurn(id: turnID, userPrompt: userPrompt,
                                blocks: finalBlocks, footer: footer, isLive: isLive)
    }

    /// The tool that should be expanded in a turn. Live turns only; once the
    /// assistant is answering after the tools (last block is text) → collapse
    /// all; otherwise expand the most recently invoked tool.
    private func activeToolCallID(in blocks: [TurnBlock], isLive: Bool) -> String? {
        guard isLive else { return nil }
        if case .text = blocks.last { return nil }
        for block in blocks.reversed() {
            if case .toolGroup(let g) = block { return g.tools.last?.callID }
        }
        return nil
    }

    /// Convert a single GraphNode to an ExecutionNode.
    private func projectNode(_ graphNode: GraphNode) -> ExecutionNode? {
        let kind: ExecutionNodeKind

        switch graphNode.payload {
        case .userInput(let text):
            kind = .message(MessageNodePayload(role: .user, text: text))

        case .thinking(let text):
            let isStreaming = graphNode.status == .running
            kind = .thinking(ThinkingNodePayload(text: text, isStreaming: isStreaming))

        case .assistantMessage(let text):
            let isStreaming = graphNode.status == .running
            kind = .message(MessageNodePayload(role: .assistant, text: text, isStreaming: isStreaming))

        case .toolCall(let payload):
            let status: ToolNodeStatus = {
                if payload.isAutoApproved { return .autoApproved }
                switch graphNode.status {
                case .running: return .running
                case .completed: return .completed
                case .failed: return .failed
                default: return .completed
                }
            }()
            // Try to compile an artifact
            let artifact = compileArtifact(from: graphNode, payload: payload)
            kind = .tool(ToolNodePayload(
                callID: payload.callID, toolName: payload.toolName,
                args: payload.args, status: status,
                output: payload.output, exitCode: payload.exitCode,
                elapsedMs: payload.elapsedMs,
                isAutoApproved: payload.isAutoApproved, artifact: artifact
            ))

        case .observation(let text):
            kind = .system(SystemNodePayload(kind: .observation, text: text))

        case .reflection(let text):
            kind = .system(SystemNodePayload(kind: .reflection, text: text))

        case .system(let payload):
            let nodeKind: SystemNodeKind = {
                switch payload.kind {
                case .modelActivity: return .modelActivity
                case .contextCompact: return .contextCompact
                case .skillLoaded: return .skillLoaded
                case .error: return .error
                }
            }()
            kind = .system(SystemNodePayload(
                kind: nodeKind, text: payload.text, metadata: payload.metadata
            ))

        case .subagent(let payload):
            // Project subagent as a system node for now
            let text = payload.result.map {
                "Sub-agent: \(payload.prompt) → \($0)"
            } ?? "Sub-agent: \(payload.prompt)"
            kind = .system(SystemNodePayload(kind: .modelActivity, text: text,
                                              metadata: ["type": "subagent", "sessionID": payload.subSessionID]))

        case .approval(let payload):
            let statusText = payload.resolved
                ? (payload.approved == true ? "Approved" : "Rejected")
                : "Awaiting approval"
            let text = "Approval: \(payload.toolName) — \(statusText)"
            kind = .system(SystemNodePayload(kind: .modelActivity, text: text,
                                              metadata: ["type": "approval", "requestID": payload.requestID]))
        }

        return ExecutionNode(
            id: graphNode.id, kind: kind,
            timestamp: graphNode.timestamp, turnID: graphNode.turnID,
            invocationID: graphNode.invocationID
        )
    }

    /// Reuse existing ToolSemanticCompiler to create an ArtifactNode when possible.
    private func compileArtifact(from graphNode: GraphNode,
                                  payload: ToolExecPayload) -> ArtifactNode? {
        guard graphNode.status == .completed || graphNode.status == .failed else { return nil }
        let item = ToolCallItem(
            callID: payload.callID,
            toolName: payload.toolName,
            toolArgs: payload.args
        )
        // Mutate status and result to match graph state
        var mutableItem = item
        mutableItem.status = graphNode.status == .failed ? .failed : .completed
        mutableItem.result = ToolResult(
            callID: payload.callID,
            toolName: payload.toolName,
            observation: payload.output,
            error: graphNode.status == .failed ? payload.output : nil
        )
        return ToolSemanticCompiler.compile(mutableItem, turnID: graphNode.turnID)
    }

    // MARK: - Render priority

    /// Ensure thinking nodes render before assistant message nodes within each turn.
    /// Stable reorder: only swaps when thinking appears after assistant text.
    /// If the server sends events in correct order (thinking first), this is a no-op.
    private func prioritizeThinking(_ nodes: [ExecutionNode]) -> [ExecutionNode] {
        // Indexed stable sort: preserve relative order except for the thinking-before-assistant rule
        var indexed = nodes.enumerated().map { (index: $0.offset, node: $0.element) }
        indexed.sort { a, b in
            // Only reorder within the same turn
            guard a.node.turnID == b.node.turnID else {
                return a.index < b.index
            }
            // thinking nodes should appear before assistant message nodes
            let aIsThinking = isThinkingKind(a.node.kind)
            let bIsThinking = isThinkingKind(b.node.kind)
            let aIsAssistant = isAssistantKind(a.node.kind)
            let bIsAssistant = isAssistantKind(b.node.kind)

            if aIsThinking && bIsAssistant { return true }
            if aIsAssistant && bIsThinking { return false }

            // Preserve original order for all other combinations
            return a.index < b.index
        }
        return indexed.map { $0.node }
    }

    private func isThinkingKind(_ kind: ExecutionNodeKind) -> Bool {
        if case .thinking = kind { return true }
        return false
    }

    private func isAssistantKind(_ kind: ExecutionNodeKind) -> Bool {
        if case .message(let p) = kind, p.role == .assistant { return true }
        return false
    }

    // MARK: - Model-finished reorder

    /// Move `model_finished` to the end of its group so the token-cost
    /// summary renders after the content the model produced.
    ///
    /// When `invocationID` is available (v1.2+), groups are precise.
    /// Falls back to `model_started` boundaries for older servers.
    ///
    /// Before: ▶ → ■ → 🔧 → A
    /// After:  ▶ → 🔧 → A → ■
    private func reorderModelFinished(_ nodes: [ExecutionNode]) -> [ExecutionNode] {
        guard nodes.count > 1 else { return nodes }

        // If any node carries an invocationID, use precise grouping
        let hasInvocationID = nodes.contains(where: { $0.invocationID != nil })
        if hasInvocationID {
            return reorderByInvocationID(nodes)
        }
        // Fallback: group by model_started boundaries
        return reorderByModelStartedBlocks(nodes)
    }

    // MARK: v1.2 precise grouping

    private func reorderByInvocationID(_ nodes: [ExecutionNode]) -> [ExecutionNode] {
        var result: [ExecutionNode] = []
        var group: [ExecutionNode] = []
        var currentInvID: String? = nil

        for node in nodes {
            let invID = node.invocationID
            if invID != currentInvID {
                flushModelFinishedGroup(&group, into: &result)
                currentInvID = invID
            }
            group.append(node)
        }
        flushModelFinishedGroup(&group, into: &result)
        return result
    }

    // MARK: v1.1 fallback grouping

    private func reorderByModelStartedBlocks(_ nodes: [ExecutionNode]) -> [ExecutionNode] {
        var result: [ExecutionNode] = []
        var block: [ExecutionNode] = []

        for node in nodes {
            if isModelStartedNode(node) || isUserMessageNode(node) {
                flushModelFinishedGroup(&block, into: &result)
            }
            block.append(node)
        }
        flushModelFinishedGroup(&block, into: &result)
        return result
    }

    // MARK: helpers

    private func flushModelFinishedGroup(_ group: inout [ExecutionNode], into result: inout [ExecutionNode]) {
        guard !group.isEmpty else { return }
        if let mfIdx = group.firstIndex(where: { isModelFinishedNode($0) }) {
            let mf = group.remove(at: mfIdx)
            group.append(mf)
        }
        result.append(contentsOf: group)
        group.removeAll()
    }

    private func isModelStartedNode(_ node: ExecutionNode) -> Bool {
        if case .system(let p) = node.kind,
           p.kind == .modelActivity,
           p.metadata["phase"] == "started" {
            return true
        }
        return false
    }

    private func isModelFinishedNode(_ node: ExecutionNode) -> Bool {
        if case .system(let p) = node.kind,
           p.kind == .modelActivity,
           p.metadata["phase"] == "finished" {
            return true
        }
        return false
    }

    private func isUserMessageNode(_ node: ExecutionNode) -> Bool {
        if case .message(let p) = node.kind, p.role == .user {
            return true
        }
        return false
    }

    // MARK: - Assistant reorder

    /// Within each turn, move the assistant message node to the end.
    /// During live streaming the first `token_delta` creates the assistant
    /// node early; subsequent model invocations and tools append after it.
    /// This pass ensures the final answer always renders at the bottom.
    ///
    /// Before: U → ▶ → 🔧 → A → ▶ → 🔧   (assistant stuck mid-turn)
    /// After:  U → ▶ → 🔧 → ▶ → 🔧 → A   (assistant at turn end)
    private func reorderAssistantToTurnEnd(_ nodes: [ExecutionNode]) -> [ExecutionNode] {
        var result: [ExecutionNode] = []
        var turnNodes: [ExecutionNode] = []
        var currentTurnID: String? = nil

        for node in nodes {
            if node.turnID != currentTurnID {
                flushTurnToEnd(&turnNodes, into: &result)
                currentTurnID = node.turnID
            }
            turnNodes.append(node)
        }
        flushTurnToEnd(&turnNodes, into: &result)
        return result
    }

    private func flushTurnToEnd(_ turnNodes: inout [ExecutionNode], into result: inout [ExecutionNode]) {
        guard !turnNodes.isEmpty else { return }
        if let asstIdx = turnNodes.firstIndex(where: { isAssistantMessageNode($0) }) {
            let asst = turnNodes.remove(at: asstIdx)
            turnNodes.append(asst)
        }
        result.append(contentsOf: turnNodes)
        turnNodes.removeAll()
    }

    private func isAssistantMessageNode(_ node: ExecutionNode) -> Bool {
        if case .message(let p) = node.kind, p.role == .assistant {
            return true
        }
        return false
    }

    // MARK: - Merge

    private func applyMerge(_ nodes: [ExecutionNode]) -> [ExecutionNode] {
        guard nodes.count > 1 else { return nodes }

        var result: [ExecutionNode] = [nodes[0]]
        for node in nodes.dropFirst() {
            var last = result.removeLast()
            if mergePolicy.shouldMerge(node, with: last) {
                mergePolicy.merge(node, into: &last)
                result.append(last)
            } else {
                result.append(last)
                result.append(node)
            }
        }
        return result
    }
}

// Note: ToolCallItem.status and .result are var, so local mutation works.
// ToolSemanticCompiler.compile is reused as-is from the existing artifact system.
