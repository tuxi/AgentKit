//
//  WorkspaceStore.swift
//  AgentKit
//
//  三栏工作区的 UI 状态中心：
//  - `selectedTab`：侧栏顶部一级分区
//  - `selectedConversationID`：驱动中间对话详情
//  - `inspectorSelection` / `isInspectorPresented`：驱动右侧 `.inspector` 详情
//  - 持有 `RuntimeClient`，管理 `ConversationListViewModel` 和活跃的 `ConversationViewModel`
//

import SwiftUI

/// 三栏工作区的 UI 选中态。
/// 这里只放"选中态"和 ViewModel 管理，跨栏的二级 push / sheet / cover 由 `AgentRouter` 负责。
@MainActor
@Observable
public final class WorkspaceStore {

    // MARK: - Tab & Selection

    public var selectedTab: SidebarTab = .code {
        didSet {
            guard oldValue != selectedTab else { return }
            selectedConversation = nil
            dismissInspector()
        }
    }

    public var selectedConversation: ConversationRef? {
        didSet {
            guard oldValue != selectedConversation else { return }
            if let conversation  = selectedConversation {
                // 选中一个真实会话即丢弃未提交的草稿。
                draft = nil
                Task { await connectToConversation(conversation) }
            } else {
                activeConversationViewModel = nil
            }
        }
    }

    // MARK: - Session Draft (P5.0 延迟创建)

    /// 未提交的本地占位会话。非 nil 时中间栏展示草稿视图。
    /// `draft == nil` 且 `activeConversationViewModel == nil` → idle；
    /// `draft == nil` 且 `activeConversationViewModel != nil` → activeSession。
    public private(set) var draft: SessionDraft?

    /// 最近打开的工作区（持久化，供草稿选择/预选）。
    public let recentWorkspaces = RecentWorkspacesStore()

    /// 端侧工作区根（iOS = Documents）下的项目目录（供草稿选择 / 新建）。
    /// macOS 上 `isAvailable == false`，UI 回退到任意文件夹选择。
    public let projects = ProjectsStore()

    /// 是否正在准备草稿的工作区（clone / import 进行中）。
    /// 此间 workspace 尚未就绪 → UI 应禁止再选目录、禁止发消息。
    public private(set) var isPreparingWorkspace = false

    public private(set) var inspectorSelection: InspectorSelection?
    public var isInspectorPresented: Bool = false

    /// P4.5: Workbench 预览面板状态（独立状态树）。
    public let workbench = WorkbenchState()

    // MARK: - Runtime Client

    /// 与 Agent Runtime 通信的客户端（agent-wire v1）。
    public let client: RuntimeClient

    /// 客户端工具注册表。
    private let toolRegistry: ToolRegistry

    // MARK: - ViewModels

    /// 侧栏会话列表的 ViewModel。
    public let listViewModel: ConversationListViewModel

    /// 当前选中会话的 ViewModel（nil 表示未选中或 mock 模式）。
    public private(set) var activeConversationViewModel: ConversationViewModel?

    // MARK: - Init

    public init(client: RuntimeClient = DefaultAgentClient(), toolRegistry: ToolRegistry = ToolRegistry()) {
        self.client = client
        self.toolRegistry = toolRegistry
        self.listViewModel = ConversationListViewModel(client: client)
    }

    // MARK: - Conversation Management

    /// 连接指定会话并开始消费事件流。
    private func connectToConversation(_ conversation: ConversationRef) async {
        // 已由 commitDraft 构建并连接好（首条消息路径）→ 不重复连接。
        if activeConversationViewModel?.conversation?.id == conversation.id { return }
        let vm = ConversationViewModel(client: client, toolRegistry: toolRegistry)
        await vm.connect(to: conversation)
        activeConversationViewModel = vm
    }

    // MARK: - Draft lifecycle (P5.0)

    /// 点击「+」：不调用任何 API，仅创建本地草稿。预选最近使用的工作区。
    public func beginDraft() {
        selectedConversation = nil          // 经 didSet 清掉活跃 VM
        projects.reload()                   // 项目目录可能被「文件」App 改动，开草稿时刷新
        draft = SessionDraft(workspace: recentWorkspaces.mostRecent)
    }

