//
//  WorkflowModels.swift
//  AgentKit
//
//  Domain data models for Flux Workflow DAG topology.
//  对照协议：runtime-event-contract-v1.md §5.8、
//           flux-dynamic-dag-integration-v1.md §9-10。
//
//  关键约束：
//  - 状态枚举全部开放（.unknown(String) 兜底），兼容服务端新增状态
//  - 所有 struct 为 Sendable
//  - 状态只由 *_state_changed 事件驱动，不由日志/文案推断
//

import Foundation
import ClientToolProtocol

// MARK: - WorkflowTaskStatus (open enum)

/// Workflow Task 整体状态。开放枚举 —— 遇到未知值回退为 `.unknown(String)`。
public enum WorkflowTaskStatus: Sendable, Equatable, Hashable {
    case pending
    case running
    case suspended      // 非终态：等待 client tool / 外部事件 / 子工作流
    case success
    case failed
    case canceled
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "pending":  self = .pending
        case "running":  self = .running
        case "suspended": self = .suspended
        case "success":  self = .success
        case "failed":   self = .failed
        case "canceled": self = .canceled
        default:         self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .pending:   return "pending"
        case .running:   return "running"
        case .suspended: return "suspended"
        case .success:   return "success"
        case .failed:    return "failed"
        case .canceled:  return "canceled"
        case .unknown(let v): return v
        }
    }

    /// 是否为终态。
    public var isTerminal: Bool {
        switch self {
        case .success, .failed, .canceled: return true
        case .pending, .running, .suspended, .unknown: return false
        }
    }
}

// MARK: - WorkflowNodeState (open enum)

/// 单个 Workflow 节点的执行状态。开放枚举 —— 未知值通过 `terminal` 字段回退渲染。
public enum WorkflowNodeState: Sendable, Equatable, Hashable {
    case pending
    case ready
    case running
    case awaiting        // 等待端侧操作（client tool）
    case retrying
    case successPendingEdges
    case failedPendingEdges
    case success
    case failed
    case skipped
    case canceled
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "pending":               self = .pending
        case "ready":                 self = .ready
        case "running":               self = .running
        case "awaiting":              self = .awaiting
        case "retrying":              self = .retrying
        case "success_pending_edges": self = .successPendingEdges
        case "failed_pending_edges":  self = .failedPendingEdges
        case "success":               self = .success
        case "failed":                self = .failed
        case "skipped":               self = .skipped
        case "canceled":              self = .canceled
        default:                      self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .pending:               return "pending"
        case .ready:                 return "ready"
        case .running:               return "running"
        case .awaiting:              return "awaiting"
        case .retrying:              return "retrying"
        case .successPendingEdges:   return "success_pending_edges"
        case .failedPendingEdges:    return "failed_pending_edges"
        case .success:               return "success"
        case .failed:                return "failed"
        case .skipped:               return "skipped"
        case .canceled:              return "canceled"
        case .unknown(let v):        return v
        }
    }

    /// 是否为终态（节点不会再变化）。
    public var isTerminal: Bool {
        switch self {
        case .success, .failed, .skipped, .canceled: return true
        case .pending, .ready, .running, .awaiting,
             .retrying, .successPendingEdges, .failedPendingEdges,
             .unknown: return false
        }
    }
}

// MARK: - WorkflowRun

/// 一次 Workflow 执行的完整状态。
/// 以 `workflowID` 为稳定标识；通过 `parentCallID` 关联到发起 `plan_workflow` 的工具调用。
public struct WorkflowRun: Sendable {
    public let workflowID: String
    public let parentCallID: String
    public var taskID: Int64?
    public var status: WorkflowTaskStatus
    public var nodes: [String: WorkflowNode]   // keyed by node.name
    public var edges: [WorkflowEdge]
    public var output: JSONValue?
    public var error: String?
    public var goal: String?
    public var lastSequence: Int64
    /// 当前 suspended 的节点名（来自 workflow_suspended 事件）。
    public var suspendedNodeName: String?

    public init(
        workflowID: String,
        parentCallID: String,
        taskID: Int64? = nil,
        status: WorkflowTaskStatus = .pending,
        nodes: [String: WorkflowNode] = [:],
        edges: [WorkflowEdge] = [],
        output: JSONValue? = nil,
        error: String? = nil,
        goal: String? = nil,
        lastSequence: Int64 = 0,
        suspendedNodeName: String? = nil
    ) {
        self.workflowID = workflowID
        self.parentCallID = parentCallID
        self.taskID = taskID
        self.status = status
        self.nodes = nodes
        self.edges = edges
        self.output = output
        self.error = error
        self.goal = goal
        self.lastSequence = lastSequence
        self.suspendedNodeName = suspendedNodeName
    }
}

