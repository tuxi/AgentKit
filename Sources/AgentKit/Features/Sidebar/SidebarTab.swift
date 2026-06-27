//
//  SidebarTab.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/6/25.
//

import Foundation

/// 侧栏顶部的一级分区，点击切换下方列表与整体内容。
public enum SidebarTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case workflow
    case code

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .workflow: return "Workflow"
        case .code: return "Code"
        }
    }

    public var systemImage: String {
        switch self {
        case .workflow: return "sparkles"
        case .code: return "chevron.left.forwardslash.chevron.right"
        }
    }
}
