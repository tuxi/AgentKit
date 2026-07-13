//
//  ExecutionReducer.swift
//  AgentKit
//
//  Pure reducer: (ExecutionGraph, AgentEvent) → (ExecutionGraph, [NodeID]).
//  Maps ALL 17 AgentEvent cases into GraphNode mutations.
//  Includes the 7 previously-ignored events.
//  Streaming coalescing via ReducerInternal (NOT persisted, NOT in RuntimeSnapshot).
//

import Foundation

// MARK: - ExecutionReducer

/// Reduces AgentEvents into ExecutionGraph mutations.
/// InternalState holds streaming buffers — never persisted, never in snapshots.
public struct ExecutionReducer: Sendable {

    private var internalState: ReducerInternal

    public init() {
        self.internalState = ReducerInternal()
    }

    /// Reduce one AgentEvent into the graph.
    /// - Returns: IDs of newly created or modified nodes (for projection consumers).
    public mutating func reduce(_ event: AgentEvent, into graph: inout ExecutionGraph) -> [NodeID] {
        let ts = Date().timeIntervalSince1970

        switch event {
        // ── Turn lifecycle ──
        case .turnAccepted, .turnQueued:
            return []

        case .turnStarted(let turnID, let text):
            return handleTurnStarted(turnID: turnID, text: text, ts: ts, graph: &graph)

        case .turnFinished(let turnID, let text, let textAnnotations):
            return handleTurnFinished(
                turnID: turnID,
                text: text,
                textAnnotations: textAnnotations,
                ts: ts,
                graph: &graph
            )

        case .turnPaused, .turnResumed:
            return []

        case .turnFailed(let turnID, let text, let err, let errorCode):
            return handleTurnFailed(
                turnID: turnID,
                text: text,
                err: err,
                errorCode: errorCode,
                ts: ts,
                graph: &graph
            )

        case .turnCancelled(let turnID, _):
            return handleTurnCancelled(
                turnID: turnID ?? internalState.currentTurnID ?? "",
                ts: ts,
                graph: &graph
            )

        // ── Streaming text ──
        case .tokenDelta(let turnID, let text):
            return handleTokenDelta(turnID: turnID ?? internalState.currentTurnID ?? "",
                                    text: text, ts: ts, graph: &graph)

        // ── Thinking ──
        case .thinking(let turnID, let text):
            return handleThinking(turnID: turnID ?? internalState.currentTurnID ?? "",
                                  text: text, ts: ts, graph: &graph)

        // ── Tool lifecycle ──
        case .toolStarted(let turnID, let callID, let tool):
            return handleToolStarted(turnID: turnID ?? internalState.currentTurnID ?? "",
                                     callID: callID, toolName: tool.toolName,
                                     args: tool.toolArgs, ts: ts, graph: &graph)

        case .toolStdout(let turnID, let callID, let chunk):
            return handleToolOutput(turnID: turnID ?? internalState.currentTurnID ?? "",
                                    callID: callID, chunk: chunk, isStderr: false,
                                    ts: ts, graph: &graph)

        case .toolStderr(let turnID, let callID, let chunk):
            return handleToolOutput(turnID: turnID ?? internalState.currentTurnID ?? "",
                                    callID: callID, chunk: chunk, isStderr: true,
                                    ts: ts, graph: &graph)

        case .toolFinished(let turnID, let callID, let result):
            return handleToolFinished(turnID: turnID ?? internalState.currentTurnID ?? "",
                                      callID: callID, observation: result.observation,
                                      error: result.error, elapsedMs: result.elapsedMs,
                                      structuredOutput: result.output,
                                      assets: result.assets,
                                      ts: ts, graph: &graph)

        // ── Observation (previously ignored!) ──
        case .observed(let turnID, let callID, _, _, let observation, let failure):
            return handleObserved(turnID: turnID ?? internalState.currentTurnID ?? "",
                                  callID: callID, observation: observation,
                                  failure: failure, ts: ts, graph: &graph)

        // ── Reflection (previously ignored!) ──
        case .reflected(let turnID, let text):
            return handleReflected(turnID: turnID ?? internalState.currentTurnID ?? "",
                                   text: text, ts: ts, graph: &graph)

        // ── Model lifecycle (previously ignored!) ──
        case .modelStarted(let turnID, let invocationID):
            internalState.currentInvocationID = invocationID
            return handleModelStarted(turnID: turnID ?? internalState.currentTurnID ?? "",
                                      ts: ts, graph: &graph)

        case .modelFinished(let turnID, let promptTokens, let completionTokens, let totalTokens,
                            let billingUnits, let elapsedMs, let invocationID, let err):
            return handleModelFinished(turnID: turnID ?? internalState.currentTurnID ?? "",
                                       promptTokens: promptTokens, completionTokens: completionTokens,
                                       totalTokens: totalTokens, billingUnits: billingUnits,
                                       invocationID: invocationID ?? internalState.currentInvocationID,
                                       elapsedMs: elapsedMs,
                                       err: err, ts: ts, graph: &graph)

        // ── Context compaction (previously ignored!) ──
        case .compacted(let turnID, let before, let after, let saved, _, let ratio):
            return handleCompacted(turnID: turnID ?? internalState.currentTurnID ?? "",
                                   beforeTokens: before, afterTokens: after,
                                   savedTokens: saved, ratio: ratio, ts: ts, graph: &graph)

        // ── Auto-approved (previously ignored!) ──
        case .autoApproved(let turnID, let toolName, let toolArgs, let text):
            return handleAutoApproved(turnID: turnID ?? internalState.currentTurnID ?? "",
                                      toolName: toolName, args: toolArgs,
                                      reason: text, ts: ts, graph: &graph)

        // ── Skill loaded (previously ignored!) ──
        case .skillLoaded(let toolName, let skillVersion):
            return handleSkillLoaded(toolName: toolName, version: skillVersion,
                                     ts: ts, graph: &graph)

        // ── Todo ──
        case .todoUpdated(let turnID, let todos):
            return handleTodoUpdated(turnID: turnID ?? internalState.currentTurnID ?? "",
                                     todos: todos, ts: ts, graph: &graph)

        // ── 子流（task 子agent + 后台 job，共用 handler）──
        case .taskStarted(let turnID, let sessionId, _, let callID, let text):
            return handleChildStarted(kind: .task, childID: sessionId, title: text,
                                      originCallID: callID,
                                      turnID: turnID ?? internalState.currentTurnID ?? "",
                                      ts: ts, graph: &graph)

        case .taskFinished(let turnID, let sessionId, _, let text):
            return handleChildFinished(childID: sessionId, result: text, exitCode: nil,
                                       failed: false, canceled: false, elapsedMs: nil,
                                       turnID: turnID ?? internalState.currentTurnID ?? "",
                                       ts: ts, graph: &graph)

        case .jobStarted(let turnID, let jobID, let callID, let command):
            return handleChildStarted(kind: .job, childID: jobID, title: command,
                                      originCallID: callID,
                                      turnID: turnID ?? internalState.currentTurnID ?? "",
                                      ts: ts, graph: &graph)

        case .jobOutput(_, let jobID, let chunk):
            return handleChildOutput(childID: jobID, chunk: chunk, ts: ts, graph: &graph)

        case .jobFinished(let turnID, let jobID, let exitCode, let err, let elapsedMs, let text):
            // P8.7 §8.5（golden 已冻结）：text ∈ exited | failed | canceled；
            // exit_code 仅失败时出现（>0 = 非零退出，-1 = 启动失败/被信号杀死）；
            // err 冗余退出码（如 "exit code 2"），直接用作展示文案。
            let canceled = text == "canceled"
            let failed = !canceled
                && (text == "failed" || (exitCode ?? 0) != 0 || err?.isEmpty == false)
            return handleChildFinished(childID: jobID,
                                       result: failed ? err : nil,
                                       exitCode: exitCode,
                                       failed: failed, canceled: canceled,
                                       elapsedMs: elapsedMs,
                                       turnID: turnID ?? internalState.currentTurnID ?? "",
                                       ts: ts, graph: &graph)

        // ── Plan Approval (handled at RuntimeEngine level, not in graph) ──
        case .planApprovalRequest:
            return []

        // ── Approval ──
        case .approvalRequest(let turnID, let request):
            return handleApprovalRequest(turnID: turnID ?? internalState.currentTurnID ?? "",
                                         request: request, ts: ts, graph: &graph)
        }
    }

