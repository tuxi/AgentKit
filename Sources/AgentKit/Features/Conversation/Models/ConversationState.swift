//
//  ConversationState.swift
//  AgentKit
//
//  Turn State Machine — 第二代 reducer。
//  Event 只驱动状态变化，不参与 UI 构建。
//
//  协议约束：
//  - turn_id 是唯一 grouping key → Dictionary<turnID, TurnGroup>
//  - call_id 是 tool identity key → Dictionary<callID, ToolCallItem>
//  - event_id 禁止用于 UI 逻辑
//  - 禁止 UUID() 生成 UI key（turnID/callID 来自协议）
//

import Foundation

// MARK: - ConversationState

/// 一个会话的完整 Turn 状态机。由 `ConversationViewModel` 的 reducer 维护。
/// UI 直接从此结构读取，不消费原始 AgentEvent。
@MainActor
public struct ConversationState {

    // MARK: - Turn 列表

    /// 有序 display 列表（turnID 按发生顺序排列）。
    public var turnIDs: [String] = []

    /// turnID → TurnGroup 查找表（唯一 grouping key）。
    public var turns: [String: TurnGroup] = [:]

    /// 当前活跃 turn 的 turnID（至多一个；turn_finished 时清空）。
    public var currentTurnID: String?

    // MARK: - 全局状态

    /// 待审批请求（快速访问；同时也在 currentTurn.approvalRequests 中）。
    public var pendingApproval: ApprovalRequest?

    /// 最新 todo 快照。
    public var latestTodos: [TodoItem] = []

    /// 历史事件已回放完毕。
    public var historyReplayed: Bool = false

    // MARK: - 流式文本（便利字段）

    /// 当前 turn 的实时助手文本（token_delta 累积；turn_finished 锁定到 TurnGroup 后清空）。
    public var streamingText: String = ""

    // MARK: - Init

    public init() {}

    // MARK: - 访问器

    /// 当前活跃的 TurnGroup（若有）。
    public var currentTurn: TurnGroup? {
        guard let id = currentTurnID else { return nil }
        return turns[id]
    }

    /// 按 display 顺序的 TurnGroup 列表。
    public var orderedTurns: [TurnGroup] {
        turnIDs.compactMap { turns[$0] }
    }

    /// 当前 turn 的 artifact 列表（按 toolCallIDs 顺序）。
    public var currentArtifacts: [ArtifactNode] {
        guard let turn = currentTurn else { return [] }
        return turn.toolCallIDs.compactMap { turn.artifactGraph.nodes[$0] }
    }
}

// MARK: - TurnGroup

/// 一个 Turn — UI 的基本单位。
/// 包含从用户输入到助手回复的完整 Agent Work 循环。
public struct TurnGroup: Identifiable, Sendable {
    // MARK: - Identity

    public var id: String { turnID }
    /// 协议级 turn 标识符（`turn_id`），唯一 grouping key。
    public let turnID: String

    // MARK: - 生命周期

    public var status: TurnStatus

    // MARK: - 内容

    /// 用户输入（来自 `turn_started`）。
    public var userMessage: String

    /// 助手回复（`token_delta` 实时累积，`turn_finished` 时锁定）。
    public var assistantMessage: String

    /// 思考步骤列表。
    public var thoughts: [ThoughtItem]

    /// callID → ToolCallItem 查找表（call_id 是 tool identity）。
    public var toolCalls: [String: ToolCallItem]
    /// 有序 display 列表。
    public var toolCallIDs: [String]

    /// 审批请求列表。
    public var approvalRequests: [ApprovalItem]

    /// Todo 快照列表。
    public var todoSnapshots: [TodoSnapshot]

    /// Subagent 引用列表。
    public var subagentRefs: [SubagentItem]

    /// Artifact 语义图（v4.3: nodes + typed edges）。
    public var artifactGraph: ArtifactGraph

    // MARK: - Init

    public init(turnID: String, userMessage: String) {
        self.turnID = turnID
        self.userMessage = userMessage
        self.status = .active
        self.assistantMessage = ""
        self.thoughts = []
        self.toolCalls = [:]
        self.toolCallIDs = []
        self.approvalRequests = []
        self.todoSnapshots = []
        self.subagentRefs = []
        self.artifactGraph = ArtifactGraph()
    }
}

// MARK: - TurnStatus

public enum TurnStatus: Sendable, Hashable {
    /// turn 正在执行（可接收增量事件）。
    case active
    /// turn 已 checkpoint 并暂停，等待恢复。
    case paused
    /// turn 正在从 paused 状态恢复。
    case resuming
    /// turn 已正常完成。
    case completed
    /// turn 被取消。
    case cancelled
    /// turn 不可恢复失败。
    case failed
}

// MARK: - Sub-structs

