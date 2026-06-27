//
//  ConversationSummary.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/6/25.
//

import Foundation

/// 侧栏列表的一项（一个会话/任务）。当前用 mock 数据填充，
/// 待 `AgentClient` 接好后由后端会话列表替换。
public struct ConversationSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public let tab: SidebarTab
    public let title: String
    public let subtitle: String
    public let updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        tab: SidebarTab,
        title: String,
        subtitle: String,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.tab = tab
        self.title = title
        self.subtitle = subtitle
        self.updatedAt = updatedAt
    }
}

extension ConversationSummary {
    /// 占位数据，方便在接入真实数据前预览三栏交互。
    public static let mock: [ConversationSummary] = [
        .init(tab: .workflow, title: "AI 热点视频", subtitle: "帮我生成 AI 热点视频", updatedAt: .now),
        .init(tab: .workflow, title: "周报摘要", subtitle: "汇总本周进展", updatedAt: .now.addingTimeInterval(-3600)),
        .init(tab: .workflow, title: "竞品调研", subtitle: "分析三款同类产品", updatedAt: .now.addingTimeInterval(-7200)),
        .init(tab: .code, title: "重构 RootView", subtitle: "三栏布局改造", updatedAt: .now.addingTimeInterval(-1800)),
        .init(tab: .code, title: "修复构建", subtitle: "补全 CoreKit 依赖", updatedAt: .now.addingTimeInterval(-5400)),
    ]

    public static func mock(for tab: SidebarTab) -> [ConversationSummary] {
        mock.filter { $0.tab == tab }
    }
}
