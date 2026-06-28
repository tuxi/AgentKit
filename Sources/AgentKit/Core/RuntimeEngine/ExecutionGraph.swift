//
//  ExecutionGraph.swift
//  AgentKit
//
//  Runtime Truth — a directed graph of execution nodes.
//  The ONLY mutable runtime state. Everything else is a projection.
//  Phase 1 uses .next edges for linear sequences; Phase 3+ adds .spawns/.forks/.parallel.
//

import Foundation

// MARK: - ID types

/// Graph node identity.
public typealias NodeID = String

/// Graph edge identity.
public typealias EdgeID = String

// MARK: - ExecutionGraph

/// Runtime Truth — nodes + typed edges.
/// Timeline is a projection of this graph, not a separate data structure.
public struct ExecutionGraph: Sendable {
    public var nodes: [NodeID: GraphNode] = [:]
    public var rootID: NodeID?
    public var edges: [EdgeID: GraphEdge] = [:]

    /// Ordered edge IDs for traversal (maintains insertion order for topological sort).
    public var edgeOrder: [EdgeID] = []

    /// Cached last node ID — avoids O(n) traversal on every append.
    var lastNodeID: NodeID?

    public init() {}

    // MARK: - Mutations

    /// Upsert a node (by id).
    public mutating func upsertNode(_ node: GraphNode) {
        nodes[node.id] = node
        if rootID == nil {
            rootID = node.id
        }
    }

    /// Update an existing node in-place. No-op if not found.
    public mutating func updateNode(_ id: NodeID, with transform: (inout GraphNode) -> Void) {
        guard var node = nodes[id] else { return }
        transform(&node)
        nodes[id] = node
    }

    /// Add an edge. Deduplicates by (from, to, type).
    public mutating func addEdge(_ edge: GraphEdge) {
        let exists = edges.values.contains { $0.from == edge.from && $0.to == edge.to && $0.type == edge.type }
        guard !exists else { return }
        edges[edge.id] = edge
        edgeOrder.append(edge.id)
    }

    /// Find the last node of a given kind (used by Reducer for coalescing).
    public func lastNode(ofKind kind: GraphNodeKind) -> GraphNode? {
        // Walk edges from root to find the last matching node
        guard let root = rootID else { return nil }
        var lastMatch: GraphNode?
        var current: NodeID? = root
        var visited = Set<NodeID>()
        while let id = current, !visited.contains(id) {
            visited.insert(id)
            if let node = nodes[id], node.kind == kind {
                lastMatch = node
            }
            // Follow .next edge
            current = edges.values.first { $0.from == id && $0.type == .next }?.to
        }
        return lastMatch
    }

    /// The last node in the graph (trailing end of .next chain).
    public var lastNode: GraphNode? {
        guard let root = rootID else { return nil }
        var current: NodeID = root
        var visited = Set<NodeID>()
        while !visited.contains(current) {
            visited.insert(current)
            if let next = edges.values.first(where: { $0.from == current && $0.type == .next }) {
                current = next.to
            } else {
                return nodes[current]
            }
        }
        return nodes[root]
    }

    /// Topological walk of nodes following .next edges.
    public func linearWalk() -> [GraphNode] {
        guard let root = rootID else { return [] }
        var result: [GraphNode] = []
        var current: NodeID? = root
        var visited = Set<NodeID>()
        while let id = current, !visited.contains(id) {
            visited.insert(id)
            if let node = nodes[id] {
                result.append(node)
            }
            current = edges.values.first { $0.from == id && $0.type == .next }?.to
        }
        // DEBUG: verify order — user messages should appear monotonically
        let userNodes = result.filter { if case .userInput = $0.payload { return true }; return false }
        let userIDs = userNodes.map { $0.id }
        print("📜 [Graph] linearWalk: \(result.count) nodes, user order: \(userIDs)")
        return result
    }
}

// MARK: - GraphNode

/// A single execution step in the agent's reasoning.
public struct GraphNode: Identifiable, Sendable {
    public let id: NodeID
    public let kind: GraphNodeKind
    public var payload: NodePayload
    public var status: NodeStatus
    public var timestamp: TimeInterval
    public let turnID: String

