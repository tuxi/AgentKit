//
//  WireFrame.swift
//  AgentKit
//
//  Raw Codable envelope for agent-wire v1 JSON frames.
//  Internal to Core — never exposed to UI.
//

import Foundation

// MARK: - Raw wire frame

/// 一帧的原始 JSON 结构。所有字段可选；通过 `type` vs `kind` 分流。
/// 对照：`docs/client_integration_v1.md` §3.1、§3.3、§3.4。
struct WireFrame: Decodable {
    // ── 控制帧字段（有 `type`）──
    let type: String?
    let id: String?
    let protocolVersion: Int?
    let server: String?
    let deadlineMs: Int?

    // ── 事件帧字段（有 `kind`）──
    let kind: String?
    let at: String?
    /// v1.2 §4：会话内单调递增的持久化序号（**有空洞**，底层是共享自增 rowid）。
    /// 增量续传游标 = 已收到帧里最大的 seq。`token_delta` 不带 seq（瞬态不持久化）。
    let seq: Int?
    let eventId: String?
    let sessionId: String?
    let parentSessionId: String?
    let turnId: String?
    let callId: String?
    let step: Int?
    let toolName: String?
    let toolArgs: JSONValue?
    let observation: String?
    let output: JSONValue?
    let assets: [AgentAssetRef]?
    let textAnnotations: [AgentTextAnnotation]?
    let failure: String?
    let planId: String?
    let title: String?
    let content: String?
    let skillVersion: String?
    let todos: [WireTodo]?
    let text: String?
    let promptTokens: Int?
    let elapsedMs: Int?
    let beforeTokens: Int?
    let afterTokens: Int?
    let savedTokens: Int?
    let summaryChars: Int?
    let ratio: Double?
    let chunk: String?
    let err: String?
    /// v1.2 §5.1：`turn_failed` 结构化错误 `{code, message}`。`code` 是开放集合（如 `auth_expired`）。
    let error: WireErrorDetail?
    let executor: String?           // v1.1: "server" | "client" (tool_started)
    let capabilities: [String]?     // v1.1: hello 帧声明的能力列表
    let invocationId: String?       // v1.2: 同一个模型调用产生的所有事件共享此 ID
    let turnStatus: String?         // v1.2 lifecycle status
    let pausedAt: Int64?            // v1.2 unix seconds
    let exitCode: Int?              // P8.7 §8.5（golden 已冻结）：仅失败时出现；>0 = 非零退出，-1 = 启动失败/被信号杀死

    enum CodingKeys: String, CodingKey {
        case type, kind, at, step, id, server, seq
        case text, observation, output, assets, failure, err, error, ratio, todos, chunk
        case textAnnotations = "text_annotations"
        case eventId = "event_id"
        case sessionId = "session_id"
        case parentSessionId = "parent_session_id"
        case turnId = "turn_id"
        case callId = "call_id"
        case invocationId = "invocation_id"
        case turnStatus = "turn_status"
        case pausedAt = "paused_at"
        case exitCode = "exit_code"
        case toolName = "tool_name"
        case toolArgs = "tool_args"
        case planId = "plan_id"
        case title, content
        case skillVersion = "skill_version"
        case promptTokens = "prompt_tokens"
        case elapsedMs = "elapsed_ms"
        case beforeTokens = "before_tokens"
        case afterTokens = "after_tokens"
        case savedTokens = "saved_tokens"
        case summaryChars = "summary_chars"
        case protocolVersion = "protocol_version"
        case deadlineMs = "deadline_ms"
        case executor
        case capabilities
    }
}

// MARK: - Wire error detail

/// `turn_failed` 携带的结构化错误（runtime-event-contract-v1 §5.1）。
struct WireErrorDetail: Decodable {
    let code: String?
    let message: String?
}

// MARK: - Wire todo

struct WireTodo: Decodable {
    let content: String
    let activeForm: String?
    let status: String

    enum CodingKeys: String, CodingKey {
        case content, status
        case activeForm = "active_form"
    }
}

// MARK: - Outgoing message encodable structs

/// 出站：AgentInput wire encoding（v1.1）。
/// 替代 `OutgoingSendMessage`，支持结构化输入。
struct OutgoingAgentInput: Encodable {
    let type = "agent_input"
    let kind: String                // "text" | "tool_result" | "command" | "system"
    let text: String?
    let toolResult: OutgoingToolResult?
    let model: String?              // per-message model selection (v1.4)
    let metadata: [String: String]?
    // system command fields
    let command: String?            // system command name
    let commandKey: String?
    let commandValue: String?

