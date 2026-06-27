//
//  AgentNavigationDestination.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/6/25.
//

import Foundation

public enum AgentNavigationDestination: Hashable {
    case conversationDetail(conversation: ConversationRef)
    
    public var id: String {
        switch self {
        case .conversationDetail(let conversation):
            return "conversationDetail\(conversation)"
        }
    }
}