/// 思考步骤（无协议级 id，UUID 仅用于 ForEach）。
public struct ThoughtItem: Identifiable, Sendable {
    public let id = UUID()
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

/// 工具调用项 — call_id 是协议级 tool identity。
/// `tool_started` + `tool_finished` = 同一个 ToolCallItem 的状态变化。
public struct ToolCallItem: Identifiable, Sendable {
    public var id: String { callID }
    /// 协议级工具调用标识符（`call_id`）。
    public let callID: String
    public let toolName: String
    public let toolArgs: JSONValue?
    public var status: ToolCallStatus
    /// `tool_finished` 时写入。
    public var result: ToolResult?

    public init(callID: String, toolName: String, toolArgs: JSONValue?) {
        self.callID = callID
        self.toolName = toolName
        self.toolArgs = toolArgs
        self.status = .running
        self.result = nil
    }
}

public enum ToolCallStatus: Sendable, Hashable {
    case running
    case completed
    case failed
}

/// 审批请求项 — id 来自协议 `approval_request.id`。
public struct ApprovalItem: Identifiable, Sendable {
    public var id: String { request.id }
    public let request: ApprovalRequest
    public var resolved: Bool
    public var approved: Bool?

    public init(request: ApprovalRequest) {
        self.request = request
        self.resolved = false
        self.approved = nil
    }
}

/// Todo 快照。
public struct TodoSnapshot: Identifiable, Sendable {
    public let id = UUID()
    public let todos: [TodoItem]

    public init(todos: [TodoItem]) {
        self.todos = todos
    }
}

/// Subagent 引用。
public struct SubagentItem: Identifiable, Sendable {
    public let id = UUID()
    public let sessionID: String
    public let prompt: String
    public var result: String?

    public init(sessionID: String, prompt: String) {
        self.sessionID = sessionID
        self.prompt = prompt
        self.result = nil
    }
}

// MARK: - Reducer（第二代）

extension ConversationState {

    /// 处理一个 `AgentEvent`，原地更新 Turn 状态机。
    /// 调用此方法后，UI 通过 SwiftUI 的 `@Observable` 自动重绘。
    public mutating func reduce(_ event: AgentEvent) {
        switch event {
        // ── Turn 生命周期 ──

        case .turnStarted(let turnID, let text):
            let turn = TurnGroup(turnID: turnID, userMessage: text)
            turns[turnID] = turn
            turnIDs.append(turnID)
            currentTurnID = turnID
            streamingText = ""

        case .turnFinished(let turnID, let text, _):
            guard var turn = turns[turnID] else { return }
            if !text.isEmpty {
                turn.assistantMessage = text
            } else if !streamingText.isEmpty {
                turn.assistantMessage = streamingText
            }
            turn.status = .completed
            turns[turnID] = turn
            if currentTurnID == turnID {
                currentTurnID = nil
            }
            streamingText = ""

        case .turnPaused(let turnID, _, _):
            guard let tid = turnID ?? currentTurnID,
                  var turn = turns[tid] else { return }
            turn.status = .paused
            turns[tid] = turn
            if currentTurnID == tid {
                currentTurnID = nil
            }

        case .turnResumed(let turnID, _):
            guard let tid = turnID,
                  var turn = turns[tid] else { return }
            turn.status = .resuming
            turns[tid] = turn
            currentTurnID = tid

        case .turnFailed(let turnID, let text, let err):
            guard let tid = turnID ?? currentTurnID,
                  var turn = turns[tid] else { return }
            if let text, !text.isEmpty {
                turn.assistantMessage = text
            } else if let err, !err.isEmpty {
                turn.assistantMessage = err
            }
            turn.status = .failed
            turns[tid] = turn
            if currentTurnID == tid {
                currentTurnID = nil
            }
            streamingText = ""

        // ── 流式文本 ──

        case .tokenDelta(let turnID, let text):
            let tid = turnID ?? currentTurnID
            guard let tid, var turn = turns[tid] else { return }
            streamingText += text
            turn.assistantMessage += text
            turns[tid] = turn

        // ── 思考 ──

        case .thinking(let turnID, let text):
            let tid = turnID ?? currentTurnID
            guard let tid, var turn = turns[tid] else { return }
            turn.thoughts.append(ThoughtItem(text: text))
            turns[tid] = turn

        // ── 模型 ──

        case .modelStarted:
            break // no-op (new invocationID field ignored by legacy state)

        case .modelFinished:
            break // no-op

        // ── 工具（call_id state update）──

        case .toolStarted(let turnID, let callID, let tool):
            let tid = turnID ?? currentTurnID
            guard let tid, var turn = turns[tid] else { return }
            let item = ToolCallItem(callID: callID, toolName: tool.toolName, toolArgs: tool.toolArgs)
            turn.toolCalls[callID] = item
            if !turn.toolCallIDs.contains(callID) {
                turn.toolCallIDs.append(callID)
            }
            turns[tid] = turn

        case .toolFinished(let turnID, let callID, let result):
            let tid = turnID ?? currentTurnID
            guard let tid, var turn = turns[tid],
                  var item = turn.toolCalls[callID] else { return }
            item.result = result
            item.status = result.error == nil ? .completed : .failed
            turn.toolCalls[callID] = item
            // 语义编译 + 图更新（v4.3: upsert node + build cross-reference edges）
            if let node = ToolSemanticCompiler.compile(item, turnID: tid) {
                turn.artifactGraph.upsert(node)
                buildCrossReferenceEdges(for: node, in: &turn)
            }
            turns[tid] = turn

        // ── 审批 ──

        case .planApprovalRequest:
            break // no-op — plan approval handled by RuntimeEngine

        case .approvalRequest(let turnID, let request):
            let tid = turnID ?? currentTurnID
            if let tid, var turn = turns[tid] {
                turn.approvalRequests.append(ApprovalItem(request: request))
                turns[tid] = turn
            }
            pendingApproval = request

        // ── Todo ──

        case .todoUpdated(let turnID, let todos):
            latestTodos = todos
            let tid = turnID ?? currentTurnID
            if let tid, var turn = turns[tid] {
                turn.todoSnapshots.append(TodoSnapshot(todos: todos))
                turns[tid] = turn
            }

        // ── Subagent ──

        case .taskStarted(let turnID, let sessionId, _, let text):
            let tid = turnID ?? currentTurnID
            guard let tid, var turn = turns[tid] else { return }
            turn.subagentRefs.append(SubagentItem(sessionID: sessionId, prompt: text))
            turns[tid] = turn

        case .taskFinished(let turnID, let sessionId, _, let text):
            let tid = turnID ?? currentTurnID
            guard let tid, var turn = turns[tid] else { return }
            if let idx = turn.subagentRefs.firstIndex(where: { $0.sessionID == sessionId }) {
                turn.subagentRefs[idx].result = text
                turns[tid] = turn
            }

        // ── Background job（P8.7，与 subagent 同一引用列表）──

        case .jobStarted(let turnID, let jobID, let command):
            let tid = turnID ?? currentTurnID
            guard let tid, var turn = turns[tid] else { return }
            turn.subagentRefs.append(SubagentItem(sessionID: jobID, prompt: command))
            turns[tid] = turn

        case .jobFinished(let turnID, let jobID, _, let err, let text):
            let tid = turnID ?? currentTurnID
            guard let tid, var turn = turns[tid] else { return }
            if let idx = turn.subagentRefs.firstIndex(where: { $0.sessionID == jobID }) {
                // §8.5：text 是状态枚举（exited/failed/canceled），不是人读摘要；
                // 展示文案用 err（失败时冗余退出码），成功时无摘要可存。
                turn.subagentRefs[idx].result = (err?.isEmpty == false) ? err
                    : (text == "exited" ? nil : text)
                turns[tid] = turn
            }

        case .jobOutput:
            break // 输出分块只属于子流自己的 transcript

        // ── 上下文 ──

        case .reflected:
            break // no-op（暂不参与 Turn 结构）

        case .compacted:
            break // no-op（压缩事件不产生 UI）

        // ── 其他 ──

        case .toolStdout, .toolStderr, .observed, .autoApproved, .skillLoaded:
            break // no-op（暂不参与 Turn 结构）
        }
    }

