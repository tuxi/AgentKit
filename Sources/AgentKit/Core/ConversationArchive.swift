//
//  ConversationArchive.swift
//  AgentKit
//
//  Runtime-owned Conversation Archive/Restore v1 contract.
//

import Foundation

public struct ConversationArchiveResponse: Codable, Sendable, Equatable {
    public let id: String
    public let archivedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case archivedAt = "archived_at"
    }

    public init(id: String, archivedAt: String? = nil) {
        self.id = id
        self.archivedAt = archivedAt
    }
}

public enum ConversationArchiveError: Error, Sendable, Equatable, LocalizedError {
    case inUse(state: String?)
    case notSupported

    public var errorDescription: String? {
        switch self {
        case .inUse(let state):
            if let state, !state.isEmpty {
                return "无法归档：任务当前处于 \(state) 状态。请先等待结束、完成审批或取消任务。"
            }
            return "无法归档正在活动或可恢复的任务。请先等待结束或取消任务。"
        case .notSupported:
            return "当前 Runtime 不支持持久化会话归档。"
        }
    }

    init?(operationPayload payload: ConversationOperationErrorPayload) {
        switch payload.code {
        case "conversation_in_use": self = .inUse(state: payload.state)
        case "conversation_archive_not_supported": self = .notSupported
        default: return nil
        }
    }
}
