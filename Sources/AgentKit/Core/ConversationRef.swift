//
//  ConversationRef.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/6/25.
//

import Foundation

/// 会话引用 — server-owned runtime execution context 的客户端句柄。
///
/// ## Session model (v1.1)
/// - `id` 是 server-assigned execution context UUID，不是客户端生成的
/// - `connect(conversationID:)` = attach 到已存在的 server session，不是创建新 session
/// - session 的生命周期由 backend 管理（内存态 / 持久化）
/// - 一个 RuntimeClient 可创建多个 session-bound channel；每个 channel 独立 attach
///
/// ## 三者关系
/// ```
/// ConversationRef         = server state identity
/// RuntimeSessionChannel   = session-bound transport binding (WebSocket)
/// RuntimeEngine           = UI-side state projection
/// ```
public struct ConversationRef: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let workspacePath: String
    public let workspace: WorkspaceAnchor?
    public var name: String?
    /// v1.2 lifecycle status from backend metadata: running / paused / resuming / done / failed.
    public let turnStatus: String?
    /// Unix seconds when the session was marked paused. Used for cold-start "continue" UI.
    public let pausedAt: Int64?
    /// Runtime-enforced execution policy. Kept as a string for forward compatibility.
    public let executionPolicy: String?
    /// Identity of the actual checkout used by Runtime tools.
    public let workspaceID: String?
    /// Identity of the source project used for sidebar grouping.
    public let baseWorkspaceID: String?
    public let worktree: ManagedWorktreeMetadata?
    public let warnings: [RuntimeAPIWarning]?
    /// Runtime-owned durable archive timestamp. Nil means the conversation is active.
    public let archivedAt: String?

    public var isPaused: Bool {
        turnStatus == "paused"
    }

    public var isArchived: Bool {
        archivedAt?.isEmpty == false
    }

    public var pausedDate: Date? {
        pausedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
    
    var uiID: String {
        [
            id,
            name ?? "-",
            turnStatus ?? "-",
            worktree?.state ?? "-",
            worktree?.branch ?? "-",
            archivedAt ?? "-",
        ].joined(separator: "|")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case workspacePath = "workspace_path"
        case workspace
        case name
        case turnStatus = "turn_status"
        case pausedAt = "paused_at"
        case executionPolicy = "execution_policy"
        case workspaceID = "workspace_id"
        case baseWorkspaceID = "base_workspace_id"
        case archivedAt = "archived_at"
        case worktree, warnings
    }

    public init(
        id: String,
        workspacePath: String,
        workspace: WorkspaceAnchor? = nil,
        name: String? = nil,
        turnStatus: String? = nil,
        pausedAt: Int64? = nil,
        executionPolicy: String? = nil,
        workspaceID: String? = nil,
        baseWorkspaceID: String? = nil,
        worktree: ManagedWorktreeMetadata? = nil,
        warnings: [RuntimeAPIWarning]? = nil,
        archivedAt: String? = nil
    ) {
        self.id = id
        self.workspacePath = workspacePath
        self.workspace = workspace
        self.name = name
        self.turnStatus = turnStatus
        self.pausedAt = pausedAt
        self.executionPolicy = executionPolicy
        self.workspaceID = workspaceID
        self.baseWorkspaceID = baseWorkspaceID
        self.worktree = worktree
        self.warnings = warnings
        self.archivedAt = archivedAt
    }

    public func withArchivedAt(_ archivedAt: String?) -> ConversationRef {
        ConversationRef(
            id: id,
            workspacePath: workspacePath,
            workspace: workspace,
            name: name,
            turnStatus: turnStatus,
            pausedAt: pausedAt,
            executionPolicy: executionPolicy,
            workspaceID: workspaceID,
            baseWorkspaceID: baseWorkspaceID,
            worktree: worktree,
            warnings: warnings,
            archivedAt: archivedAt
        )
    }

    /// Worktree sessions stay grouped under their source project rather than
    /// creating a top-level workspace for the checkout directory.
    public var workspaceGroupingID: String {
        // Prefer a path identity whenever Runtime gives us one. Existing main
        // checkout conversations often only have WorkspaceAnchor.rootPath,
        // while managed worktrees carry base_workspace_id. Normalizing both to
        // `path:` keeps old and new sessions in the same sidebar group.
        if let baseWorkspaceID, baseWorkspaceID.hasPrefix("/") {
            return "path:\(URL(fileURLWithPath: baseWorkspaceID).standardizedFileURL.path)"
        }
        if let rootPath = workspace?.localRootPath, !rootPath.isEmpty {
            return "path:\(URL(fileURLWithPath: rootPath).standardizedFileURL.path)"
        }
        if let basePath = inferredBaseWorkspacePath {
            return "path:\(URL(fileURLWithPath: basePath).standardizedFileURL.path)"
        }
        if let baseWorkspaceID, !baseWorkspaceID.isEmpty {
            return "base:\(baseWorkspaceID)"
        }
        if let workspace { return "workspace:\(workspace.id)" }
        guard !workspacePath.isEmpty else { return "chat" }
        return "path:\(URL(fileURLWithPath: workspacePath).standardizedFileURL.path)"
    }

    public var workspaceGroupingName: String {
        if let basePath = inferredBaseWorkspacePath {
            return URL(fileURLWithPath: basePath).lastPathComponent
        }
        if worktree == nil, let workspace { return workspace.displayName }
        if let baseWorkspaceID, baseWorkspaceID.hasPrefix("/") {
            return URL(fileURLWithPath: baseWorkspaceID).lastPathComponent
        }
        if let baseWorkspaceID, !baseWorkspaceID.isEmpty { return baseWorkspaceID }
        guard !workspacePath.isEmpty else { return "聊天" }
        return URL(fileURLWithPath: workspacePath).lastPathComponent
    }

    public var inferredBaseWorkspacePath: String? {
        let marker = "/.codeagent/worktrees/"
        guard let range = workspacePath.range(of: marker) else { return nil }
        return String(workspacePath[..<range.lowerBound])
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        return lhs.id == rhs.id
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
