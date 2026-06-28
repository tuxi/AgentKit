//
//  ExecutionNode.swift
//  AgentKit
//
//  UI model produced by TimelineProjection.
//  NOT stored in ExecutionGraph. NOT persisted.
//  Small kind enum (5 cases) + typed payloads — won't explode to 40 cases.
//

import Foundation

// MARK: - ExecutionNode

/// A single entry in the chronological timeline, produced by TimelineProjection.
public struct ExecutionNode: Identifiable, Sendable {
    public let id: NodeID
    public let kind: ExecutionNodeKind
    public let timestamp: TimeInterval
    public let turnID: String
    /// v1.2: Identifies which model invocation produced this node.
    /// Used by TimelineProjection to group content before model_finished.
    public let invocationID: String?

    public init(id: NodeID, kind: ExecutionNodeKind, timestamp: TimeInterval,
                turnID: String, invocationID: String? = nil) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.turnID = turnID
        self.invocationID = invocationID
    }
}

// MARK: - ExecutionNodeKind

/// UI-level node kind — small set, detail in payloads.
public enum ExecutionNodeKind: Sendable {
    case message(MessageNodePayload)
    case thinking(ThinkingNodePayload)
    case tool(ToolNodePayload)
    case artifact(ArtifactNodePayload)
    case system(SystemNodePayload)
}

// MARK: - Payloads

public struct MessageNodePayload: Sendable {
    public let role: MessageRole
    public let text: String
    public let isStreaming: Bool

    public init(role: MessageRole, text: String, isStreaming: Bool = false) {
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
    }
}

public struct ThinkingNodePayload: Sendable {
    public let text: String
    public let isStreaming: Bool

    public init(text: String, isStreaming: Bool = false) {
        self.text = text
        self.isStreaming = isStreaming
    }
}

public struct ToolNodePayload: Sendable {
    public let callID: String
    public let toolName: String
    public let args: JSONValue?
    public let status: ToolNodeStatus
    public let output: String
    public let exitCode: Int?
    public let elapsedMs: Int?
    public let isAutoApproved: Bool
    /// When non-nil, the tool produced an artifact — links to Inspector.
    public let artifact: ArtifactNode?

    public init(callID: String, toolName: String, args: JSONValue?,
                status: ToolNodeStatus, output: String = "",
                exitCode: Int? = nil, elapsedMs: Int? = nil,
                isAutoApproved: Bool = false,
                artifact: ArtifactNode? = nil) {
        self.callID = callID
        self.toolName = toolName
        self.args = args
        self.status = status
        self.output = output
        self.exitCode = exitCode
        self.elapsedMs = elapsedMs
        self.isAutoApproved = isAutoApproved
        self.artifact = artifact
    }
}

public enum ToolNodeStatus: String, Sendable {
    case running
    case completed
    case failed
    case autoApproved
}

public struct ArtifactNodePayload: Sendable {
    public let node: ArtifactNode

    public init(node: ArtifactNode) {
        self.node = node
    }
}

public struct SystemNodePayload: Sendable {
    public let kind: SystemNodeKind
    public let text: String
    public let metadata: [String: String]

    public init(kind: SystemNodeKind, text: String, metadata: [String: String] = [:]) {
        self.kind = kind
        self.text = text
        self.metadata = metadata
    }
}

public enum SystemNodeKind: String, Sendable {
    case observation
    case reflection
    case modelActivity
    case contextCompact
    case skillLoaded
    case error
}
