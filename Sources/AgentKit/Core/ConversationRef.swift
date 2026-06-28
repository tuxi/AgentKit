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
/// - 一个 client 同时只 attach 一个 session（一个 WebSocket 连接）
///
/// ## 三者关系
/// ```
/// ConversationRef         = server state identity
/// AgentTransport.attach() = transport binding (WebSocket)
/// RuntimeEngine           = UI-side state projection
/// ```
public struct ConversationRef: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let workspacePath: String
    public let name: String?

    enum CodingKeys: String, CodingKey {
        case id
        case workspacePath = "workspace_path"
        case name
    }

    public init(id: String, workspacePath: String, name: String? = nil) {
        self.id = id
        self.workspacePath = workspacePath
        self.name = name
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        return lhs.id == rhs.id
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