    public init(
        id: NodeID,
        kind: GraphNodeKind,
        payload: NodePayload,
        status: NodeStatus = .running,
        timestamp: TimeInterval = Date().timeIntervalSince1970,
        turnID: String
    ) {
        self.id = id
        self.kind = kind
        self.payload = payload
        self.status = status
        self.timestamp = timestamp
        self.turnID = turnID
    }
}

// MARK: - GraphNodeKind

/// The kind of execution step. Small set — detail is in NodePayload.
public enum GraphNodeKind: String, Sendable, CaseIterable {
    case userInput
    case thinking
    case toolCall
    case observation
    case reflection
    case assistantMessage
    case system
    case subagent
    case approval
}

// MARK: - NodePayload

/// Typed payload per GraphNodeKind. Uses existing ArtifactPayload for artifact-kind nodes.
public enum NodePayload: Sendable {
    case userInput(text: String)
    case thinking(text: String)
    case toolCall(ToolExecPayload)
    case observation(text: String)
    case reflection(text: String)
    case assistantMessage(text: String)
    case system(SystemPayload)
    case subagent(SubagentExecPayload)
    case approval(ApprovalExecPayload)
}

// MARK: - Payload structs

public struct ToolExecPayload: Sendable {
    public let callID: String
    public let toolName: String
    public let args: JSONValue?
    public var output: String
    public var exitCode: Int?
    public var elapsedMs: Int?
    public var isAutoApproved: Bool

    public init(callID: String, toolName: String, args: JSONValue?,
                output: String = "", exitCode: Int? = nil,
                elapsedMs: Int? = nil, isAutoApproved: Bool = false) {
        self.callID = callID
        self.toolName = toolName
        self.args = args
        self.output = output
        self.exitCode = exitCode
        self.elapsedMs = elapsedMs
        self.isAutoApproved = isAutoApproved
    }
}

public struct SystemPayload: Sendable {
    public let kind: SystemPayloadKind
    public let text: String
    public let metadata: [String: String]

    public init(kind: SystemPayloadKind, text: String, metadata: [String: String] = [:]) {
        self.kind = kind
        self.text = text
        self.metadata = metadata
    }
}

public enum SystemPayloadKind: String, Sendable {
    case modelActivity
    case contextCompact
    case skillLoaded
    case error
}

public struct SubagentExecPayload: Sendable {
    public let subSessionID: String
    public let prompt: String
    public var result: String?

    public init(subSessionID: String, prompt: String, result: String? = nil) {
        self.subSessionID = subSessionID
        self.prompt = prompt
        self.result = result
    }
}

public struct ApprovalExecPayload: Sendable {
    public let requestID: String
    public let toolName: String
    public let args: JSONValue?
    public var resolved: Bool
    public var approved: Bool?

    public init(requestID: String, toolName: String, args: JSONValue?,
                resolved: Bool = false, approved: Bool? = nil) {
        self.requestID = requestID
        self.toolName = toolName
        self.args = args
        self.resolved = resolved
        self.approved = approved
    }
}

// MARK: - GraphEdge

public struct GraphEdge: Identifiable, Sendable {
    public let id: EdgeID
    public let from: NodeID
    public let to: NodeID
    public let type: EdgeType

    public init(id: EdgeID = UUID().uuidString, from: NodeID, to: NodeID, type: EdgeType) {
        self.id = id
        self.from = from
        self.to = to
        self.type = type
    }
}

// MARK: - EdgeType

public enum EdgeType: String, Sendable, CaseIterable {
    /// Linear sequence — the default progression.
    case next
    /// Parent spawns a sub-agent.
    case spawns
    /// Tool produces an observation.
    case observes
    /// Tool triggers an approval request.
    case approves
    // Future:
    // case forks     — a thinking node forks into multiple tool paths
    // case parallel  — two tool nodes execute concurrently
    // case dependsOn — a tool depends on output from another
}

// MARK: - NodeStatus

public enum NodeStatus: String, Sendable {
    case pending
    case running
    case completed
    case failed
    case cancelled
}
