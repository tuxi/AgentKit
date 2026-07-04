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

    /// Adjacency index for `.next` edges (from → to). Keeps linearWalk and
    /// lastNode O(N) instead of scanning `edges` once per hop.
    private var nextByFrom: [NodeID: NodeID] = [:]

    /// Dedup index for addEdge — (from, to, type) triples already present.
    private var edgeKeys: Set<String> = []

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
        let key = "\(edge.from)\u{1F}\(edge.to)\u{1F}\(edge.type.rawValue)"
        guard edgeKeys.insert(key).inserted else { return }
        edges[edge.id] = edge
        edgeOrder.append(edge.id)
        if edge.type == .next {
            nextByFrom[edge.from] = edge.to
        }
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
            current = nextByFrom[id]
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
            if let next = nextByFrom[current] {
                current = next
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
        result.reserveCapacity(nodes.count)
        var current: NodeID? = root
        var visited = Set<NodeID>(minimumCapacity: nodes.count)
        while let id = current, !visited.contains(id) {
            visited.insert(id)
            if let node = nodes[id] {
                result.append(node)
            }
            current = nextByFrom[id]
        }
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
    /// v1.2: Identifies which model invocation produced this node.
    /// nil for user messages and turn-boundary events. Set by appendNode.
    public var invocationID: String?

    public init(
        id: NodeID,
        kind: GraphNodeKind,
        payload: NodePayload,
        status: NodeStatus = .running,
        timestamp: TimeInterval = Date().timeIntervalSince1970,
        turnID: String,
        invocationID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.payload = payload
        self.status = status
        self.timestamp = timestamp
        self.turnID = turnID
        self.invocationID = invocationID
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
    case childStream
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
    case assistantMessage(text: String, textAnnotations: [AgentTextAnnotation])
    case system(SystemPayload)
    case childStream(ChildStreamPayload)
    case approval(ApprovalExecPayload)
}

// MARK: - Payload structs

public struct ToolExecPayload: Sendable {
    public let callID: String
    public let toolName: String
    public let args: JSONValue?
    public var output: String
    public var structuredOutput: JSONValue?
    public var assets: [AgentAssetRef]
    public var exitCode: Int?
    public var elapsedMs: Int?
    public var isAutoApproved: Bool

    public init(callID: String, toolName: String, args: JSONValue?,
                output: String = "", structuredOutput: JSONValue? = nil,
                assets: [AgentAssetRef] = [], exitCode: Int? = nil,
                elapsedMs: Int? = nil, isAutoApproved: Bool = false) {
        self.callID = callID
        self.toolName = toolName
        self.args = args
        self.output = output
        self.structuredOutput = structuredOutput
        self.assets = assets
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

/// 子流类别 —— task 子agent（P8.3）与后台 job（P8.7）共用一套渲染。
public enum ChildStreamKind: String, Sendable, Hashable {
    case task
    case job
}

/// 一个"子流"（task 子agent / 后台 job）在父时间线中的入口节点。
/// `childID` 是子流 id（task 的子 session id / job 的 job id），
/// 可通过 `GET /v1/conversations/{childID}/events` attach 子流详情。
public struct ChildStreamPayload: Sendable {
    public let kind: ChildStreamKind
    public let childID: String
    /// task 的委派 prompt / job 的 command。
    public let title: String
    /// 发起此子流的工具调用 id（task→`task` 调用 / job→`run_command` 调用）。
    /// 与工具卡共享，投影层据此合并去重（比按 prompt 字符串更稳）。
    public let originCallID: String?
    /// 结束时写入：task 的结论 / job 失败时的展示文案（`err`，如 "exit code 2"）。
    public var result: String?
    /// job 专用（P8.7 §8.5）：仅失败时出现；>0 = 非零退出，-1 = 启动失败/被信号杀死。
    public var exitCode: Int?
    /// job 专用：被主动取消（`text=="canceled"`），样式上区别于失败。
    public var canceled: Bool
    /// job 专用：任务总耗时（`job_finished.elapsed_ms`）。
    public var elapsedMs: Int?
    /// 输出累积（`job_output` 分块；只在子流自己的 graph 里增长）。
    public var output: String

    public init(kind: ChildStreamKind, childID: String, title: String,
                originCallID: String? = nil,
                result: String? = nil, exitCode: Int? = nil,
                canceled: Bool = false, elapsedMs: Int? = nil, output: String = "") {
        self.kind = kind
        self.childID = childID
        self.title = title
        self.originCallID = originCallID
        self.result = result
        self.exitCode = exitCode
        self.canceled = canceled
        self.elapsedMs = elapsedMs
        self.output = output
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
