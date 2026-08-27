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
    public let error: String?
    public let output: JSONValue?
    /// 该 run 关联的 workflow version id（无版本链接时为空）。
    public let workflowVersionID: Int64?

    public init(
        id: Int64,
        status: String,
        progress: Double? = nil,
        error: String? = nil,
        output: JSONValue? = nil,
        workflowVersionID: Int64? = nil
    ) {
        self.id = id
        self.status = status
        self.progress = progress
        self.error = error
        self.output = output
        self.workflowVersionID = workflowVersionID
    }

    enum CodingKeys: String, CodingKey {
        case id, status, progress, error, output
        case workflowVersionID = "workflow_version_id"
    }
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
    /// 是否处于挂起等待（task 挂起且该节点 awaiting）。
    public let suspended: Bool

    public init(
        name: String,
        state: String,
        terminal: Bool,
        active: Bool,
        error: String? = nil,
        progress: Double? = nil,
        output: JSONValue? = nil,
        suspended: Bool = false
    ) {
        self.name = name
        self.state = state
        self.terminal = terminal
        self.active = active
        self.error = error
        self.progress = progress
        self.output = output
        self.suspended = suspended
    }
    
    enum CodingKeys: CodingKey {
        case name
        case state
        case terminal
        case active
        case error
        case progress
        case output
        case suspended
    }
    
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.state = try container.decode(String.self, forKey: .state)
        self.terminal = try container.decode(Bool.self, forKey: .terminal)
        self.active = try container.decode(Bool.self, forKey: .active)
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        self.progress = try container.decodeIfPresent(Double.self, forKey: .progress)
        self.output = try container.decodeIfPresent(JSONValue.self, forKey: .output)
        self.suspended = try container.decodeIfPresent(Bool.self, forKey: .suspended) ?? false
    }
}

/// Snapshot 中的边。
public struct WorkflowSnapshotEdge: Decodable, Sendable {
    public let from: String
    public let to: String
}

// MARK: - Workspace-scoped catalog / detail DTOs (P18 R1)

/// `GET /v1/workspaces/{path}/workflows` 的一行目录项。
/// 对照 code-agent `internal/runtime/workflow_list.go` 的 `WorkflowSummary`。
public struct WorkflowSummary: Decodable, Sendable, Identifiable, Equatable {
    public let id: Int64
    public let name: String
    public let description: String
    public let latestHash: String?
    public let latestTaskID: Int64?
    public let latestStatus: String?
    public let latestError: String?
    /// 是否为用户命名的可复用模板（R4 保存后置 1）。
    public let isTemplate: Bool

    public init(
        id: Int64,
        name: String,
        description: String = "",
        latestHash: String? = nil,
        latestTaskID: Int64? = nil,
        latestStatus: String? = nil,
        latestError: String? = nil,
        isTemplate: Bool = false
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.latestHash = latestHash
        self.latestTaskID = latestTaskID
        self.latestStatus = latestStatus
        self.latestError = latestError
        self.isTemplate = isTemplate
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case latestHash = "latest_hash"
        case latestTaskID = "latest_task_id"
        case latestStatus = "latest_status"
        case latestError = "latest_error"
        case isTemplate = "is_template"
    }

    /// 容忍缺省：老 daemon / 一次性 run 的摘要可能没有 `is_template`，缺省为 false。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(Int64.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.description = try container.decode(String.self, forKey: .description)
        self.latestHash = try container.decodeIfPresent(String.self, forKey: .latestHash)
        self.latestTaskID = try container.decodeIfPresent(Int64.self, forKey: .latestTaskID)
        self.latestStatus = try container.decodeIfPresent(String.self, forKey: .latestStatus)
        self.latestError = try container.decodeIfPresent(String.self, forKey: .latestError)
        self.isTemplate = try container.decodeIfPresent(Bool.self, forKey: .isTemplate) ?? false
    }
}

/// 一个不可变定义版本。
public struct WorkflowVersionSummary: Decodable, Sendable, Identifiable, Equatable {
    public let id: Int64
    public let version: Int64
    public let hash: String
    public let createdAt: String

    public init(id: Int64, version: Int64, hash: String, createdAt: String) {
        self.id = id
        self.version = version
        self.hash = hash
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, version, hash
        case createdAt = "created_at"
    }
}

