//
//  MergePolicy.swift
//  AgentKit
//
//  Merge strategy for TimelineProjection.
//  Separate from ReplayEngine — different platforms can use different policies.
//  Replay should NOT know how to merge. Merge is a UI/projection concern.
//

import Foundation

// MARK: - MergePolicy

/// Determines whether and how consecutive ExecutionNodes should be merged.
/// Injected into TimelineProjection. Platforms pick their own policy.
public protocol MergePolicy: Sendable {
    /// Whether `node` should be merged into `previous`.
    func shouldMerge(_ node: ExecutionNode, with previous: ExecutionNode) -> Bool

    /// Merge `node`'s content into `previous`. Called only when shouldMerge returns true.
    func merge(_ node: ExecutionNode, into previous: inout ExecutionNode)
}

// MARK: - DefaultMergePolicy

/// Default coalescing: consecutive thinking / assistant messages merge.
/// Tool stdout/stderr aren't distinct in v1 protocol, so tool nodes don't merge here.
public struct DefaultMergePolicy: MergePolicy {

    public init() {}

    public func shouldMerge(_ node: ExecutionNode, with previous: ExecutionNode) -> Bool {
        switch (previous.kind, node.kind) {
        // Consecutive thinking blocks merge
        case (.thinking, .thinking):
            return true
        // Consecutive assistant messages merge (streaming deltas)
        case (.message(let prev), .message(let next)):
            return prev.role == next.role && prev.role == .assistant
        // System nodes never merge — each is a distinct event
        // (model started/finished are separate timeline events, not deltas)
        case (.system, .system):
            return false
        default:
            return false
        }
    }

    public func merge(_ node: ExecutionNode, into previous: inout ExecutionNode) {
        switch (previous.kind, node.kind) {
        case (.thinking(var prevPayload), .thinking(let nextPayload)):
            prevPayload = ThinkingNodePayload(
                text: prevPayload.text + nextPayload.text,
                isStreaming: nextPayload.isStreaming
            )
            previous = ExecutionNode(
                id: previous.id, kind: .thinking(prevPayload),
                timestamp: previous.timestamp, turnID: previous.turnID,
                invocationID: previous.invocationID
            )

        case (.message(var prevPayload), .message(let nextPayload)):
            prevPayload = MessageNodePayload(
                role: prevPayload.role,
                text: prevPayload.text + nextPayload.text,
                isStreaming: nextPayload.isStreaming
            )
            previous = ExecutionNode(
                id: previous.id, kind: .message(prevPayload),
                timestamp: previous.timestamp, turnID: previous.turnID,
                invocationID: previous.invocationID
            )

        case (.system(var prevPayload), .system(let nextPayload)):
            prevPayload = SystemNodePayload(
                kind: prevPayload.kind,
                text: prevPayload.text + "\n" + nextPayload.text,
                metadata: prevPayload.metadata.merging(nextPayload.metadata) { _, new in new }
            )
            previous = ExecutionNode(
                id: previous.id, kind: .system(prevPayload),
                timestamp: previous.timestamp, turnID: previous.turnID,
                invocationID: previous.invocationID
            )

        default:
            break // No merge defined
        }
    }
}