    // MARK: - Turn lifecycle handlers

    private mutating func handleTurnStarted(turnID: String, text: String, ts: TimeInterval,
                                             graph: inout ExecutionGraph) -> [NodeID] {
        internalState.currentTurnID = turnID
        internalState.currentInvocationID = nil  // turn boundaries reset invocation tracking
        internalState.streamingAssistant = ""
        internalState.streamingThinking = ""
        internalState.activeToolCallIDs = []
        internalState.lastNodeOfKind = [:]

        // Defensive: server may return duplicate turn_started with the same
        // turnID. Disambiguate so the graph chain and node identity stay sound.
        let baseID = "turn_\(turnID)_user"
        var nodeID = baseID
        if graph.nodes[nodeID] != nil {
            var suffix = 2
            while graph.nodes["\(baseID)_v\(suffix)"] != nil { suffix += 1 }
            nodeID = "\(baseID)_v\(suffix)"
            print("⚠️ [Reducer] duplicate turn_started for \(turnID) → using \(nodeID)")
        }
        let node = GraphNode(
            id: nodeID, kind: .userInput,
            payload: .userInput(text: text),
            status: .completed, timestamp: ts, turnID: turnID
        )
        appendNode(node, to: &graph)
        return [nodeID]
    }

    private mutating func handleTurnFinished(
        turnID: String,
        text: String,
        textAnnotations: [AgentTextAnnotation],
        ts: TimeInterval,
        graph: inout ExecutionGraph
    ) -> [NodeID] {
        // 1. Finalize any in-progress streaming assistant segment.
        if !internalState.streamingAssistant.isEmpty {
            if let prevID = internalState.lastNodeOfKind[.assistantMessage],
               var prevNode = graph.nodes[prevID] {
                prevNode.payload = .assistantMessage(
                    text: internalState.streamingAssistant,
                    textAnnotations: []
                )
                prevNode.status = .completed
                graph.upsertNode(prevNode)
            }
            internalState.streamingAssistant = ""
        }

        // 2. Ensure the authoritative final answer is present exactly once.
        //    turn_finished.text is the complete assistant message. If the last
        //    assistant segment already holds it (streamed answer), we're done;
        //    otherwise it was delivered only here (cold replay or a non-streamed
        //    answer) — append it. Content compare avoids both dropping the
        //    answer and duplicating an already-streamed one.
        if !text.isEmpty {
            // Compare against the actual last assistant node in the graph (the
            // tracked pointer is cleared at each segment boundary, so it can't
            // be used here).
            let lastAssistantNode = graph.linearWalk().last { node in
                if case .assistantMessage = node.payload { return true }
                return false
            }
            let lastText = lastAssistantNode.flatMap { node -> String? in
                if case .assistantMessage(let t, _) = node.payload { return t }
                return nil
            }
            if lastText != text {
                let nodeID = "\(turnID)_assistant_\(internalState.nextAssistantSeq)"
                internalState.nextAssistantSeq += 1
                let node = GraphNode(
                    id: nodeID, kind: .assistantMessage,
                    payload: .assistantMessage(text: text, textAnnotations: textAnnotations),
                    status: .completed, timestamp: ts, turnID: turnID
                )
                appendNode(node, to: &graph)
                internalState.lastNodeOfKind[.assistantMessage] = nodeID
            } else if !textAnnotations.isEmpty,
                      let lastAssistantNode,
                      var node = graph.nodes[lastAssistantNode.id] {
                node.payload = .assistantMessage(text: text, textAnnotations: textAnnotations)
                node.status = .completed
                graph.upsertNode(node)
            }
        }

        // 3. Finalize streaming thinking
        if !internalState.streamingThinking.isEmpty {
            let prevID = internalState.lastNodeOfKind[.thinking]
            if let prevID, var prevNode = graph.nodes[prevID] {
                prevNode.payload = .thinking(text: internalState.streamingThinking)
                prevNode.status = .completed
                graph.upsertNode(prevNode)
            }
            internalState.streamingThinking = ""
        }
        internalState.currentTurnID = nil
        return []
    }

