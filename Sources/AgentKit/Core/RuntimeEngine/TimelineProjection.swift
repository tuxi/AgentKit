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

    /// Project the graph into a chronological timeline.
    /// Walks .next edges from root, converts each GraphNode → ExecutionNode, applies merge.
    public func project(_ graph: ExecutionGraph) -> [ExecutionNode] {
        let rawNodes = graph.linearWalk().compactMap { projectNode($0) }
        return applyMerge(rawNodes)
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
            timestamp: graphNode.timestamp, turnID: graphNode.turnID
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
