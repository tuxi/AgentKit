//
//  AgentEvent.swift
//  AgentKit
//
//  Typed event enum — the UI-facing event model.
//  协议约束：turn_id 是唯一 grouping key，call_id 是 tool identity key。
//  Converted from WireFrame by AgentWireSocket.
//  对照：`docs/client_integration_v1.md` §3.3、§3.4。
//

import Foundation

// MARK: - AgentEvent

/// UI 层消费的事件。由 `AgentWireSocket` 从原始 JSON 帧解码并转换。
/// `turnID` 和 `callID` 来自协议层，是 ConversationState reducer 的唯一 key。
public enum AgentEvent: Sendable {
    // ── Turn 生命周期 ──
    /// `turn_started`：新 turn 开始。`turnID` 是 grouping key。
    case turnStarted(turnID: String, text: String)
    /// `turn_finished`：当前 turn 结束。
    case turnFinished(turnID: String, text: String)

    // ── 模型 ──
    case modelStarted(turnID: String?, invocationID: String?)
    case modelFinished(turnID: String?, promptTokens: Int?, elapsedMs: Int?, err: String?)

    // ── 流式文本 ──
    case tokenDelta(turnID: String?, text: String)
    case thinking(turnID: String?, text: String)

    // ── 工具（call_id 是 tool identity）──
    case toolStarted(turnID: String?, callID: String, tool: ToolCall)
    case toolFinished(turnID: String?, callID: String, result: ToolResult)
    case toolStdout(turnID: String?, callID: String, chunk: String)
    case toolStderr(turnID: String?, callID: String, chunk: String)
    case observed(turnID: String?, callID: String?, step: Int, toolName: String, observation: String?, failure: String?)
    case autoApproved(turnID: String?, toolName: String, toolArgs: JSONValue?, text: String?)

    // ── Skill ──
    case skillLoaded(toolName: String, skillVersion: String?)

    // ── Todo ──
    case todoUpdated(turnID: String?, todos: [TodoItem])

    // ── Subagent ──
    case taskStarted(turnID: String?, sessionId: String, parentSessionId: String, text: String)
    case taskFinished(turnID: String?, sessionId: String, parentSessionId: String, text: String)

    // ── 上下文 ──
    case reflected(turnID: String?, text: String)
    case compacted(turnID: String?, beforeTokens: Int, afterTokens: Int, savedTokens: Int, summaryChars: Int, ratio: Double)

    // ── 审批 ──
    case approvalRequest(turnID: String?, request: ApprovalRequest)
    case planApprovalRequest(turnID: String?, request: PlanApprovalRequest)
}

// MARK: - WireFrame → AgentEvent conversion

extension AgentEvent {
    /// 从 `WireFrame` 构造 `AgentEvent`。`kind` 不匹配时返回 `nil`（前向兼容：忽略未知 kind）。
    static func from(wire: WireFrame) -> AgentEvent? {
        guard let kind = wire.kind else { return nil }

        // turnID: 来自协议 turn_id 字段
        let turnID = wire.turnId

        // callID: 来自协议 call_id 字段，或由 step 生成
        let callID = wire.callId ?? wire.step.map { "call_\($0)" }

        switch kind {
        case "turn_started":
            return .turnStarted(turnID: turnID ?? "", text: wire.text ?? "")

        case "turn_finished":
            return .turnFinished(turnID: turnID ?? "", text: wire.text ?? "")

        case "model_started":
            return .modelStarted(turnID: turnID, invocationID: wire.invocationId)

        case "model_finished":
            return .modelFinished(
                turnID: turnID,
                promptTokens: wire.promptTokens,
                elapsedMs: wire.elapsedMs,
                err: wire.err
            )

        case "token_delta":
            return .tokenDelta(turnID: turnID, text: wire.text ?? "")

        case "thinking":
            return .thinking(turnID: turnID, text: wire.text ?? "")

        case "tool_started":
            let executor = ToolExecutor(rawValue: wire.executor ?? "") ?? .server
            let tool = ToolCall(
                callID: callID ?? "",
                toolName: wire.toolName ?? "unknown",
                toolArgs: wire.toolArgs,
                executor: executor
            )
            return .toolStarted(turnID: turnID, callID: callID ?? "", tool: tool)

        case "tool_stdout":
            return .toolStdout(turnID: turnID, callID: callID ?? "", chunk: wire.chunk ?? "")

        case "tool_stderr":
            return .toolStderr(turnID: turnID, callID: callID ?? "", chunk: wire.chunk ?? "")

        case "tool_finished":
            let result = ToolResult(
                callID: callID ?? "",
                toolName: wire.toolName ?? "unknown",
                observation: wire.observation.normalized,
                error: wire.err.normalized,
                elapsedMs: wire.elapsedMs
            )
            return .toolFinished(turnID: turnID, callID: callID ?? "", result: result)

        case "observed":
            return .observed(
                turnID: turnID,
                callID: callID,
                step: wire.step ?? 0,
                toolName: wire.toolName ?? "unknown",
                observation: wire.observation.normalized,
                failure: wire.failure.normalized
            )

        case "auto_approved":
            return .autoApproved(
                turnID: turnID,
                toolName: wire.toolName ?? "unknown",
                toolArgs: wire.toolArgs,
                text: wire.text
            )

        case "skill_loaded":
            return .skillLoaded(
                toolName: wire.toolName ?? "unknown",
                skillVersion: wire.skillVersion
            )

        case "todo_updated":
            let items = (wire.todos ?? []).map { todo in
                TodoItem(
                    content: todo.content,
                    activeForm: todo.activeForm,
                    status: TodoStatus(rawValue: todo.status) ?? .pending
                )
            }
            return .todoUpdated(turnID: turnID, todos: items)

        case "task_started":
            return .taskStarted(
                turnID: turnID,
                sessionId: wire.sessionId ?? "",
                parentSessionId: wire.parentSessionId ?? "",
                text: wire.text ?? ""
            )

        case "task_finished":
            return .taskFinished(
                turnID: turnID,
                sessionId: wire.sessionId ?? "",
                parentSessionId: wire.parentSessionId ?? "",
                text: wire.text ?? ""
            )

        case "reflected":
            return .reflected(turnID: turnID, text: wire.text ?? "")

        case "compacted":
            return .compacted(
                turnID: turnID,
                beforeTokens: wire.beforeTokens ?? 0,
                afterTokens: wire.afterTokens ?? 0,
                savedTokens: wire.savedTokens ?? 0,
                summaryChars: wire.summaryChars ?? 0,
                ratio: wire.ratio ?? 0
            )

        default:
            // 前向兼容：忽略未知 kind，不崩
            return nil
        }
    }
}

// MARK: - Wire value normalization

/// 将服务端 sentinel 值规范化：nil / "" / "none" → nil。
private extension Optional where Wrapped == String {
    var normalized: String? {
        guard let self else { return nil }
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.lowercased() != "none" else { return nil }
        return self
    }
}