    /// A failed turn is terminal just like a finished turn.  In particular,
    /// every outstanding node must leave `.running`, otherwise the timeline
    /// keeps showing a spinner after the composer has already recovered.
    private mutating func handleTurnFailed(
        turnID: String?,
        text: String?,
        err: String?,
        errorCode: String?,
        ts: TimeInterval,
        graph: inout ExecutionGraph
    ) -> [NodeID] {
        let resolvedTurnID = turnID ?? internalState.currentTurnID ?? ""
        var changed: [NodeID] = []

        for (nodeID, var node) in graph.nodes where node.turnID == resolvedTurnID && node.status == .running {
            node.status = .failed
            node.timestamp = ts
            graph.upsertNode(node)
            changed.append(nodeID)
        }

        // Surface the terminal error in the transcript as well as ending the
        // animation. `err` is the canonical display message; `text` remains a
        // compatibility fallback for older runtimes.
        let message = err ?? text
        if let message, !message.isEmpty {
            let nodeID = "\(resolvedTurnID)_error_\(internalState.nextSystemSeq)"
            internalState.nextSystemSeq += 1
            let metadata = errorCode.map { ["code": $0] } ?? [:]
            let node = GraphNode(
                id: nodeID,
                kind: .system,
                payload: .system(SystemPayload(kind: .error, text: message, metadata: metadata)),
                status: .failed,
                timestamp: ts,
                turnID: resolvedTurnID
            )
            appendNode(node, to: &graph)
            changed.append(nodeID)
        }

        internalState.streamingAssistant = ""
        internalState.streamingThinking = ""
        internalState.lastNodeOfKind[.assistantMessage] = nil
        internalState.lastNodeOfKind[.thinking] = nil
        internalState.activeToolCallIDs = []
        internalState.currentTurnID = nil
        return changed
    }