    /// 审批处理完毕后清除待审批状态。
    public mutating func clearApproval() {
        guard let req = pendingApproval else { return }
        // 标记对应的 ApprovalItem 为已处理
        // 找到包含此 approval 的 turn
        for turnID in turnIDs {
            if let idx = turns[turnID]?.approvalRequests.firstIndex(where: { $0.id == req.id }) {
                turns[turnID]?.approvalRequests[idx].resolved = true
                break
            }
        }
        pendingApproval = nil
    }

    /// 标记审批结果为已批准/已拒绝。
    public mutating func resolveApproval(id: String, approved: Bool) {
        for turnID in turnIDs {
            if let idx = turns[turnID]?.approvalRequests.firstIndex(where: { $0.id == id }) {
                turns[turnID]?.approvalRequests[idx].resolved = true
                turns[turnID]?.approvalRequests[idx].approved = approved
                break
            }
        }
        if pendingApproval?.id == id {
            pendingApproval = nil
        }
    }

    /// v4.3: 为新节点建立与同 turn 已有节点的交叉引用边。
    /// 规则：相同 filePath → `.references`
    private mutating func buildCrossReferenceEdges(for node: ArtifactNode, in turn: inout TurnGroup) {
        let newPath = extractReferencedPath(from: node)
        guard let newPath else { return }

        for existing in turn.artifactGraph.allNodes where existing.callID != node.callID {
            if let existingPath = extractReferencedPath(from: existing), existingPath == newPath {
                turn.artifactGraph.addEdge(ArtifactEdge(
                    from: node.callID, to: existing.callID, type: .references
                ))
            }
        }
    }

    /// 从 ArtifactNode 提取被引用的文件路径（用于边构建匹配）。
    private func extractReferencedPath(from node: ArtifactNode) -> String? {
        node.path
    }
}
