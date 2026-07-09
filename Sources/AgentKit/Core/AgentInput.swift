//
//  AgentInput.swift
//  AgentKit
//
//  Structured agent input model — replaces sendMessage(String).
//  Semantic: input = execution graph continuation edge, not chat message.
//
//  Protocol: AgentKit Runtime Protocol v1.1 §AgentInput
//

import Foundation

// MARK: - AgentInput

/// 结构化 Agent 输入。替代 `sendMessage(String)`。
///
/// ## 语义
/// `AgentInput` 不是"用户消息"，而是 **execution graph continuation edge**：
/// - `.text` — 用户文本输入
/// - `.toolResult` — 工具执行结果回传（graph continuation）
/// - `.command` — 系统命令（cancel / switch_model）
/// - `.system` — 结构化系统指令（context injection / memory / plan）
///
/// ## 扩展
/// `metadata` 是 P0 预留的扩展槽，P1 将收敛 schema。
public struct AgentInput: Sendable {

    // MARK: - Kind

    public enum Kind: Sendable {
        /// 用户文本输入。
        case text
        /// 工具执行结果回传 — execution graph continuation edge。
        case toolResult
        /// 系统命令（如 cancel / switch_model）。
        case command
        /// 结构化系统指令。P1 收敛具体 command schema。
        case system(SystemCommand)
    }

    // MARK: - Fields

    public var kind: Kind
    public var text: String?
    public var toolResult: ToolResultContent?
    /// 当前轮使用的模型（Gateway 模型 ID 或 config alias）。为空时 Runtime 使用 default_model。
    public var model: String?
    /// 扩展元数据。P1 收敛 schema，P0 仅保留扩展点。
    public var metadata: [String: String]?

    // MARK: - Convenience factories

    public static func text(_ text: String, model: String? = nil) -> AgentInput {
        AgentInput(kind: .text, text: text, model: model)
    }

    public static func toolResult(_ result: ToolResultContent) -> AgentInput {
        AgentInput(kind: .toolResult, toolResult: result)
    }

    public static func command(_ cmd: String) -> AgentInput {
        AgentInput(kind: .command, text: cmd)
    }

    public static func system(_ cmd: SystemCommand, metadata: [String: String]? = nil) -> AgentInput {
        AgentInput(kind: .system(cmd), metadata: metadata)
    }

    // MARK: - Init

    public init(
        kind: Kind = .text,
        text: String? = nil,
        toolResult: ToolResultContent? = nil,
        model: String? = nil,
        metadata: [String: String]? = nil
    ) {
        self.kind = kind
        self.text = text
        self.toolResult = toolResult
        self.model = model
        self.metadata = metadata
    }
}

// MARK: - SystemCommand

/// 系统级指令。P0 定义语义框架，P1 收敛具体 command schema。
///
/// 设计约束：不放任自由字符串，避免 `system` 变成语义垃圾桶。
public enum SystemCommand: Sendable {
    /// 注入上下文（如 memory / project rules）。
    case patchContext(key: String, value: String)
    /// 更新 memory。
    case updateMemory(key: String, value: String)
    /// 覆盖当前 plan。
    case overridePlan(planID: String)
}

// MARK: - ToolResultContent

/// 工具执行结果 — execution graph edge payload。
///
/// `toolUseID` 对应 `tool_started` 事件的 `call_id`，
/// 是 agent 将工具结果关联到调用上下文的唯一键。
public struct ToolResultContent: Sendable {
    /// 对应 `tool_started` 的 `call_id` — execution graph edge identity。
    public let toolUseID: String
    /// 工具输出文本。
    public let content: String
    /// Tool-specific structured side-channel from agent-wire v1.3.
    public let output: JSONValue?
    /// Normalized clickable asset references from agent-wire v1.3.
    public let assets: [AgentAssetRef]
    /// `true` = 工具执行失败，agent 应据此决定重试策略。
    public let isError: Bool

    public init(
        toolUseID: String,
        content: String,
        isError: Bool = false,
        output: JSONValue? = nil,
        assets: [AgentAssetRef] = []
    ) {
        self.toolUseID = toolUseID
        self.content = content
        self.output = output
        self.assets = assets
        self.isError = isError
    }
}