/// 一次 run 的记录（task id = `id`）。
public struct WorkflowRunSummary: Decodable, Sendable, Identifiable, Equatable {
    public let id: Int64
    public let status: String
    public let progress: Double
    public let error: String?
    public let createdAt: String

    public init(id: Int64, status: String, progress: Double = 0, error: String? = nil, createdAt: String = "") {
        self.id = id
        self.status = status
        self.progress = progress
        self.error = error
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, status, progress, error
        case createdAt = "created_at"
    }
}

/// `GET /v1/workspaces/{path}/workflows/{name}` — 定义元数据 + 版本历史 + run 历史。
public struct WorkflowDetail: Decodable, Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let description: String
    public let versions: [WorkflowVersionSummary]
    public let runs: [WorkflowRunSummary]
    /// 是否为用户命名的可复用模板。
    public let isTemplate: Bool
    /// 模板的源 manifest JSON（goal/template/agents[]/parallelism/timeout_ms），
    /// 保存模板时从 run 固化；一次性 run 为空。
    public let manifest: JSONValue?

    public init(
        id: Int64,
        name: String,
        description: String = "",
        versions: [WorkflowVersionSummary] = [],
        runs: [WorkflowRunSummary] = [],
        isTemplate: Bool = false,
        manifest: JSONValue? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.versions = versions
        self.runs = runs
        self.isTemplate = isTemplate
        self.manifest = manifest
    }

        enum CodingKeys: String, CodingKey {
        case id, name, description, versions, runs, manifest
        case isTemplate = "is_template"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(Int64.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.description = try container.decode(String.self, forKey: .description)
        self.versions = try container.decode([WorkflowVersionSummary].self, forKey: .versions)
        self.runs = try container.decodeIfPresent([WorkflowRunSummary].self, forKey: .runs) ?? []
        self.isTemplate = try container.decodeIfPresent(Bool.self, forKey: .isTemplate) ?? false
        self.manifest = try container.decodeIfPresent(JSONValue.self, forKey: .manifest)
    }
}

// MARK: - Manifest parsing (trigger form prefill)

/// 模板源 manifest 的轻量解析视图。字段全部可选：缺失/类型不符时降级为 nil。
public struct WorkflowManifest: Decodable, Sendable, Equatable {
    public let goal: String?
    public let template: String?
    public let agents: [WorkflowManifestAgent]?
    public let parallelism: Int?
    public let timeoutMs: Int64?

    public init(
        goal: String? = nil,
        template: String? = nil,
        agents: [WorkflowManifestAgent]? = nil,
        parallelism: Int? = nil,
        timeoutMs: Int64? = nil
    ) {
        self.goal = goal
        self.template = template
        self.agents = agents
        self.parallelism = parallelism
        self.timeoutMs = timeoutMs
    }

    enum CodingKeys: String, CodingKey {
        case goal, template, agents, parallelism
        case timeoutMs = "timeout_ms"
    }

    /// 从 detail.manifest（JSONValue）解析；非 object 或字段缺失返回 nil。
    public static func fromJSONValue(_ value: JSONValue?) -> WorkflowManifest? {
        guard let object = value?.object else { return nil }
        let agents: [WorkflowManifestAgent]? = object["agents"]?.array?.compactMap {
            WorkflowManifestAgent.fromJSONValue($0)
        }
        return WorkflowManifest(
            goal: object["goal"]?.string,
            template: object["template"]?.string,
            agents: (agents?.isEmpty == false) ? agents : nil,
            parallelism: Self.readInt(object["parallelism"]),
            timeoutMs: Self.readInt(object["timeout_ms"]).map(Int64.init)
        )
    }

    private static func readInt(_ value: JSONValue?) -> Int? {
        if let i = value?.int { return i }
        if let d = value?.number { return Int(d) }
        return nil
    }
}

/// manifest 里的单个 agent 摘要。
public struct WorkflowManifestAgent: Decodable, Sendable, Equatable {
    public let role: String?
    public let sessionID: String?
    public let message: String?
    public let intent: String?
    public let correlationID: String?
    public let workspacePath: String?

    public init(
        role: String? = nil,
        sessionID: String? = nil,
        message: String? = nil,
        intent: String? = nil,
        correlationID: String? = nil,
        workspacePath: String? = nil
    ) {
        self.role = role
        self.sessionID = sessionID
        self.message = message
        self.intent = intent
        self.correlationID = correlationID
        self.workspacePath = workspacePath
    }

