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

    public var isPaused: Bool {
        turnStatus == "paused"
    }

    public var pausedDate: Date? {
        pausedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
    
    var uiID: String {
        return id + (name ?? "-") + (turnStatus ?? "-")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case workspacePath = "workspace_path"
        case workspace
        case name
        case turnStatus = "turn_status"
        case pausedAt = "paused_at"
    }

    public init(
        id: String,
        workspacePath: String,
        workspace: WorkspaceAnchor? = nil,
        name: String? = nil,
        turnStatus: String? = nil,
        pausedAt: Int64? = nil
    ) {
        self.id = id
        self.workspacePath = workspacePath
        self.workspace = workspace
        self.name = name
        self.turnStatus = turnStatus
        self.pausedAt = pausedAt
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        return lhs.id == rhs.id
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
