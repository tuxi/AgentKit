//
//  ApprovalRequest.swift
//  AgentKit
//
//  DTO for `approval_request` control frames.
//  对照：`docs/client_integration_v1.md` §3.4。
//

import Foundation

/// 审批请求：服务端推给客户端，要求用户确认副作用操作。
/// `id` 是关联键 — 回复 `approval_response` 时必须原样带回。
public struct ApprovalRequest: Sendable, Identifiable, Hashable {
    public let id: String
    public let toolName: String
    /// 结构化 JSON 对象，如 `{"command": "git push"}`。
    public let toolArgs: JSONValue?
    /// 超时毫秒数；deadline 内不回复视为拒绝。
    public let deadlineMs: Int?
    /// v1 可能缺省（审批器当前无 turn 上下文），按可选处理。
    public let sessionId: String?
    public let turnId: String?
    
    public init(
        id: String,
        toolName: String,
        toolArgs: JSONValue?,
        deadlineMs: Int?,
        sessionId: String?,
        turnId: String?
    ) {
        self.id = id
        self.toolName = toolName
        self.toolArgs = toolArgs
        self.deadlineMs = deadlineMs
        self.sessionId = sessionId
        self.turnId = turnId
    }

    /// 从 WireFrame 构造。
    static func from(wire: WireFrame) -> ApprovalRequest? {
        guard wire.type == "approval_request", let id = wire.id else { return nil }
        return ApprovalRequest(
            id: id,
            toolName: wire.toolName ?? "unknown",
            toolArgs: wire.toolArgs,
            deadlineMs: wire.deadlineMs,
            sessionId: wire.sessionId,
            turnId: wire.turnId
        )
    }

    // MARK: - MCP tool name display

    /// 是否为 MCP 外部工具（`tool_name` 以 `mcp__` 开头）。
    public var isMCP: Bool { toolName.hasPrefix("mcp__") }
    
    /// MCP server 名（第一个 `__` 之前的字符串），非 MCP 工具返回 nil。
    /// 例：`mcp__github__list_issues` → `"github"`。
    public var mcpServer: String? {
        guard isMCP else { return nil }
        let withoutPrefix = String(toolName.dropFirst(5)) // drop "mcp__"
        guard let separatorRange = withoutPrefix.range(of: "__") else { return nil }
        return String(withoutPrefix[..<separatorRange.lowerBound])
    }
    
    /// MCP 工具裸名（去掉 `mcp__<server>__` 前缀），非 MCP 工具返回原始 toolName。
    /// 例：`mcp__github__list_issues` → `"list_issues"`。
    public var mcpBareToolName: String {
        guard isMCP, let server = mcpServer else { return toolName }
        let prefix = "mcp__\(server)__"
        return String(toolName.dropFirst(prefix.count))
    }
    
    /// UI 展示用的工具名：MCP 工具显示为 `"MCP: server → tool"`，内置工具显示原始名。
    public var displayToolName: String {
        guard let server = mcpServer else { return toolName }
        return "MCP: \(server) → \(mcpBareToolName)"
    }
    
    /// 是否为外部路径访问审批（`tool_name == "external_path_access"`）。
    public var isExternalPathAccess: Bool {
        toolName == "external_path_access"
    }
    
    /// 外部路径访问操作的中文描述。
    public var externalPathOperation: String {
        guard isExternalPathAccess,
              case .object(let dict) = toolArgs,
              case .string(let op) = dict["operation"] else { return "访问" }
        switch op {
        case "list": return "列出目录"
        case "read": return "读取文件"
        default: return "访问"
        }
    }
    
    /// 外部路径访问的目标路径。
    public var externalPathTarget: String {
        guard isExternalPathAccess,
              case .object(let dict) = toolArgs,
              case .string(let path) = dict["path"] else { return "未知路径" }
        return path
    }

    /// "Always allow" 按钮的提示文案。
    /// MCP 工具：`"Always allow all tools from \"\(server)\""`
    /// 内置工具：`"Always allow \"\(toolName)\""`
    public var alwaysAllowPrompt: String {
        if let server = mcpServer {
            return "Always allow all tools from \"\(server)\""
        }
        return "Always allow \"\(toolName)\""
    }
}

// MARK: - PlanApprovalRequest

