//
//  ConversationRef.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/6/25.
//

import Foundation

/// 会话引用：对应 `POST /v1/conversations` 与 `GET /v1/conversations` 的返回值。
/// v1 只返回 `id`，metadata（title / model / 时间）属于 P1-B。
public struct ConversationRef: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let workspacePath: String
    
    enum CodingKeys: String, CodingKey {
        case id
        case workspacePath = "workspace_path"
    }

    public init(id: String, workspacePath: String) {
        self.id = id
        self.workspacePath = workspacePath
    }
    
    public static func == (lhs: Self, rhs: Self) -> Bool {
        return lhs.id == rhs.id
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
