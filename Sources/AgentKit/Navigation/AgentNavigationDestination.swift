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
    ///  Workflow 控制面板（P18 R1/R2 只读观测）
    case workflow

    public var id: String {
        switch self {
        case .conversationDetail(let conversation):
            return "conversationDetail.\(conversation.id)"
        case .draft:
            return "draft"
        case .automation:
            return "automation"
        case .workflow:
            return "workflow"
        }
    }
    
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.draft, .draft):
            return true
        case (.automation, .automation):
            return true
        case (.workflow, .workflow):
            return true
        case (.conversationDetail(let conversation1), .conversationDetail(let conversation2)):
            return conversation1.id == conversation2.id
        default:
            return false
        }
    }
}
