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

    private let viewModel: ConversationListViewModel
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

    #if os(iOS)
    /// runtime 连接状态横幅：重连中显示进度，连接失败显示重试按钮。连接正常时不渲染。
    @ViewBuilder
    private var connectionBanner: some View {
        switch RuntimeConnectionMonitor.shared.state {
        case .reconnecting:
            Label("正在重连运行时…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .disconnected:
            HStack {
                Label("运行时连接失败", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Spacer()
                Button("重试") {
                    Task {
                        if await RuntimeConnectionMonitor.shared.ensureHealthy() {
                            await viewModel.refresh()
                        }
                    }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        case .connected, .connecting:
            EmptyView()
        }
    }
    #endif

    var body: some View {
        let listRevision = viewModel.revision

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

            #if os(iOS)
            connectionBanner
            // 连接类错误由 connectionBanner 呈现；其余错误才用原始文案，避免与横幅重复。
            if RuntimeConnectionMonitor.shared.state == .connected
                || RuntimeConnectionMonitor.shared.state == .connecting,
               let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            #else
            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            #endif

            if !viewModel.isLoading && filteredConversations.isEmpty && !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .listRowSeparator(.hidden)
            }

            ForEach(filteredConversations, id: \.uiID) { ref in
                ConversationRow(ref: ref)
                    .id("\(ref.uiID)-\(listRevision)")
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
                let newName = renameText.trimmingCharacters(in: .whitespaces)
                if let target = renameTarget, !newName.isEmpty {
                    Task {
                        if let updated = await viewModel.renameConversation(target, name: newName),
                           selected?.id == updated.id {
                            selected = updated
                        }
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
                if ref.isPaused {
                    Label("已暂停", systemImage: "pause.circle.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                }
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