    /// 在 Documents 根下创建新项目并选入当前草稿（iOS）。失败时抛 `ProjectsError`。
    public func createAndSelectProject(named name: String) throws {
        guard draft != nil else { return }
        let workspace = try projects.createProject(named: name)
        selectWorkspace(workspace)
    }

    /// 从外部文件夹 copy-in 一个项目到 Documents、命名为 `name`，并选入当前草稿（iOS）。
    public func importAndSelectProject(from sourceURL: URL, named name: String) async throws {
        guard draft != nil else { return }
        isPreparingWorkspace = true
        defer { isPreparingWorkspace = false }
        let workspace = try await projects.importProject(from: sourceURL, named: name)
        selectWorkspace(workspace)
    }

    /// clone 公开 GitHub 仓库到 Documents（runtime go-git）并选入当前草稿（iOS）。
    public func cloneAndSelectProject(url: String, ref: String? = nil) async throws {
        guard draft != nil else { return }
        isPreparingWorkspace = true
        defer { isPreparingWorkspace = false }
        let cloned = try await client.cloneRepo(url: url, ref: ref)
        projects.reload()   // 让新 clone 的目录出现在项目列表
        selectWorkspace(Workspace(url: URL(fileURLWithPath: cloned.workspacePath)))
    }

    /// 在草稿中选择/切换工作区（仅草稿期可变）。
    public func selectWorkspace(_ workspace: Workspace) {
        guard draft != nil else { return }
        draft?.workspace = workspace
        draft?.state = .ready
        recentWorkspaces.touch(workspace)
    }

    /// 放弃当前草稿。
    public func cancelDraft() {
        draft = nil
    }

    /// 提交草稿（发送首条消息）：创建真实 Session → 连接 → 发送首条消息 → 替换为活跃会话。
    /// 这是唯一的 Session 创建点。失败时草稿进入 `.failed`，保留用户输入以便重试。
    public func commitDraft(firstMessage: String) async {
        guard let current = draft, let workspace = current.workspace else { return }
        draft?.state = .committing
        do {
            let ref = try await client.createConversation(workspacePath: workspace.url.path)
            let vm = ConversationViewModel(client: client, toolRegistry: toolRegistry, workspace: workspace)
            await vm.connect(to: ref)
            await vm.send(input: .text(firstMessage))

            // 草稿 → 真实会话
            activeConversationViewModel = vm
            listViewModel.prepend(ref)
            selectedConversation = ref  // connectToConversation 守卫避免二次连接
            draft = nil
        } catch {
            draft?.state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Inspector

    /// 点击对话详情里的某个内容时调用，弹出右侧检查器。
    public func showInspector(_ selection: InspectorSelection) {
        inspectorSelection = selection
        isInspectorPresented = true
    }

    public func dismissInspector() {
        inspectorSelection = nil
        isInspectorPresented = false
    }
}

// MARK: - Legacy mock bridge

extension WorkspaceStore {
    /// 向后兼容 — 来自 ConversationRef 列表的视图数据。
    /// 待 `ConversationSummary` 完成迁移后可移除。
    public func conversation(id: String?) -> ConversationSummary? {
        guard let id, let ref = listViewModel.conversations.first(where: { $0.id == id }) else {
            return nil
        }
        return ConversationSummary(
            id: ref.id,
            tab: selectedTab,
            title: ref.id,
            subtitle: "v1 会话",
            updatedAt: .now
        )
    }

    /// 向后兼容 — mock conversations 已被 listViewModel 替代。
    @available(*, deprecated, message: "使用 listViewModel.conversations")
    public var conversations: [ConversationSummary] {
        listViewModel.conversations.map { ref in
            ConversationSummary(
                id: ref.id,
                tab: selectedTab,
                title: ref.id,
                subtitle: "v1 会话",
                updatedAt: .now
            )
        }
    }
}
