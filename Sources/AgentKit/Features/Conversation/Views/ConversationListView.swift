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

public struct ConversationListView: View {

    @Environment(WorkspaceStore.self) private var store
    private let viewModel: ConversationListViewModel
    @Binding var selected: ConversationRef?

    /// 搜索过滤文本（由父视图 `.searchable` 驱动）。
    var searchText: String = ""

    // MARK: - 重命名状态

    @State private var renameTarget: ConversationRef? = nil
    @State private var renameText: String = ""
    @State private var expandedWorkspaceIDs: Set<String> = []
    @State private var knownWorkspaceIDs: Set<String> = []
    @State private var didInitializeExpansion = false
    @State private var isProjectsExpanded = true

    public init(viewModel: ConversationListViewModel,
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

    /// 侧边栏仅用的展示分组。每个真实会话固定属于一个 workspace；旧数据或通用会话
    /// 没有工作区路径时统一归入「聊天」。
    private var conversationGroups: [ConversationWorkspaceGroup] {
        var groups: [ConversationWorkspaceGroup] = []
        var indices: [String: Int] = [:]

        for conversation in filteredConversations {
            let descriptor = ConversationWorkspaceGroup.Descriptor(conversation: conversation)
            if let index = indices[descriptor.id] {
                groups[index].conversations.append(conversation)
            } else {
                indices[descriptor.id] = groups.count
                groups.append(ConversationWorkspaceGroup(
                    id: descriptor.id,
                    title: descriptor.title,
                    systemImage: descriptor.systemImage,
                    conversations: [conversation]
                ))
            }
        }
        return groups
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

    public var body: some View {
        let listRevision = viewModel.revision
        List(selection: $selected) {
            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
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
                    .listRowSeparator(.hidden)
            }
            #else
            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .listRowSeparator(.hidden)
            }
            #endif

            if !viewModel.isLoading && filteredConversations.isEmpty && !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if !conversationGroups.isEmpty {
                projectGroupHeader

                if isProjectsExpanded {
                    ForEach(conversationGroups) { group in
                        workspaceGroup(group, listRevision: listRevision)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .task {
            await viewModel.refresh()
            await store.refreshRuntimeState()
        }
        .onAppear {
            syncExpandedWorkspaceIDs()
        }
        .onChange(of: listRevision) { _, _ in
            syncExpandedWorkspaceIDs()
        }
        .onChange(of: searchText) { _, newValue in
            guard !newValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            // 搜索结果位于某个收起的项目时，自动展开该项目，避免结果被隐藏。
            isProjectsExpanded = true
            expandedWorkspaceIDs.formUnion(conversationGroups.map(\.id))
        }
        .alert("重命名任务", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("任务名称", text: $renameText)
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
        }
    }

    private var projectGroupHeader: some View {
        Button {
            isProjectsExpanded.toggle()
        } label: {
            HStack(spacing: 7) {
                Text("项目")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Image(systemName: isProjectsExpanded
                      ? "chevron.down"
                      : "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.top, 13)
            .padding(.bottom, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(.init())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityLabel(isProjectsExpanded ? "收起项目" : "展开项目")
    }

    @ViewBuilder
    private func workspaceGroup(
        _ group: ConversationWorkspaceGroup,
        listRevision: Int
    ) -> some View {
        let isExpanded = expandedWorkspaceIDs.contains(group.id)

        Button {
            if isExpanded {
                expandedWorkspaceIDs.remove(group.id)
            } else {
                expandedWorkspaceIDs.insert(group.id)
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: group.systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(group.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(.init())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityLabel(isExpanded ? "收起项目 \(group.title)" : "展开项目 \(group.title)")

        if isExpanded {
            ForEach(group.conversations, id: \.uiID) { ref in
                ConversationRow(
                    ref: ref,
                    activity: store.supervisor.activity(for: ref)
                )
                    .id("\(ref.uiID)-\(listRevision)")
                    .tag(ref)
                    .listRowInsets(.init(top: 0, leading: 12, bottom: 0, trailing: 12))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
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
    }

    /// 首次加载保持紧凑折叠；之后只为新出现的项目增加默认展开状态，
    /// 不会因为刷新列表而覆盖用户手动控制的项目。
    private func syncExpandedWorkspaceIDs() {
        let currentIDs = Set(conversationGroups.map(\.id))
        guard !currentIDs.isEmpty else { return }

        if !didInitializeExpansion {
            // 与宿主应用原有侧栏一致：启动时先显示紧凑的项目概览。
            expandedWorkspaceIDs = []
            didInitializeExpansion = true
        } else {
            expandedWorkspaceIDs.formUnion(currentIDs.subtracting(knownWorkspaceIDs))
            expandedWorkspaceIDs.formIntersection(currentIDs)
        }
        knownWorkspaceIDs = currentIDs
    }
}

// MARK: - Local presentation model

/// 只服务于侧边栏渲染，不参与 Runtime 会话数据的持久化或传输。
private struct ConversationWorkspaceGroup: Identifiable {
    struct Descriptor {
        let id: String
        let title: String
        let systemImage: String

        init(conversation: ConversationRef) {
            // 通用会话没有绑定路径，固定显示在「聊天」分组中。
            guard !conversation.workspacePath.isEmpty else {
                id = "chat"
                title = "聊天"
                systemImage = "bubble.left.and.bubble.right"
                return
            }

            // Managed worktrees stay under their source project. ConversationRef
            // also preserves the legacy workspace/path grouping fallback.
            id = conversation.workspaceGroupingID
            title = conversation.workspaceGroupingName
            systemImage = "folder"
        }
    }

    let id: String
    let title: String
    let systemImage: String
    var conversations: [ConversationRef]
}

// MARK: - ConversationRow

private struct ConversationRow: View {
    let ref: ConversationRef
    let activity: ConversationActivityState

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ref.name ?? ref.id)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let worktree = ref.worktree {
                    worktreeDetail(worktree)
                }
            }
            Spacer(minLength: 6)

            switch activity {
            case .connecting:
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("正在连接")
            case .queued:
                statusLabel("排队中", systemImage: "clock.fill", color: .secondary)
            case .running:
                statusLabel("运行中", systemImage: "circle.fill", color: .green)
            case .waitingForApproval:
                statusLabel("待审批", systemImage: "hand.raised.fill", color: .orange)
            case .waitingForClientTool:
                statusLabel("等待客户端", systemImage: "desktopcomputer", color: .secondary)
            case .paused:
                Label("已暂停", systemImage: "pause.circle.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
            case .succeeded:
                statusLabel("已完成", systemImage: "checkmark.circle.fill", color: .green)
            case .failed:
                statusLabel("失败", systemImage: "exclamationmark.circle.fill", color: .red)
            case .cancelled:
                statusLabel("已取消", systemImage: "xmark.circle.fill", color: .secondary)
            case .idle where ref.isPaused:
                Label("已暂停", systemImage: "pause.circle.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
            case .idle where ref.name != nil:
                Text(ref.id.prefix(8) + "…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
    }

    private func statusLabel(_ title: String, systemImage: String, color: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
    }

    @ViewBuilder
    private func worktreeDetail(_ worktree: ManagedWorktreeMetadata) -> some View {
        let hasSourceWarning = ref.warnings?.contains(where: { $0.code == "source_workspace_dirty" }) == true
        HStack(spacing: 4) {
            Image(systemName: worktree.requiresAttention
                ? "exclamationmark.triangle.fill"
                : "arrow.triangle.branch")
            Text(worktree.requiresAttention
                ? worktreeAttentionTitle(worktree)
                : (worktree.branch ?? worktree.name ?? "Worktree"))
                .lineLimit(1)
            if !worktree.requiresAttention {
                Text("· Worktree")
            }
            if hasSourceWarning {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("主工作区未提交修改未复制")
            }
        }
        .font(.caption2)
        .foregroundStyle(worktree.requiresAttention ? Color.orange : Color.secondary)
    }

    private func worktreeAttentionTitle(_ worktree: ManagedWorktreeMetadata) -> String {
        if worktree.needsRebind || worktree.state == "missing" { return "Worktree 不可用" }
        if worktree.state == "remove_failed" { return "Worktree 清理失败" }
        if worktree.state == "failed" { return "Worktree 创建失败" }
        return worktree.state
    }
}
