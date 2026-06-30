//
//  ConversationListView.swift
//  AgentKit
//
//  会话列表 — 侧栏内容。从 `ConversationListViewModel` 读取数据。
//
//  - macOS：sidebar 风格的 List，带 selection 绑定。
//  - iOS：支持搜索过滤、滑动删除、长按菜单。
//

import SwiftUI

struct ConversationListView: View {

    @State private var viewModel: ConversationListViewModel
    @Environment(WorkspaceStore.self) private var store
    @Binding var selected: ConversationRef?

    /// 搜索过滤文本（由父视图 `.searchable` 驱动）。
    var searchText: String = ""

    // MARK: - 重命名状态

    @State private var renameTarget: ConversationRef? = nil
    @State private var renameText: String = ""

    init(viewModel: ConversationListViewModel,
         selected: Binding<ConversationRef?>,
         searchText: String = "") {
        self.viewModel = viewModel
        self._selected = selected
        self.searchText = searchText
    }

    /// 当前可见的会话列表（客户端搜索过滤）。
    private var filteredConversations: [ConversationRef] {
        let conversations = viewModel.conversations
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return conversations
        }
        return conversations.filter { ref in
            ref.id.localizedCaseInsensitiveContains(searchText)
                || (ref.name ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List(selection: $selected) {
            if viewModel.isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .listRowSeparator(.hidden)
            }

            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            if !viewModel.isLoading && filteredConversations.isEmpty && !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .listRowSeparator(.hidden)
            }

            ForEach(filteredConversations, id: \.uiID) { ref in
                ConversationRow(ref: ref)
                    .tag(ref)
                    #if os(iOS)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            // TODO: 调用后端删除 API
                            // await viewModel.deleteConversation(ref)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    #endif
                    .contextMenu {
                        Button {
                            renameTarget = ref
                            renameText = ref.name ?? ""
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .task {
            await viewModel.refresh()
        }
        .alert("重命名会话", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) {
                renameTarget = nil
            }
            Button("确定") {
                if let target = renameTarget, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    Task {
                        await viewModel.renameConversation(target, name: renameText.trimmingCharacters(in: .whitespaces))
                    }
                }
                renameTarget = nil
            }
        } message: {
            if let target = renameTarget {
                Text("为会话 \(target.id.prefix(8))… 设置新名称")
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    // P5.0：不立即创建会话，只开一个本地草稿，等首条消息再创建。
                    store.beginDraft()
                } label: {
                    Label("新建会话", systemImage: "square.and.pencil")
                }
            }
        }
    }
}

// MARK: - ConversationRow

private struct ConversationRow: View {
    let ref: ConversationRef

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ref.name ?? ref.id)
                .font(.body)
                .lineLimit(1)

            HStack(spacing: 6) {
                Label(ref.workspacePath.isEmpty
                        ? "通用"
                        : URL(fileURLWithPath: ref.workspacePath).lastPathComponent,
                      systemImage: "folder")
                    .font(.caption)
                Spacer()
                if ref.name != nil {
                    Text(ref.id.prefix(8) + "…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
