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
    public let archivedAt: String?

    /// P6.0 — 服务端返回的分叉血缘字段。
    /// `fork_source_session_id`：源对话 id
    /// `fork_through_turn_id`：切到的轮（整段 fork 时为空/缺省）
    public let forkSourceSessionID: String?
    public let forkThroughTurnID: String?

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
        case archivedAt = "archived_at"
        case forkSourceSessionID = "fork_source_session_id"
        case forkThroughTurnID = "fork_through_turn_id"
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
        archivedAt = try c.decodeIfPresent(String.self, forKey: .archivedAt)
        forkSourceSessionID = try c.decodeIfPresent(String.self, forKey: .forkSourceSessionID)
        forkThroughTurnID = try c.decodeIfPresent(String.self, forKey: .forkThroughTurnID)
    }

    public var isArchived: Bool { archivedAt?.isEmpty == false }

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

/// Fork 响应模型
public struct ConversationForkResponse: Sendable, Codable, Hashable {
    public let id: String
    public let parentSessionID: String
    public let sourceSessionID: String
    public let workspacePath: String
    public let kind: String
    public let status: String
    public let throughTurnID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case parentSessionID = "parent_session_id"
        case sourceSessionID = "source_session_id"
        case workspacePath = "workspace_path"
        case kind
        case status
        case throughTurnID = "through_turn_id"
    }
}

/// `POST /v1/conversations/{source_id}/forks` 请求体。
struct ConversationForkRequest: Sendable, Codable {
    let requestID: String
    let name: String?
    let throughTurnID: String?
    let executionPolicy: String
    let worktreeName: String?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case name
        case throughTurnID = "through_turn_id"
        case executionPolicy = "execution_policy"
        case worktreeName = "worktree_name"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(requestID, forKey: .requestID)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(throughTurnID, forKey: .throughTurnID)
        try c.encode(executionPolicy, forKey: .executionPolicy)
        try c.encodeIfPresent(worktreeName, forKey: .worktreeName)
    }
}

/// `GET /v1/conversations/{source_id}/events?through_turn_id=` 结果。
///
/// 这些事件的 `seq` 属于**源会话**分区，不能与 fork 子会话自身（从 1 开始）
/// 的事件混入同一序列。渲染方必须把它们作为独立 partition 处理。
public struct ConversationEventsPrefix: Sendable {
    public let events: [AgentEvent]
    public let isTruncated: Bool

    public init(events: [AgentEvent], isTruncated: Bool) {
        self.events = events
        self.isTruncated = isTruncated
    }
}