    /// Locally cancelling a turn has no guaranteed terminal server event.
    /// Stop all current nodes immediately so UI state does not depend on a
    /// best-effort `cancel_turn` acknowledgement.
    public mutating func cancelActiveTurn(turnID: String, graph: inout ExecutionGraph) {
        for (_, var node) in graph.nodes where node.turnID == turnID && node.status == .running {
            node.status = .cancelled
            graph.upsertNode(node)
        }
        internalState.streamingAssistant = ""
        internalState.streamingThinking = ""
        internalState.lastNodeOfKind[.assistantMessage] = nil
        internalState.lastNodeOfKind[.thinking] = nil
        internalState.activeToolCallIDs = []
        internalState.currentTurnID = nil
    }

    private mutating func handleTurnCancelled(
        turnID: String,
        ts: TimeInterval,
        graph: inout ExecutionGraph
    ) -> [NodeID] {
        var changed: [NodeID] = []
        for (nodeID, var node) in graph.nodes where node.turnID == turnID && node.status == .running {
            node.status = .cancelled
            node.timestamp = ts
            graph.upsertNode(node)
            changed.append(nodeID)
        }
        internalState.streamingAssistant = ""
        internalState.streamingThinking = ""
        internalState.lastNodeOfKind[.assistantMessage] = nil
        internalState.lastNodeOfKind[.thinking] = nil
        internalState.activeToolCallIDs = []
        internalState.currentTurnID = nil
        return changed
    }

    // MARK: - Streaming handlers

    private mutating func handleTokenDelta(turnID: String, text: String, ts: TimeInterval,
                                            graph: inout ExecutionGraph) -> [NodeID] {
        internalState.streamingAssistant += text

        if let prevID = internalState.lastNodeOfKind[.assistantMessage],
           var prevNode = graph.nodes[prevID] {
            prevNode.payload = .assistantMessage(
                text: internalState.streamingAssistant,
                textAnnotations: []
            )
            prevNode.timestamp = ts
            graph.upsertNode(prevNode)
            return [prevID]
        } else {
            // Segmented per text run: a fresh node each time text resumes after
            // a tool / new invocation (see finalizeStreamingAssistant). Keeps
            // multi-invocation answers as separate, correctly-positioned blocks
            // instead of one concatenated node forced to the turn end.
            let nodeID = "\(turnID)_assistant_\(internalState.nextAssistantSeq)"
            let node = GraphNode(
                id: nodeID, kind: .assistantMessage,
                payload: .assistantMessage(
                    text: internalState.streamingAssistant,
                    textAnnotations: []
                ),
                status: .running, timestamp: ts, turnID: turnID
            )
            internalState.lastNodeOfKind[.assistantMessage] = nodeID
            appendNode(node, to: &graph)
            return [nodeID]
        }
    }

    /// Finalize the current streaming assistant node and reset the accumulator
    /// so the next `token_delta` starts a new segment. Mirrors the thinking
    /// finalize logic. Called at text-segment boundaries: when a tool starts
    /// (text interrupted) and when a model invocation finishes.
    private mutating func finalizeStreamingAssistant(_ graph: inout ExecutionGraph) {
        guard !internalState.streamingAssistant.isEmpty else { return }
        if let prevID = internalState.lastNodeOfKind[.assistantMessage],
           var prevNode = graph.nodes[prevID] {
            prevNode.status = .completed
            prevNode.payload = .assistantMessage(
                text: internalState.streamingAssistant,
                textAnnotations: []
            )
            graph.upsertNode(prevNode)
        }
        internalState.streamingAssistant = ""
        internalState.lastNodeOfKind[.assistantMessage] = nil
        internalState.nextAssistantSeq += 1
    }

