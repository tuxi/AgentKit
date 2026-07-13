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
    }

    private var projectGroupHeader: some View {
        Button {
            isProjectsExpanded.toggle()
        } label: {
            HStack(spacing: 8) {
                Text("项目")
                    .font(.headline)
                Image(systemName: isProjectsExpanded
                      ? "chevron.down"
                      : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
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
            HStack(spacing: 8) {
                Label(group.title, systemImage: group.systemImage)
                    .textCase(nil)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 16)
        .padding(.vertical, 2)
        .accessibilityLabel(isExpanded ? "收起项目 \(group.title)" : "展开项目 \(group.title)")

        if isExpanded {
            ForEach(group.conversations, id: \.uiID) { ref in
                ConversationRow(
                    ref: ref,
                    activity: store.supervisor.activity(for: ref.id)
                )
                    .id("\(ref.uiID)-\(listRevision)")
                    .tag(ref)
                    .padding(.leading, 34)
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

    /// 首次加载时默认展开所有项目；之后只为新出现的项目增加默认展开状态，
    /// 不会因为刷新列表而覆盖用户刚刚收起的项目。
    private func syncExpandedWorkspaceIDs() {
        let currentIDs = Set(conversationGroups.map(\.id))
        guard !currentIDs.isEmpty else { return }

        if !didInitializeExpansion {
            expandedWorkspaceIDs = currentIDs
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

            if let workspace = conversation.workspace {
                id = "workspace:\(workspace.id)"
                title = workspace.displayName
                systemImage = "folder"
                return
            }

            // 兼容尚未返回结构化 workspace 的旧会话；规范化路径后作为本地分组键。
            let path = URL(fileURLWithPath: conversation.workspacePath).standardizedFileURL.path
            id = "path:\(path)"
            title = URL(fileURLWithPath: path).lastPathComponent
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
        HStack(spacing: 6) {
            Text(ref.name ?? ref.id)
                .font(.body)
                .lineLimit(1)
            Spacer(minLength: 4)

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
            case .paused:
                Label("已暂停", systemImage: "pause.circle.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
            case .failed:
                statusLabel("失败", systemImage: "exclamationmark.circle.fill", color: .red)
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
        .padding(.vertical, 2)
    }

    private func statusLabel(_ title: String, systemImage: String, color: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
    }
}