/// Plan Mode 审批请求：模型调用 propose_plan 时服务端推送。
/// type == "plan_approval_request"，包含完整 plan markdown。
public struct PlanApprovalRequest: Sendable, Identifiable, Hashable {
    public let id: String
    public let planID: String
    public let title: String
    /// Plan 正文（markdown 格式）。
    public let content: String
    /// 超时毫秒数。
    public let deadlineMs: Int?
    public let sessionId: String?
    public let turnId: String?
    public let planPath: String?
    public let filePath: String?

    public var deadlineSeconds: Int? { deadlineMs.map { $0 / 1000 } }

    public init(
        id: String,
        planID: String,
        title: String,
        content: String,
        deadlineMs: Int?,
        sessionId: String?,
        turnId: String?,
        planPath: String?,
        filePath: String?
    ) {
        self.id = id
        self.planID = planID
        self.title = title
        self.content = content
        self.deadlineMs = deadlineMs
        self.sessionId = sessionId
        self.turnId = turnId
        self.filePath = filePath
        self.planPath = planPath
    }

    /// 从 WireFrame 构造 plan_approval_request。
    static func from(wire: WireFrame) -> PlanApprovalRequest? {
        guard wire.type == "plan_approval_request", let id = wire.id else { return nil }
        return PlanApprovalRequest(
            id: id,
            planID: wire.planId ?? "",
            title: wire.title ?? "Plan",
            content: wire.content ?? "",
            deadlineMs: wire.deadlineMs,
            sessionId: wire.sessionId,
            turnId: wire.turnId,
            planPath: wire.planPath,
            filePath: wire.filePath,
        )
    }
}

// MARK: - AskUserRequest

/// ask_user 请求：模型遇到歧义时，服务端推送给客户端，要求用户选择或输入。
/// `id` 是关联键 — 回复 `ask_user_response` 时必须原样带回。
public struct AskUserRequest: Sendable, Identifiable, Hashable {
    public let id: String
    /// 问题文本。
    public let question: String
    /// 简短标题（最多 12 字符）。
    public let header: String
    /// 可选项列表。
    public let options: [AskUserOption]
    /// 是否允许多选。
    public let multiSelect: Bool
    /// 是否允许用户自定义输入。
    public let allowCustom: Bool
    /// 超时毫秒数。
    public let deadlineMs: Int?
    public let sessionId: String?
    public let turnId: String?

    public var deadlineSeconds: Int? { deadlineMs.map { $0 / 1000 } }

    public init(
        id: String,
        question: String,
        header: String,
        options: [AskUserOption],
        multiSelect: Bool,
        allowCustom: Bool,
        deadlineMs: Int?,
        sessionId: String?,
        turnId: String?
    ) {
        self.id = id
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
        self.allowCustom = allowCustom
        self.deadlineMs = deadlineMs
        self.sessionId = sessionId
        self.turnId = turnId
    }

    /// 是否为推荐项（label 包含 `(Recommended)` 后缀）。
    public func isRecommended(_ option: AskUserOption) -> Bool {
        option.label.hasSuffix("(Recommended)") || option.label.hasSuffix("（推荐）")
    }

    /// 从 WireFrame 构造 ask_user_request。
    static func from(wire: WireFrame) -> AskUserRequest? {
        guard wire.type == "ask_user_request",
              let id = wire.id,
              let q = wire.question else { return nil }
        return AskUserRequest(
            id: id,
            question: q.question,
            header: q.header,
            options: q.options.map { AskUserOption(label: $0.label, description: $0.description) },
            multiSelect: q.multiSelect ?? false,
            allowCustom: q.allowCustom ?? false,
            deadlineMs: wire.deadlineMs,
            sessionId: wire.sessionId,
            turnId: wire.turnId
        )
    }
}

public struct AskUserOption: Sendable, Identifiable, Hashable {
    public var id: String { label }
    public let label: String
    public let description: String

    public init(label: String, description: String) {
        self.label = label
        self.description = description
    }
}

/// ask_user 用户的回答。
public struct AskUserAnswer: Sendable, Hashable {
    /// 用户选中的选项 label 列表。取消时为空。
    public let selected: [String]
    /// 用户自由文本输入。取消时为空。
    public let notes: String?

    public init(selected: [String], notes: String?) {
        self.selected = selected
        self.notes = notes
    }

    public var isSkipped: Bool { selected.isEmpty && (notes?.isEmpty ?? true) }
}
