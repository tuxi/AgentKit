//
//  Message.swift
//  AgentKit
//
//  DTO for `GET /v1/conversations/{id}/messages` — 对话主干消息。
//  规范：`docs/client_integration_v1.md` §2 (历史读取)。
//

import Foundation

/// 对话主干中的一条消息（user/assistant）。
public struct Message: Sendable, Codable, Hashable, Identifiable {
    public let seq: Int
    public let role: MessageRole
    public let content: String

    public var id: Int { seq }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.seq = try container.decode(Int.self, forKey: .seq)
        self.content = try container.decode(String.self, forKey: .content)
        let rawRole = try container.decode(String.self, forKey: .role)
        self.role = MessageRole(rawValue: rawRole) ?? .unknown
    }

    enum CodingKeys: String, CodingKey {
        case seq, role, content
    }
}

public enum MessageRole: String, Sendable, Hashable, Codable {
    case user
    case assistant
    case unknown
}
