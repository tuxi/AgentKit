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

    /// 会话名称（用户自定义）。
    public let name: String?

    enum CodingKeys: String, CodingKey {
        case id
        case turnCount = "turn_count"
        case messageCount = "message_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case workspacePath = "workspace_path"
        case name
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        turnCount = try c.decode(Int.self, forKey: .turnCount)
        messageCount = try c.decode(Int.self, forKey: .messageCount)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
        workspacePath = try c.decodeIfPresent(String.self, forKey: .workspacePath)
        name = try c.decodeIfPresent(String.self, forKey: .name)
    }
}