    enum CodingKeys: String, CodingKey {
        case type, kind, text, metadata, command, model
        case toolResult = "tool_result"
        case commandKey = "command_key"
        case commandValue = "command_value"
    }

    /// 从 `AgentInput` 编码。
    static func from(input: AgentInput) -> OutgoingAgentInput {
        switch input.kind {
        case .text:
            return OutgoingAgentInput(
                kind: "text", text: input.text, toolResult: nil, model: input.model,
                metadata: input.metadata, command: nil, commandKey: nil, commandValue: nil
            )
        case .toolResult:
            let tr = input.toolResult.map {
                OutgoingToolResult(
                    toolUseID: $0.toolUseID,
                    content: $0.content,
                    output: $0.output,
                    assets: $0.assets,
                    isError: $0.isError
                )
            }
            return OutgoingAgentInput(
                kind: "tool_result", text: nil, toolResult: tr, model: input.model,
                metadata: input.metadata, command: nil, commandKey: nil, commandValue: nil
            )
        case .command:
            return OutgoingAgentInput(
                kind: "command", text: input.text, toolResult: nil, model: input.model,
                metadata: input.metadata, command: nil, commandKey: nil, commandValue: nil
            )
        case .system(let cmd):
            switch cmd {
            case .patchContext(let key, let value):
                return OutgoingAgentInput(
                    kind: "system", text: nil, toolResult: nil, model: input.model,
                    metadata: input.metadata,
                    command: "patch_context", commandKey: key, commandValue: value
                )
            case .updateMemory(let key, let value):
                return OutgoingAgentInput(
                    kind: "system", text: nil, toolResult: nil, model: input.model,
                    metadata: input.metadata,
                    command: "update_memory", commandKey: key, commandValue: value
                )
            case .overridePlan(let planID):
                return OutgoingAgentInput(
                    kind: "system", text: nil, toolResult: nil, model: input.model,
                    metadata: input.metadata,
                    command: "override_plan", commandKey: nil, commandValue: planID
                )
            }
        }
    }
}

/// 出站：toolResult payload。
struct OutgoingToolResult: Encodable {
    let toolUseID: String
    let content: String
    let output: JSONValue?
    let assets: [AgentAssetRef]
    let isError: Bool

    enum CodingKeys: String, CodingKey {
        case content, output, assets
        case toolUseID = "tool_use_id"
        case isError = "is_error"
    }
}

/// 出站：向服务端注册客户端工具（握手后立即发送）。
struct OutgoingRegisterTools: Encodable {
    let type = "register_tools"
    let tools: [OutgoingClientToolDef]
}

struct OutgoingClientToolDef: Encodable {
    let name: String
    let description: String
    let inputSchema: JSONValue?

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }
}

/// 出站：驱动一个 turn（v1 兼容）。
@available(*, deprecated, message: "Use OutgoingAgentInput")
struct OutgoingSendMessage: Encodable {
    let type = "send_message"
    let text: String
}

/// 出站：取消当前 turn。
struct OutgoingCancelTurn: Encodable {
    let type = "cancel_turn"
}

/// 出站：审批回复（v1.2 三态：decision + scope）。
/// 向后兼容：老客户端只发 `approved` 布尔仍可工作。
struct OutgoingApprovalResponse: Encodable {
    let type = "approval_response"
    let id: String
    /// 兼容字段。`decision` 存在时服务端忽略此字段。
    var approved: Bool? = nil
    /// v1.2 三态决策："once" | "always" | "deny"。存在时优先于 `approved`。
    var decision: String? = nil
    /// v1.2 作用域："local"（项目本地，默认）或 "user"（全局）。
    /// 仅 `decision = "always"` 时有意义。
    var scope: String? = nil

    /// 兼容初始化（两态布尔）。
    init(id: String, approved: Bool) {
        self.id = id
        self.approved = approved
    }

    /// v1.2 三态初始化。
    init(id: String, decision: String, scope: String? = nil) {
        self.id = id
        self.decision = decision
        self.scope = scope
    }

    enum CodingKeys: String, CodingKey {
        case type, id, approved, decision, scope
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(id, forKey: .id)
        // 只编码非 nil 字段：decision 优先于 approved
        if let decision {
            try container.encode(decision, forKey: .decision)
            try container.encodeIfPresent(scope, forKey: .scope)
        } else if let approved {
            try container.encode(approved, forKey: .approved)
        } else {
            // 不可达：两个 init 保证至少设置其一
            assertionFailure("OutgoingApprovalResponse: both decision and approved are nil — must set one")
        }
    }
}

/// 出站：计划审批回复。
struct OutgoingPlanApprovalResponse: Encodable {
    let type = "plan_approval_response"
    let id: String
    let approved: Bool
}
