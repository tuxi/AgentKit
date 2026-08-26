//
//  WorkspacePermissions.swift
//  AgentKit
//
//  DTO for `GET/PUT /v1/workspaces/permissions/{path...}`.
//  契约来源：code-agent `internal/server/permissions.go`（permissionResponse）。
//
//  语义（见 code-agent docs/approval-modes-client-v1.md §1）：
//  - `approval_mode` 是 workspace 级档位，落在 `<workspace>/.codeagent/settings.local.json`
//    顶层 `approval_mode` 键（合并层 user → shared → local，local 最高）。
//  - `mode` 是合并后的有效档位（workspace 未设时含 user 层 fallback）。
//  - v1 的 `scope` 恒为 "workspace"（硬编码），响应无来源字段，
//    客户端无法区分「自定义档位」vs「继承 user 全局」。
//

import Foundation

/// `GET /v1/workspaces/permissions/{path...}` 响应。
public struct WorkspacePermissions: Codable, Sendable, Equatable {
    /// 恒为 `"workspace"`（v1 硬编码）。
    public let scope: String
    /// 请求的 workspace 绝对路径。
    public let path: String
    /// 可选档位列表（`["ask", "auto", "full"]`）。
    public let available: [String]
    /// 合并后的有效档位：`ask` / `auto` / `full`。
    public let mode: String

    public init(
        scope: String,
        path: String,
        available: [String],
        mode: String
    ) {
        self.scope = scope
        self.path = path
        self.available = available
        self.mode = mode
    }
}

/// `PUT /v1/workspaces/permissions/{path...}` 请求体。
/// 只写顶层 `approval_mode`，不碰 allow/deny 规则。
public struct WorkspacePermissionsUpdate: Codable, Sendable, Equatable {
    /// 目标档位：`ask` / `auto` / `full`。
    public let mode: String

    public init(mode: String) {
        self.mode = mode
    }
}
