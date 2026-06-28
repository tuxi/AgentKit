//
//  AgentNavigationDestination.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/6/25.
//

import Foundation

public enum AgentNavigationDestination: Hashable {
    /// 已有会话的详情页。
    case conversationDetail(conversation: ConversationRef)
    /// 新建会话草稿页（尚未创建真实 Session）。
    case draft

    public var id: String {
        switch self {
        case .conversationDetail(let conversation):
            return "conversationDetail.\(conversation.id)"
        case .draft:
            return "draft"
        }
    }
}
