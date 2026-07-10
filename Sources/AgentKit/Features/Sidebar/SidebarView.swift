//
//  SidebarView.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/6/24.
//

import SwiftUI

/// 最左侧栏：顶部一级 Tab 切换分区，下方为当前分区的会话列表。
/// 列表点选通过 `store.selectedConversation` 驱动中间对话详情。
///
/// - macOS：标准侧栏布局，列表支持 selection 绑定。
/// - iOS：支持搜索过滤、滑动删除，列表点选后自动 push 到详情。
public struct SidebarView: View {

    @Environment(WorkspaceStore.self) private var store
    @Environment(AccountManager.self) private var accountManager
    @State private var searchText = ""
    @State private var showSettings = false

    public init() {}

    public var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            newTaskButton

            ConversationListView(
                viewModel: store.listViewModel,
                selected: $store.selectedConversation,
                searchText: searchText
            )
            #if os(macOS)
            Divider()
            footer
            #endif
        }
        .navigationTitle(store.selectedTab.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("设置")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        #if os(iOS)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer,
            prompt: "搜索会话…"
        )
        .navigationBarTitleDisplayMode(.large)
        #endif
    }

    private var footer: some View {
        Button {
            showSettings = true
        } label: {
            HStack(spacing: 10) {
                Text(accountInitial)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor, in: Circle())

                Text(accountName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityLabel("账户：\(accountName)")
    }

    private var newTaskButton: some View {
        Button {
            // 仅建立本地草稿；首条消息发送时才会创建真正的会话。
            store.beginDraft()
        } label: {
            HStack {
                Image(systemName: "plus.app.fill")
                    .font(.subheadline)
                Text("新建任务")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityHint("创建一个新的对话草稿")
    }

    private var accountName: String {
        guard let account = accountManager.state.accountInfo else {
            return "未登录"
        }
        if let displayName = account.displayName, !displayName.isEmpty {
            return displayName
        }
        if let email = account.email, !email.isEmpty {
            return email
        }
        return account.userId
    }

    private var accountInitial: String {
        String(accountName.prefix(1)).uppercased()
    }
}
