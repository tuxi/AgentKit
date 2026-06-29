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

    /// Flat natural-order timeline (`RuntimeSnapshot.timeline`).
    /// The Turn → Block renderer uses `projectTurns` instead; this stays as a
    /// flat projection for any external consumer. Ordering is structural now —
    /// the old assistant/model_finished reorder hacks are gone.
    public func project(_ graph: ExecutionGraph) -> [ExecutionNode] {
        projectNodes(graph)
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

        // Split into turns at each user prompt (turn_started). `turn_id` is NOT
        // a reliable boundary or identity: a restarted server can reuse the same
        // turn_id within one session, so we cut on the user message and identify
        // each turn by its first node's UNIQUE id (the reducer disambiguates
        // colliding node ids with `_v2`). Keying turns on a colliding turn_id
        // would give ForEach duplicate ids → dropped/reordered/scroll-shuffled.
        var runs: [[ExecutionNode]] = []
        for node in nodes {
            if runs.isEmpty || isUserMessageNode(node) {
                runs.append([node])
            } else {
                runs[runs.count - 1].append(node)
            }
        }

        return runs.enumerated()
            .map { idx, run in buildTurn(nodes: run, isLive: isLive && idx == runs.count - 1) }
            .filter { !$0.isEmpty }
    }

    private func isUserMessageNode(_ node: ExecutionNode) -> Bool {
        if case .message(let p) = node.kind, p.role == .user { return true }
        return false
    }

    private func buildTurn(nodes: [ExecutionNode], isLive: Bool) -> ConversationTurn {
        // Unique, stable id = first node's id (the user node, created once).
        // Never the raw turn_id, which can collide across a server restart.
        let turnUID = nodes.first?.id ?? UUID().uuidString
        var userPrompt: MessageNodePayload?
        var blocks: [TurnBlock] = []
        var pendingTools: [ToolNodePayload] = []
        var footerTokens = 0, footerElapsed = 0, footerCount = 0
        var sawFinished = false

        func flushTools() {
            guard let first = pendingTools.first else { return }
            blocks.append(.toolGroup(ToolGroup(id: first.callID, tools: pendingTools)))
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
                // This agent uses `thinking` events as the assistant's spoken
                // narration between tools ("let me expand each commit…"), not
                // hidden reasoning. Render it as an assistant reply so the turn
                // reads as reply → tool → reply → … → answer (Claude Code style).
                flushTools()
                blocks.append(.text(id: node.id,
                    MessageNodePayload(role: .assistant, text: p.text, isStreaming: p.isStreaming)))
            case .tool(let p):
                // Group only consecutive SAME-NAME tools, so a run renders as
                // "read_file ×4" then "grep" rather than one mixed blob.
                if let last = pendingTools.last, last.toolName != p.toolName {
                    flushTools()
                }
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
        blocks = mergeAdjacentNarration(blocks)

        let footer = sawFinished
            ? TurnStats(promptTokens: footerTokens, elapsedMs: footerElapsed, invocationCount: footerCount)
            : nil
        return ConversationTurn(id: turnUID, userPrompt: userPrompt,
                                blocks: blocks, footer: footer, isLive: isLive)
    }

    /// Collapse adjacent assistant-text blocks when one is a prefix of the other.
    /// The server emits the same narration on both the `thinking` and
    /// `token_delta` channels; without this the conversation shows each reply
    /// twice. Prefix (not just equality) handles the two channels streaming at
    /// different rates — the shorter is folded into the longer, keeping the first
    /// block's identity stable.
    private func mergeAdjacentNarration(_ blocks: [TurnBlock]) -> [TurnBlock] {
        var result: [TurnBlock] = []
        for block in blocks {
            if case .text(_, let p) = block {
                let cur = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cur.isEmpty, let last = result.last, case .text(let lid, let lp) = last {
                    let prev = lp.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !prev.isEmpty, prev.hasPrefix(cur) || cur.hasPrefix(prev) {
                        let longer = cur.count >= prev.count ? p.text : lp.text
                        let streaming = p.isStreaming || lp.isStreaming
                        result[result.count - 1] = .text(id: lid,
                            MessageNodePayload(role: .assistant, text: longer, isStreaming: streaming))
                        continue
                    }
                }
            }
            result.append(block)
        }
        return result
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
