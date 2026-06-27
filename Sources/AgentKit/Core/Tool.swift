//
//  Tool.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/6/24.
//

import Foundation

// MARK: - ToolCall

/// 工具调用开始事件（对应 `tool_started` 的 payload）。
public struct ToolCall: Sendable, Hashable {
    /// 协议级工具调用标识符（`call_id`），tool 卡片生命周期唯一 key。
    public let callID: String
    public let toolName: String
    /// 结构化 JSON 对象，如 `{"command": "git push"}`。
    public let toolArgs: JSONValue?
    /// v1.1：工具执行位置。"server"（默认）| "client"。
    public let executor: ToolExecutor

    public init(callID: String, toolName: String, toolArgs: JSONValue?, executor: ToolExecutor = .server) {
        self.callID = callID
        self.toolName = toolName
        self.toolArgs = toolArgs
        self.executor = executor
    }
}

/// 工具执行位置。
public enum ToolExecutor: String, Sendable, Hashable {
    case server
    case client
}

// MARK: - ToolResult

/// 工具调用结束事件（对应 `tool_finished` 的 payload）。
public struct ToolResult: Sendable, Hashable {
    /// 协议级工具调用标识符（`call_id`），与对应 `ToolCall` 匹配。
    public let callID: String
    public let toolName: String
    /// 工具输出文本。
    public let observation: String?
    /// 错误信息（工具执行失败时非空）。
    public let error: String?
    /// 工具执行耗时（毫秒），服务端 P2 新增。
    public let elapsedMs: Int?

    public init(callID: String, toolName: String, observation: String?, error: String?, elapsedMs: Int? = nil) {
        self.callID = callID
        self.toolName = toolName
        self.observation = observation
        self.error = error
        self.elapsedMs = elapsedMs
    }
}

// MARK: - Todo

/// 任务条目（对应 `todo_updated` 事件）。
public struct TodoItem: Sendable, Hashable, Codable {
    public let content: String
    /// 进行中形态的文案，如 "writing wire.go"，可缺省。
    public let activeForm: String?
    public let status: TodoStatus

    public init(content: String, activeForm: String? = nil, status: TodoStatus) {
        self.content = content
        self.activeForm = activeForm
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case content, status
        case activeForm = "active_form"
    }
}

public enum TodoStatus: String, Sendable, Hashable, Codable {
    case pending
    case inProgress = "in_progress"
    case completed
}