    private mutating func handleThinking(turnID: String, text: String, ts: TimeInterval,
                                          graph: inout ExecutionGraph) -> [NodeID] {
        internalState.streamingThinking += text

        if let prevID = internalState.lastNodeOfKind[.thinking],
           var prevNode = graph.nodes[prevID],
           prevNode.status == .running {
            prevNode.payload = .thinking(text: internalState.streamingThinking)
            prevNode.timestamp = ts
            graph.upsertNode(prevNode)
            return [prevID]
        } else {
            let nodeID = "\(turnID)_think_\(internalState.nextThinkingSeq)"
            internalState.nextThinkingSeq += 1
            let node = GraphNode(
                id: nodeID, kind: .thinking,
                payload: .thinking(text: internalState.streamingThinking),
                status: .running, timestamp: ts, turnID: turnID
            )
            internalState.lastNodeOfKind[.thinking] = nodeID
            appendNode(node, to: &graph)
            return [nodeID]
        }
    }

    // MARK: - Tool handlers

    private mutating func handleToolStarted(turnID: String, callID: String, toolName: String,
                                             args: JSONValue?, ts: TimeInterval,
                                             graph: inout ExecutionGraph) -> [NodeID] {
        internalState.activeToolCallIDs.insert(callID)
        // Thinking block is finalized when a tool starts.
        // Clear tracking so the next thinking block creates a fresh node
        // instead of reusing the old one (which would put it out of order).
        if !internalState.streamingThinking.isEmpty {
            if let prevID = internalState.lastNodeOfKind[.thinking],
               var prevNode = graph.nodes[prevID] {
                prevNode.status = .completed
                prevNode.payload = .thinking(text: internalState.streamingThinking)
                graph.upsertNode(prevNode)
            }
            internalState.streamingThinking = ""
            internalState.lastNodeOfKind[.thinking] = nil
        }
        // Assistant text is interrupted by the tool — close the current segment
        // so any text after the tool starts a fresh block.
        finalizeStreamingAssistant(&graph)

        let nodeID = callID
        let payload = ToolExecPayload(callID: callID, toolName: toolName, args: args)
        let node = GraphNode(
            id: nodeID, kind: .toolCall,
            payload: .toolCall(payload),
            status: .running, timestamp: ts, turnID: turnID
        )
        internalState.lastNodeOfKind[.toolCall] = nodeID
        appendNode(node, to: &graph)
        return [nodeID]
    }

    /// Handle streaming stdout/stderr chunks — append to tool node's output.
    private mutating func handleToolOutput(turnID: String, callID: String, chunk: String,
                                            isStderr: Bool, ts: TimeInterval,
                                            graph: inout ExecutionGraph) -> [NodeID] {
        guard var toolNode = graph.nodes[callID],
              case .toolCall(var payload) = toolNode.payload else {
            return []
        }
        let prefix = isStderr ? "[stderr] " : ""
        payload.output = Self.appendCapped(payload.output, prefix + chunk)
        toolNode.payload = .toolCall(payload)
        toolNode.timestamp = ts
        graph.upsertNode(toolNode)
        return [callID]
    }

    private mutating func handleToolFinished(turnID: String, callID: String,
                                              observation: String?, error: String?,
                                              elapsedMs: Int?,
                                              structuredOutput: JSONValue?,
                                              assets: [AgentAssetRef],
                                              ts: TimeInterval,
                                              graph: inout ExecutionGraph) -> [NodeID] {
        internalState.activeToolCallIDs.remove(callID)
        guard var toolNode = graph.nodes[callID],
              case .toolCall(var payload) = toolNode.payload else {
            return []
        }

        if let err = error, !err.isEmpty {
            // Only show error if no streaming output accumulated
            if payload.output.isEmpty {
                payload.output = err
            }
            payload.exitCode = 1
            toolNode.status = .failed
        } else {
            // Use observation only if no streaming output accumulated
            if payload.output.isEmpty, let obs = observation {
                payload.output = obs
            }
            toolNode.status = .completed
        }
        payload.structuredOutput = structuredOutput
        payload.assets = assets
        payload.elapsedMs = elapsedMs
        toolNode.payload = .toolCall(payload)
        toolNode.timestamp = ts
        graph.upsertNode(toolNode)
        return [callID]
    }

    // MARK: - Observation handler (PREVIOUSLY IGNORED)