// MARK: - WorkflowNode

/// DAG 中的单个节点。
public struct WorkflowNode: Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let type: String
    public var state: WorkflowNodeState
    public var progress: Double
    public var output: JSONValue?
    public var error: String?
    /// 是否为终态（来自事件中的 `terminal` 字段；未知 state 时用于回退判断）。
    public var terminal: Bool
    /// 节点耗时（毫秒）。
    public var elapsedMs: Int64?
    /// 瞬态 stream 输出缓冲区（不用于状态恢复，可能丢失）。
    public var streamOutput: String
    /// 工具名（tool 类型节点）。
    public var toolName: String?
    /// 表达式形式的输入映射（来自 plan_ready，key 为参数名，value 为 $from 表达式）。
    public var inputMapping: JSONValue?

    public init(
        name: String,
        type: String,
        state: WorkflowNodeState = .pending,
        progress: Double = 0,
        output: JSONValue? = nil,
        error: String? = nil,
        terminal: Bool = false,
        elapsedMs: Int64? = nil,
        streamOutput: String = "",
        toolName: String? = nil,
        inputMapping: JSONValue? = nil
    ) {
        self.name = name
        self.type = type
        self.state = state
        self.progress = progress
        self.output = output
        self.error = error
        self.terminal = terminal
        self.elapsedMs = elapsedMs
        self.streamOutput = streamOutput
        self.toolName = toolName
        self.inputMapping = inputMapping
    }
}

// MARK: - WorkflowEdge

/// DAG 中的一条有向边。
public struct WorkflowEdge: Sendable, Equatable, Hashable {
    public let from: String
    public let to: String
    public let type: String   // "normal" | "conditional" | ...

    public init(from: String, to: String, type: String = "normal") {
        self.from = from
        self.to = to
        self.type = type
    }
}

// MARK: - AgentEvent payload types for workflow events

/// `workflow_plan_ready` 事件的 payload。
public struct WorkflowPlanReadyData: Sendable {
    public let workflowID: String
    public let parentCallID: String
    public let goal: String?
    public let nodes: [WorkflowPlanNode]
    public let edges: [WorkflowEdge]

    public init(workflowID: String, parentCallID: String,
                goal: String?, nodes: [WorkflowPlanNode], edges: [WorkflowEdge]) {
        self.workflowID = workflowID
        self.parentCallID = parentCallID
        self.goal = goal
        self.nodes = nodes
        self.edges = edges
    }
}

/// plan_ready 中的节点定义（轻量，仅拓扑信息）。
public struct WorkflowPlanNode: Sendable {
    public let name: String
    public let type: String
    public let toolName: String?
    /// 表达式形式的输入映射，key 为工具参数名，value 为 $from 表达式。
    public let inputMapping: JSONValue?

    public init(name: String, type: String, toolName: String? = nil,
                inputMapping: JSONValue? = nil) {
        self.name = name
        self.type = type
        self.toolName = toolName
        self.inputMapping = inputMapping
    }
}

/// `workflow_task_state_changed` 事件的 payload。
public struct WorkflowTaskStateChange: Sendable {
    public let workflowID: String
    public let taskID: Int64?
    public let rootTaskID: Int64?
    public let from: String?
    public let to: String
    public let sequence: Int64?
    public let message: String?
    public let progress: Double
    public let createdAt: String?

    public init(workflowID: String, taskID: Int64?, rootTaskID: Int64? = nil,
                from: String?, to: String, sequence: Int64? = nil,
                message: String? = nil, progress: Double = 0,
                createdAt: String? = nil) {
        self.workflowID = workflowID
        self.taskID = taskID
        self.rootTaskID = rootTaskID
        self.from = from
        self.to = to
        self.sequence = sequence
        self.message = message
        self.progress = progress
        self.createdAt = createdAt
    }
}

/// `workflow_node_state_changed` 事件的 payload。
public struct WorkflowNodeStateChange: Sendable {
    public let workflowID: String
    public let parentCallID: String?
    public let taskID: Int64?
    public let nodeName: String
    public let from: String?
    public let to: String
    public let terminal: Bool
    public let progress: Double
    public let sequence: Int64?
    public let error: String?
    public let output: JSONValue?
    public let message: String?
    public let createdAt: String?

    public init(workflowID: String, parentCallID: String?, taskID: Int64?,
                nodeName: String, from: String?, to: String,
                terminal: Bool, progress: Double, sequence: Int64? = nil,
                error: String? = nil, output: JSONValue? = nil,
                message: String? = nil, createdAt: String? = nil) {
        self.workflowID = workflowID
        self.parentCallID = parentCallID
        self.taskID = taskID
        self.nodeName = nodeName
        self.from = from
        self.to = to
        self.terminal = terminal
        self.progress = progress
        self.sequence = sequence
        self.error = error
        self.output = output
        self.message = message
        self.createdAt = createdAt
    }
}