    enum CodingKeys: String, CodingKey {
        case role, message, intent
        case sessionID = "session_id"
        case correlationID = "correlation_id"
        case workspacePath = "workspace_path"
    }

    public static func fromJSONValue(_ value: JSONValue?) -> WorkflowManifestAgent? {
        guard let object = value?.object else { return nil }
        return WorkflowManifestAgent(
            role: object["role"]?.string,
            sessionID: object["session_id"]?.string,
            message: object["message"]?.string,
            intent: object["intent"]?.string,
            correlationID: object["correlation_id"]?.string,
            workspacePath: object["workspace_path"]?.string
        )
    }
}

// MARK: - P2: save-as-template / parameterized trigger

/// `POST /v1/workflows/{name}/template?workspace=<abs_path>` body。
/// 把某次 run 保存为用户命名的可复用模板（manifest 从 source run 恢复）。
public struct WorkflowTemplateSaveRequest: Encodable, Sendable, Equatable {
    public var sourceTaskID: Int64
    public var description: String?

    public init(sourceTaskID: Int64, description: String? = nil) {
        self.sourceTaskID = sourceTaskID
        self.description = description
    }

    enum CodingKeys: String, CodingKey {
        case sourceTaskID = "source_task_id"
        case description
    }
}

/// `POST .../template` 的 201 响应 data：`{"name": "<模板名>"}`。
public struct WorkflowTemplateNameResponse: Decodable, Sendable, Equatable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

/// 触发请求里的单个 agent 花名册行（对齐 plan_workflow manifest 的 agents[]）。
public struct WorkflowAgentSpec: Encodable, Sendable, Equatable, Identifiable {
    public var role: String
    public var sessionID: String
    public var message: String
    /// "request" | "notification"
    public var intent: String
    public var correlationID: String
    /// 可选：worker 会话的目标 workspace（缺省用触发时的 workspace）。
    public var workspacePath: String?

    public var id: String { "\(role)#\(sessionID)#\(correlationID)" }

    public init(
        role: String,
        sessionID: String,
        message: String,
        intent: String = "request",
        correlationID: String,
        workspacePath: String? = nil
    ) {
        self.role = role
        self.sessionID = sessionID
        self.message = message
        self.intent = intent
        self.correlationID = correlationID
        self.workspacePath = workspacePath
    }

    enum CodingKeys: String, CodingKey {
        case role, message, intent
        case sessionID = "session_id"
        case correlationID = "correlation_id"
        case workspacePath = "workspace_path"
    }
}

/// `POST /v1/workflows/{name}/runs?workspace=<abs_path>` body（run input manifest）。
/// 服务端原样透传给引擎 Submit；202 返回 `{"task_id": <int>}`。
public struct WorkflowTriggerRequest: Encodable, Sendable, Equatable {
    public var goal: String
    /// 模板类型："cross_workspace_collaboration_v1" | "..._v2"
    public var template: String
    public var agents: [WorkflowAgentSpec]
    public var parallelism: Int?
    public var timeoutMs: Int64?

    public init(
        goal: String,
        template: String,
        agents: [WorkflowAgentSpec],
        parallelism: Int? = nil,
        timeoutMs: Int64? = nil
    ) {
        self.goal = goal
        self.template = template
        self.agents = agents
        self.parallelism = parallelism
        self.timeoutMs = timeoutMs
    }

    enum CodingKeys: String, CodingKey {
        case goal, template, agents, parallelism
        case timeoutMs = "timeout_ms"
    }
}

/// `POST .../runs` 的 202 响应 data：`{"task_id": <int>}`。
public struct WorkflowTriggeredResponse: Decodable, Sendable, Equatable {
    public let taskID: Int64

    public init(taskID: Int64) {
        self.taskID = taskID
    }

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
    }
}

/// `POST /v1/workflows/{name}/runs/{task_id}/resume?workspace=<abs_path>` body。
/// `resumeFrom` 为空 = 服务端自动收集失败根节点；202 返回 `{"task_id": <int>}`。
public struct WorkflowResumeRequest: Encodable, Sendable, Equatable {
    public var resumeFrom: String?

    public init(resumeFrom: String? = nil) {
        self.resumeFrom = resumeFrom
    }

    enum CodingKeys: String, CodingKey {
        case resumeFrom = "resume_from"
    }
}
