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
        projectTurns(nodes: projectNodes(graph), isLive: isLive)
    }

    /// Same as `projectTurns(_:isLive:)` but takes already-projected nodes,
    /// so callers that also need the flat timeline walk the graph only once.
    public func projectTurns(nodes: [ExecutionNode], isLive: Bool = false) -> [ConversationTurn] {
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
        var plans: [TurnPlan] = []
        var todos: [TodoItem] = []
        var contextTokens = 0, totalTokens = 0, usageUnits: Int64 = 0, footerElapsed = 0, footerCount = 0
        var hasUsageUnits = false
        var seenInvocationIDs: Set<String> = []
        var sawFinished = false

        // P8.7 ①：同一次委派/启动会同时出现工具卡和 childStream 入口卡——
        //   task：`task` 工具卡（tool_started/finished） + task_started/finished bracket
        //   job：`run_command(background)` 工具卡 + job_started/finished bracket
        // 合并：入口卡为准，隐藏发起它的那张工具卡。用 `call_id` 关联（bracket 与工具卡
        // 共享，服务端 stamp，跨 live/回放稳定），比按 prompt 字符串更稳、多个同 prompt
        // 委派不退化。前台 `run_command`（无 job）call_id 不在此集合里，卡片照常保留。
        let entryCardCallIDs: Set<String> = Set(
            nodes.compactMap { node -> String? in
                guard case .childStream(let p) = node.kind else { return nil }
                return p.originCallID
            }
        )

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
                // Model reasoning/thinking content — a separate collapsible card,
                // NOT assistant narration. Distinct from the spoken reply (text).
                flushTools()
                blocks.append(.thinking(id: node.id, p))
            case .tool(let p):
                // `propose_plan` has a dedicated semantic Plan node. Keeping
                // its raw tool row would show the same proposal twice.
                let semanticToolName = p.toolName
                    .lowercased()
                    .replacingOccurrences(of: "-", with: "_")
                if semanticToolName == "propose_plan" {
                    continue
                }
                // 隐藏发起了子流入口卡的那张工具卡（详情在入口卡 → 子流查看器里看）。
                if entryCardCallIDs.contains(p.callID) {
                    continue
                }
                // Group only consecutive SAME-NAME tools, so a run renders as
                // "read_file ×4" then "grep" rather than one mixed blob.
                if let last = pendingTools.last, last.toolName != p.toolName {
                    flushTools()
                }
                pendingTools.append(p)
            case .artifact(let p):
                flushTools()
                blocks.append(.artifact(id: node.id, p.node))
            case .childStream(let p):
                // 子流入口卡：内嵌在 turn card 中的折叠卡片（Claude Code 式）。
                flushTools()
                blocks.append(.childStream(id: node.id, p))
            case .todo(let items):
                // A checklist is the state summary for its owning turn. Keep
                // only the latest revision and render it at that turn's bottom.
                todos = items
            case .plan(let plan):
                flushTools()
                if let index = plans.firstIndex(where: { $0.id == plan.id }) {
                    plans[index] = plan
                } else {
                    plans.append(plan)
                }
            case .system(let p):
                if p.kind == .modelActivity, let phase = p.metadata["phase"] {
                    // Model lifecycle → footer / spinner, never a block.
                    if phase == "finished" {
                        if let invocationID = p.metadata["invocationID"],
                           !seenInvocationIDs.insert(invocationID).inserted {
                            continue
                        }
                        sawFinished = true
                        footerCount += 1
                        let prompt = p.metadata["promptTokens"].flatMap(Int.init)
                        let completion = p.metadata["completionTokens"].flatMap(Int.init) ?? 0
                        contextTokens = prompt ?? contextTokens
                        totalTokens += p.metadata["totalTokens"].flatMap(Int.init) ?? ((prompt ?? 0) + completion)
                        if let units = p.metadata["billingUnits"].flatMap(Int64.init) {
                            usageUnits += units
                            hasUsageUnits = true
                        }
                        if let e = p.metadata["elapsedMs"], let v = Int(e) { footerElapsed += v }
                    }
                } else if p.kind == .modelActivity,
                          p.metadata["type"] == "todos" || p.metadata["type"] == "approval" {
                    // todos → projected through RuntimeSnapshot.latestTodos.
                    // approval → approval bar is the canonical UI; don't render
                    // a redundant "[modelActivity] Approval: …" system block.
                    break
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
            ? TurnStats(contextTokens: contextTokens, totalTokens: totalTokens, usageUnits: usageUnits,
                        hasUsageUnits: hasUsageUnits, elapsedMs: footerElapsed, invocationCount: footerCount)
            : nil
        return ConversationTurn(id: turnUID, userPrompt: userPrompt,
                                blocks: blocks, plans: plans, todos: todos,
                                footer: footer, isLive: isLive)
    }

    /// Collapse adjacent assistant-text blocks when one is a prefix of the other.
    /// Handles the case where `token_delta` and `turn_finished` (or replayed
    /// deltas) deliver overlapping text at different rates — the shorter is
    /// folded into the longer, keeping the first block's identity stable.
    /// Note: `thinking` blocks carry reasoning (different from assistant text),
    /// so they no longer participate in this merge.
    private func mergeAdjacentNarration(_ blocks: [TurnBlock]) -> [TurnBlock] {
        var result: [TurnBlock] = []
        for block in blocks {
            if case .text(_, let p) = block {
                let cur = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cur.isEmpty, let last = result.last, case .text(let lid, let lp) = last {
                    let prev = lp.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !prev.isEmpty, prev.hasPrefix(cur) || cur.hasPrefix(prev) {
                        let useCurrent = cur.count >= prev.count
                        let longer = useCurrent ? p.text : lp.text
                        let annotations = useCurrent ? p.textAnnotations : lp.textAnnotations
                        let streaming = p.isStreaming || lp.isStreaming
                        result[result.count - 1] = .text(id: lid,
                            MessageNodePayload(
                                role: .assistant,
                                text: longer,
                                isStreaming: streaming,
                                textAnnotations: annotations
                            ))
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
        var kind: ExecutionNodeKind?

        switch graphNode.payload {
        case .userInput(let payload):
            kind = .message(MessageNodePayload(
                role: .user,
                text: payload.text,
                userAssets: payload.userAssets
            ))

        case .thinking(let text):
            let isStreaming = graphNode.status == .running
            kind = .thinking(ThinkingNodePayload(text: text, isStreaming: isStreaming))

        case .assistantMessage(let text, let textAnnotations):
            let isStreaming = graphNode.status == .running
            kind = .message(MessageNodePayload(
                role: .assistant,
                text: text,
                isStreaming: isStreaming,
                textAnnotations: textAnnotations
            ))

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
                output: payload.output,
                structuredOutput: payload.structuredOutput,
                assets: payload.assets,
                exitCode: payload.exitCode,
                elapsedMs: payload.elapsedMs,
                isAutoApproved: payload.isAutoApproved, artifact: artifact
            ))

        case .observation:
            // agent的观测信息不显示，因为工具本身的output有显示了，这里重叠了
            break

        case .reflection(let text):
            kind = .system(SystemNodePayload(kind: .reflection, text: text))

        case .system(let payload):
            if payload.kind == .modelActivity,
               payload.metadata["type"] == "approval" {
                break // 不生成 TurnBlock，屏蔽啰嗦的：modelActivity Approval: run_command — Approved
            }
            let nodeKind: SystemNodeKind = {
                switch payload.kind {
                case .modelActivity:
                    return .modelActivity
                case .contextCompact: return .contextCompact
                case .skillLoaded: return .skillLoaded
                case .error: return .error
                }
            }()
            kind = .system(SystemNodePayload(
                kind: nodeKind, text: payload.text, metadata: payload.metadata
            ))

        case .childStream(let payload):
            let status: ChildStreamNodeStatus = {
                if payload.canceled { return .canceled }
                switch graphNode.status {
                case .running: return .running
                case .failed: return .failed
                default: return .completed
                }
            }()
            kind = .childStream(ChildStreamNodePayload(
                kind: payload.kind, childID: payload.childID, title: payload.title,
                status: status, originCallID: payload.originCallID, result: payload.result,
                exitCode: payload.exitCode, elapsedMs: payload.elapsedMs,
                output: payload.output
            ))

        case .approval(let payload):
//            if payload.approved == true {
//                break // 已授权同意的权限不现实Approved，只显示Rejected
//            }
            let statusText = payload.resolved
                ? (payload.approved == true ? "Approved" : "Rejected")
                : "Awaiting approval"
            let text = "Approval: \(payload.toolName) — \(statusText)"
            kind = .system(SystemNodePayload(kind: .modelActivity, text: text,
                                              metadata: ["type": "approval", "requestID": payload.requestID]))

        case .todo(let items):
            kind = .todo(items)

        case .plan(let payload):
            kind = .plan(TurnPlan(
                id: payload.planID,
                requestID: payload.requestID,
                title: payload.title,
                content: payload.content,
                status: payload.status
            ))
        }

        guard let kind else { return nil }
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