/// `workflow_suspended` 事件的 payload。
public struct WorkflowSuspendedData: Sendable {
    public let workflowID: String
    public let parentCallID: String?
    public let taskID: Int64?
    public let status: String
    public let nodeName: String?
    public let reason: String?
    public let resumable: Bool

    public init(workflowID: String, parentCallID: String?, taskID: Int64?,
                status: String, nodeName: String?, reason: String?,
                resumable: Bool) {
        self.workflowID = workflowID
        self.parentCallID = parentCallID
        self.taskID = taskID
        self.status = status
        self.nodeName = nodeName
        self.reason = reason
        self.resumable = resumable
    }
}

/// `workflow_finished` 事件的 payload。
public struct WorkflowFinishedData: Sendable {
    public let workflowID: String
    public let taskID: Int64?
    public let status: String
    public let output: JSONValue?

    public init(workflowID: String, taskID: Int64?,
                status: String, output: JSONValue?) {
        self.workflowID = workflowID
        self.taskID = taskID
        self.status = status
        self.output = output
    }
}

/// `workflow_failed` 事件的 payload。
public struct WorkflowFailedData: Sendable {
    public let workflowID: String
    public let taskID: Int64?
    public let status: String
    public let error: String?

    public init(workflowID: String, taskID: Int64?,
                status: String, error: String?) {
        self.workflowID = workflowID
        self.taskID = taskID
        self.status = status
        self.error = error
    }
}

/// `workflow_*_progress` 事件的通用 payload。
public struct WorkflowProgressData: Sendable {
    public let workflowID: String
    public let nodeName: String?
    public let progress: Double

    public init(workflowID: String, nodeName: String?, progress: Double) {
        self.workflowID = workflowID
        self.nodeName = nodeName
        self.progress = progress
    }
}

/// `workflow_tool_log` / `workflow_tool_stream` 事件的 payload。
public struct WorkflowToolStreamData: Sendable {
    public let workflowID: String
    public let nodeName: String
    public let chunk: String

    public init(workflowID: String, nodeName: String, chunk: String) {
        self.workflowID = workflowID
        self.nodeName = nodeName
        self.chunk = chunk
    }
}

/// `workflow_task_succeeded` / `workflow_task_failed` / `workflow_task_suspended` bracket 事件的 payload。
public struct WorkflowTaskBracketData: Sendable {
    public let workflowID: String
    public let parentCallID: String?
    public let taskID: Int64?
    public let rootTaskID: Int64?
    public let message: String?
    public let error: String?
    public let progress: Double
    public let sequence: Int64?
    public let createdAt: String?

    public init(workflowID: String, parentCallID: String? = nil,
                taskID: Int64? = nil, rootTaskID: Int64? = nil,
                message: String? = nil, error: String? = nil,
                progress: Double = 0, sequence: Int64? = nil,
                createdAt: String? = nil) {
        self.workflowID = workflowID
        self.parentCallID = parentCallID
        self.taskID = taskID
        self.rootTaskID = rootTaskID
        self.message = message
        self.error = error
        self.progress = progress
        self.sequence = sequence
        self.createdAt = createdAt
    }
}


// MARK: - Phase 4 Snapshot API types

/// `GET /v1/conversations/{id}/workflow/{workflow_id}/snapshot` 返回的顶层结构。
/// 包含 DAG 拓扑 + 全部节点状态 + snapshot_sequence，一次调用即可渲染完整 DAG。
public struct WorkflowSnapshot: Decodable, Sendable {
    public let workflowId: String
    public let goal: String?
    public let task: WorkflowSnapshotTask?
    public let nodes: [WorkflowSnapshotNode]
    public let edges: [WorkflowSnapshotEdge]
    public let snapshotSequence: Int64

    enum CodingKeys: String, CodingKey {
        case goal, task, nodes, edges
        case workflowId = "workflow_id"
        case snapshotSequence = "snapshot_sequence"
    }
}

/// Snapshot 中的 task 摘要。
public struct WorkflowSnapshotTask: Decodable, Sendable {
    public let id: Int64
    public let status: String
    public let progress: Double?
    public let output: JSONValue?
}

/// Snapshot 中的单个节点状态。
public struct WorkflowSnapshotNode: Decodable, Sendable {
    public let name: String
    public let state: String
    public let terminal: Bool
    public let active: Bool
    public let error: String?
    public let progress: Double?
    public let output: JSONValue?
}

/// Snapshot 中的边。
public struct WorkflowSnapshotEdge: Decodable, Sendable {
    public let from: String
    public let to: String
}