    private mutating func handleObserved(turnID: String, callID: String?,
                                          observation: String?, failure: String?,
                                          ts: TimeInterval,
                                          graph: inout ExecutionGraph) -> [NodeID] {
        // Prefer observation; if missing, show failure only if it's a real error
        let text: String
        if let obs = observation, !obs.isEmpty {
            text = obs
        } else if let fail = failure, !fail.isEmpty {
            text = "Error: \(fail)"
        } else {
            text = ""
        }
        guard !text.isEmpty else { return [] }

        let nodeID = "\(callID ?? "unknown")_obs_\(UUID().uuidString.prefix(8))"
        let node = GraphNode(
            id: nodeID, kind: .observation,
            payload: .observation(text: text),
            status: .completed, timestamp: ts, turnID: turnID
        )
        appendNode(node, to: &graph)

        // Link tool → observation via .observes edge
        if let callID, graph.nodes[callID] != nil {
            let edge = GraphEdge(from: callID, to: nodeID, type: .observes)
            graph.addEdge(edge)
        }

        return [nodeID]
    }

    // MARK: - Reflection handler (PREVIOUSLY IGNORED)

    private mutating func handleReflected(turnID: String, text: String, ts: TimeInterval,
                                           graph: inout ExecutionGraph) -> [NodeID] {
        guard !text.isEmpty else { return [] }

        let nodeID = "\(turnID)_refl_\(UUID().uuidString.prefix(8))"
        let node = GraphNode(
            id: nodeID, kind: .reflection,
            payload: .reflection(text: text),
            status: .completed, timestamp: ts, turnID: turnID
        )
        appendNode(node, to: &graph)
        return [nodeID]
    }

    // MARK: - Model lifecycle handlers (PREVIOUSLY IGNORED)

    private mutating func handleModelStarted(turnID: String, ts: TimeInterval,
                                              graph: inout ExecutionGraph) -> [NodeID] {
        let nodeID = "\(turnID)_model_\(UUID().uuidString.prefix(8))"
        let payload = SystemPayload(kind: .modelActivity, text: "Model invoked",
                                     metadata: ["phase": "started"])
        let node = GraphNode(
            id: nodeID, kind: .system,
            payload: .system(payload),
            status: .completed, timestamp: ts, turnID: turnID
        )
        appendNode(node, to: &graph)
        return [nodeID]
    }

    private mutating func handleModelFinished(turnID: String, promptTokens: Int?,
                                               completionTokens: Int?, totalTokens: Int?,
                                               billingUnits: Int64?, invocationID: String?, elapsedMs: Int?, err: String?,
                                               ts: TimeInterval,
                                               graph: inout ExecutionGraph) -> [NodeID] {
        // Finalize the thinking block from this model invocation.
        // Without this, thinking from the next invocation merges into
        // the old node, corrupting both content and timeline position.
        if !internalState.streamingThinking.isEmpty {
            if let prevID = internalState.lastNodeOfKind[.thinking],
               var prevNode = graph.nodes[prevID] {
                prevNode.status = .completed
                prevNode.payload = .thinking(text: internalState.streamingThinking)
                graph.upsertNode(prevNode)
            }
            internalState.streamingThinking = ""
            internalState.lastNodeOfKind[.thinking] = nil
        }
        // Close the assistant text segment for this invocation so the next
        // invocation's text becomes a separate block.
        finalizeStreamingAssistant(&graph)

        let nodeID = "\(turnID)_model_\(UUID().uuidString.prefix(8))"

        if let err {
            let payload = SystemPayload(kind: .error, text: err)
            let node = GraphNode(id: nodeID, kind: .system, payload: .system(payload),
                                 status: .failed, timestamp: ts, turnID: turnID)
            appendNode(node, to: &graph)
            return [nodeID]
        }

        var parts: [String] = []
        if let tokens = promptTokens { parts.append("ctx \(tokens) tokens") }
        if let tokens = totalTokens ?? promptTokens.map({ $0 + (completionTokens ?? 0) }) {
            parts.append("\(tokens) total tokens")
        }
        if let units = billingUnits { parts.append("\(units) units") }
        if let ms = elapsedMs { parts.append("\(ms)ms") }
        let text = parts.isEmpty ? "Model finished" : "Model finished: \(parts.joined(separator: ", "))"

        var metadata: [String: String] = ["phase": "finished"]
        if let tokens = promptTokens { metadata["promptTokens"] = String(tokens) }
        if let tokens = completionTokens { metadata["completionTokens"] = String(tokens) }
        if let tokens = totalTokens { metadata["totalTokens"] = String(tokens) }
        if let units = billingUnits { metadata["billingUnits"] = String(units) }
        if let invocationID { metadata["invocationID"] = invocationID }
        if let ms = elapsedMs { metadata["elapsedMs"] = String(ms) }

        let payload = SystemPayload(kind: .modelActivity, text: text, metadata: metadata)
        let node = GraphNode(id: nodeID, kind: .system, payload: .system(payload),
                             status: .completed, timestamp: ts, turnID: turnID)
        appendNode(node, to: &graph)
        return [nodeID]
    }

