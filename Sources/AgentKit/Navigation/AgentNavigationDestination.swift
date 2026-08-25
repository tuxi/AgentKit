//
//  AgentNavigationDestination.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/6/25.
//

import Foundation

public enum AgentNavigationDestination: Hashable, Equatable {
    /// 已有会话的详情页。
    case conversationDetail(conversation: ConversationRef)
    /// 新建会话草稿页（尚未创建真实 Session）。
    case draft
    ///  自动化仪表盘
    case automation

    public var id: String {
        switch self {
        case .conversationDetail(let conversation):
            return "conversationDetail.\(conversation.id)"
        case .draft:
            return "draft"
        case .automation:
            return "automation"
        }
    }
    
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.draft, .draft):
            return true
        case (.automation, .automation):
            return true
        case (.conversationDetail(let conversation1), .conversationDetail(let conversation2)):
            return conversation1.id == conversation2.id
        default:
            return false
        }
    }
}
