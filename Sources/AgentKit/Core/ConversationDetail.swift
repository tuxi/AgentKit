//
//  ConversationDetail.swift
//  AgentKit
//
//  DTO for `GET /v1/conversations/{id}` — 由事件派生的会话概要。
//  规范：`docs/client_integration_v1.md` §2 (历史读取)。
//

import Foundation

/// 会话概要（由已记录事件派生）。
public struct ConversationDetail: Sendable, Codable, Hashable {
    public let id: String
    public let turnCount: Int
    public let messageCount: Int
    public let createdAt: String
    public let updatedAt: String

    /// P5.0 — 会话绑定的工作区路径（best-effort：服务端未返回时为 nil）。
    /// 用于历史会话在 UI 上回显其工作区绑定。
    public let workspacePath: String?
    public let workspace: WorkspaceAnchor?

    /// 会话名称（用户自定义）。
    public let name: String?

    /// v1.2 lifecycle status from backend metadata.
    public let turnStatus: String?

    /// Unix seconds when the session was paused.
    public let pausedAt: Int64?
    public let executionPolicy: String?
    public let workspaceID: String?
    public let baseWorkspaceID: String?
    public let worktree: ManagedWorktreeMetadata?
    public let warnings: [RuntimeAPIWarning]?

    enum CodingKeys: String, CodingKey {
        case id
        case turnCount = "turn_count"
        case messageCount = "message_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case workspacePath = "workspace_path"
        case workspace
        case name
        case turnStatus = "turn_status"
        case pausedAt = "paused_at"
        case executionPolicy = "execution_policy"
        case workspaceID = "workspace_id"
        case baseWorkspaceID = "base_workspace_id"
        case worktree, warnings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        turnCount = try c.decode(Int.self, forKey: .turnCount)
        messageCount = try c.decode(Int.self, forKey: .messageCount)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
        workspacePath = try c.decodeIfPresent(String.self, forKey: .workspacePath)
        workspace = try c.decodeIfPresent(WorkspaceAnchor.self, forKey: .workspace)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        turnStatus = try c.decodeIfPresent(String.self, forKey: .turnStatus)
        pausedAt = try c.decodeIfPresent(Int64.self, forKey: .pausedAt)
        executionPolicy = try c.decodeIfPresent(String.self, forKey: .executionPolicy)
        workspaceID = try c.decodeIfPresent(String.self, forKey: .workspaceID)
        baseWorkspaceID = try c.decodeIfPresent(String.self, forKey: .baseWorkspaceID)
        worktree = try c.decodeIfPresent(ManagedWorktreeMetadata.self, forKey: .worktree)
        warnings = try c.decodeIfPresent([RuntimeAPIWarning].self, forKey: .warnings)
    }

    public var workspaceGroupingName: String? {
        if let path = workspacePath,
           let range = path.range(of: "/.codeagent/worktrees/") {
            return URL(fileURLWithPath: String(path[..<range.lowerBound])).lastPathComponent
        }
        if worktree == nil, let workspace { return workspace.displayName }
        if let baseWorkspaceID, baseWorkspaceID.hasPrefix("/") {
            return URL(fileURLWithPath: baseWorkspaceID).lastPathComponent
        }
        return baseWorkspaceID
    }
}