    // MARK: - Context compaction handler (PREVIOUSLY IGNORED)

    private mutating func handleCompacted(turnID: String, beforeTokens: Int, afterTokens: Int,
                                           savedTokens: Int, ratio: Double, ts: TimeInterval,
                                           graph: inout ExecutionGraph) -> [NodeID] {
        let text = "Context compacted: \(beforeTokens) → \(afterTokens) tokens (saved \(savedTokens))"
        let metadata: [String: String] = [
            "beforeTokens": String(beforeTokens),
            "afterTokens": String(afterTokens),
            "savedTokens": String(savedTokens),
            "ratio": String(format: "%.1f", ratio)
        ]
        let nodeID = "\(turnID)_compact_\(UUID().uuidString.prefix(8))"
        let payload = SystemPayload(kind: .contextCompact, text: text, metadata: metadata)
        let node = GraphNode(id: nodeID, kind: .system, payload: .system(payload),
                             status: .completed, timestamp: ts, turnID: turnID)
        appendNode(node, to: &graph)
        return [nodeID]
    }

    // MARK: - Auto-approved handler (PREVIOUSLY IGNORED)

    private mutating func handleAutoApproved(turnID: String, toolName: String, args: JSONValue?,
                                              reason: String?, ts: TimeInterval,
                                              graph: inout ExecutionGraph) -> [NodeID] {
        let callID = "auto_\(turnID)_\(UUID().uuidString.prefix(8))"
        let payload = ToolExecPayload(
            callID: callID, toolName: toolName, args: args,
            output: reason ?? "", exitCode: 0, isAutoApproved: true
        )
        let node = GraphNode(id: callID, kind: .toolCall, payload: .toolCall(payload),
                             status: .completed, timestamp: ts, turnID: turnID)
        appendNode(node, to: &graph)
        return [callID]
    }

    // MARK: - Skill loaded handler (PREVIOUSLY IGNORED)

    private mutating func handleSkillLoaded(toolName: String, version: String?,
                                             ts: TimeInterval,
                                             graph: inout ExecutionGraph) -> [NodeID] {
        let text = version.map { "Loaded skill: \(toolName) v\($0)" } ?? "Loaded skill: \(toolName)"
        let metadata: [String: String] = version.map { ["version": $0] } ?? [:]
        let nodeID = "skill_\(UUID().uuidString.prefix(8))"
        let payload = SystemPayload(kind: .skillLoaded, text: text, metadata: metadata)
        let node = GraphNode(id: nodeID, kind: .system, payload: .system(payload),
                             status: .completed, timestamp: ts, turnID: "")
        appendNode(node, to: &graph)
        return [nodeID]
    }

    // MARK: - Todo handler

    private mutating func handleTodoUpdated(turnID: String, todos: [TodoItem], ts: TimeInterval,
                                             graph: inout ExecutionGraph) -> [NodeID] {
        let text = todos.map { "[\($0.status.rawValue)] \($0.content)" }.joined(separator: "\n")
        let nodeID = "\(turnID)_todos"
        let payload = SystemPayload(kind: .modelActivity, text: text,
                                     metadata: ["type": "todos", "count": String(todos.count)])
        let node = GraphNode(id: nodeID, kind: .system, payload: .system(payload),
                             status: .completed, timestamp: ts, turnID: turnID)

        // Update existing node — don't create duplicate edges (branches)
        if graph.nodes[nodeID] != nil {
            graph.upsertNode(node)
        } else {
            appendNode(node, to: &graph)
        }
        return [nodeID]
    }

    // MARK: - Child stream handlers (task subagent + background job)

