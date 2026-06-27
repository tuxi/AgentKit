//
//  SidebarView.swift
//  CodeAgent
//
//  Created by xiaoyuan on 2026/6/24.
//

import SwiftUI

/// 最左侧栏：顶部一级 Tab 切换分区，下方为当前分区的会话列表。
/// 列表点选通过 `store.selectedConversationID` 驱动中间对话详情。
public struct SidebarView: View {

    @Environment(WorkspaceStore.self) private var store

    public init() {}

    public var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {

//            Picker("Tab", selection: $store.selectedTab) {
//                ForEach(SidebarTab.allCases) { tab in
//                    Label(tab.title, systemImage: tab.systemImage)
//                        .tag(tab)
//                }
//            }
//            .pickerStyle(.segmented)
//            .labelsHidden()
//            .padding(.horizontal, 12)
//            .padding(.vertical, 10)
//
//            Divider()

            ConversationListView(
                viewModel: store.listViewModel,
                selected: $store.selectedConversation
            )

            Divider()
            footer
        }
        .navigationTitle(store.selectedTab.title)
    }

    private var footer: some View {
        VStack(spacing: 2) {
            Text("CodeAgent")
                .font(.caption.weight(.semibold))
            Text("1.0.0")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}
