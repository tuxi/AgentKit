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
    case childStream(ChildStreamNodePayload)
}

// MARK: - Payloads

public struct MessageNodePayload: Sendable {
    public let role: MessageRole
    public let text: String
    public let isStreaming: Bool
    public let textAnnotations: [AgentTextAnnotation]

    public init(
        role: MessageRole,
        text: String,
        isStreaming: Bool = false,
        textAnnotations: [AgentTextAnnotation] = []
    ) {
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
        self.textAnnotations = textAnnotations
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
    public let structuredOutput: JSONValue?
    public let assets: [AgentAssetRef]
    public let exitCode: Int?
    public let elapsedMs: Int?
    public let isAutoApproved: Bool
    /// When non-nil, the tool produced an artifact — links to Inspector.
    public let artifact: ArtifactNode?

    public init(callID: String, toolName: String, args: JSONValue?,
                status: ToolNodeStatus, output: String = "",
                structuredOutput: JSONValue? = nil,
                assets: [AgentAssetRef] = [],
                exitCode: Int? = nil, elapsedMs: Int? = nil,
                isAutoApproved: Bool = false,
                artifact: ArtifactNode? = nil) {
        self.callID = callID
        self.toolName = toolName
        self.args = args
        self.status = status
        self.output = output
        self.structuredOutput = structuredOutput
        self.assets = assets
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

/// 子流入口卡（task 子agent / 后台 job）— 父时间线中的折叠卡片，
/// 点击展开子流查看器（macOS 右侧面板 / iOS sheet）。
public struct ChildStreamNodePayload: Sendable, Hashable {
    public let kind: ChildStreamKind
    public let childID: String
    /// task 的委派 prompt / job 的 command。
    public let title: String
    public let status: ChildStreamNodeStatus
    /// 结束后的结果摘要（task 结论 / job 收尾说明或错误）。
    public let result: String?
    public let exitCode: Int?
    /// job 任务总耗时（`job_finished.elapsed_ms`）。
    public let elapsedMs: Int?
    /// 累积输出（job 子流内部使用；父流入口卡不展示）。
    public let output: String

    public init(kind: ChildStreamKind, childID: String, title: String,
                status: ChildStreamNodeStatus, result: String? = nil,
                exitCode: Int? = nil, elapsedMs: Int? = nil, output: String = "") {
        self.kind = kind
        self.childID = childID
        self.title = title
        self.status = status
        self.result = result
        self.exitCode = exitCode
        self.elapsedMs = elapsedMs
        self.output = output
    }

    /// 人读耗时（对齐 `TurnStats.formattedElapsed` 的风格，分钟以上加 m 段）。
    public var formattedElapsed: String? {
        guard let ms = elapsedMs else { return nil }
        if ms >= 60_000 {
            let totalSeconds = ms / 1000
            return "\(totalSeconds / 60)m\(totalSeconds % 60)s"
        }
        if ms >= 1000 {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        }
        return "\(ms)ms"
    }
}

public enum ChildStreamNodeStatus: String, Sendable, Hashable {
    case running
    case completed
    case failed
    /// job 被主动取消（P8.7 §8.5 `text=="canceled"`）— 样式上区别于失败。
    case canceled
}