    private mutating func handleChildStarted(kind: ChildStreamKind, childID: String, title: String,
                                              originCallID: String?, turnID: String, ts: TimeInterval,
                                              graph: inout ExecutionGraph) -> [NodeID] {
        let nodeID = "sub_\(childID)"
        // Replay can deliver a duplicate started — keep the existing node's identity.
        guard graph.nodes[nodeID] == nil else { return [nodeID] }
        let payload = ChildStreamPayload(kind: kind, childID: childID, title: title,
                                         originCallID: originCallID)
        let node = GraphNode(id: nodeID, kind: .childStream, payload: .childStream(payload),
                             status: .running, timestamp: ts, turnID: turnID)
        appendNode(node, to: &graph)
        return [nodeID]
    }

    private mutating func handleChildOutput(childID: String, chunk: String, ts: TimeInterval,
                                             graph: inout ExecutionGraph) -> [NodeID] {
        let nodeID = "sub_\(childID)"
        guard var node = graph.nodes[nodeID],
              case .childStream(var payload) = node.payload else {
            return []
        }
        payload.output = Self.appendCapped(payload.output, chunk)
        node.payload = .childStream(payload)
        node.timestamp = ts
        graph.upsertNode(node)
        return [nodeID]
    }

    private mutating func handleChildFinished(childID: String, result: String?, exitCode: Int?,
                                               failed: Bool, canceled: Bool, elapsedMs: Int?,
                                               turnID: String, ts: TimeInterval,
                                               graph: inout ExecutionGraph) -> [NodeID] {
        let nodeID = "sub_\(childID)"
        guard var node = graph.nodes[nodeID],
              case .childStream(var payload) = node.payload else {
            // finished without started（乱序/部分回放）— 不崩，静默忽略。
            return []
        }
        payload.result = result
        payload.exitCode = exitCode
        payload.canceled = canceled
        payload.elapsedMs = elapsedMs
        node.payload = .childStream(payload)
        node.status = failed ? .failed : .completed
        node.timestamp = ts
        graph.upsertNode(node)
        return [nodeID]
    }

    // MARK: - Approval handler

    private mutating func handleApprovalRequest(turnID: String, request: ApprovalRequest,
                                                 ts: TimeInterval,
                                                 graph: inout ExecutionGraph) -> [NodeID] {
        let nodeID = "approval_\(request.id)"
        let payload = ApprovalExecPayload(
            requestID: request.id, toolName: request.toolName,
            args: request.toolArgs
        )
        let node = GraphNode(id: nodeID, kind: .approval, payload: .approval(payload),
                             status: .running, timestamp: ts, turnID: turnID)
        appendNode(node, to: &graph)
        return [nodeID]
    }

    // MARK: - Helpers

    /// Streamed output cap. Long-running tools/jobs can emit megabytes of
    /// stdout; every byte lives in the graph AND in each published snapshot,
    /// so it is capped here at the source. Head + tail are kept — the middle
    /// is dropped once, then the tail keeps absorbing subsequent trims.
    static let maxStreamedOutput = 262_144        // characters
    private static let cappedHead = 131_072
    private static let cappedTail = 65_536
    private static let truncationMarker = "\n… [output truncated] …\n"

    static func appendCapped(_ current: String, _ chunk: String) -> String {
        var result = current + chunk
        guard result.count > maxStreamedOutput else { return result }
        let head = result.prefix(cappedHead)
        let tail = result.suffix(cappedTail)
        result = head + truncationMarker + tail
        return result
    }

    /// Append a node to the graph, linking it via .next edge from the previous last node.
    /// Uses cached lastNodeID for O(1) instead of O(n) traversal.
    /// Automatically stamps `invocationID` from the reducer's tracked current invocation.
    private mutating func appendNode(_ node: GraphNode, to graph: inout ExecutionGraph) {
        var mutableNode = node
        if mutableNode.invocationID == nil {
            mutableNode.invocationID = internalState.currentInvocationID
        }
        if let lastID = graph.lastNodeID {
            let edge = GraphEdge(from: lastID, to: mutableNode.id, type: .next)
            graph.addEdge(edge)
        }
        graph.upsertNode(mutableNode)
        graph.lastNodeID = mutableNode.id
    }
}

// MARK: - ReducerInternal

/// Streaming buffers and transient state. NOT persisted. NOT in RuntimeSnapshot.
struct ReducerInternal: Sendable {
    var streamingThinking: String = ""
    var streamingAssistant: String = ""
    var activeToolCallIDs: Set<String> = []
    var lastNodeOfKind: [GraphNodeKind: NodeID] = [:]
    var currentTurnID: String? = nil
    var currentInvocationID: String? = nil
    var nextThinkingSeq: Int = 0
    var nextAssistantSeq: Int = 0
    var nextSystemSeq: Int = 0
}
