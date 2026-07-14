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
#if os(iOS)
import Network
#endif

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
            supervisor.setSelectedSessionID(selectedConversation?.id)
            if let conversation = selectedConversation {
                // 选中一个真实会话即丢弃未提交的草稿。
                draft = nil
                let controller = supervisor.controller(for: conversation)
                // Controller installation is synchronous; history/socket loading cannot
                // later overwrite selection because it only mutates this session.
                Task { await controller.connect(to: conversation) }
            }
        }
    }

    // MARK: - Session Draft (P5.0 延迟创建)

    /// 未提交的本地占位会话。非 nil 时中间栏展示草稿视图。
    /// `draft == nil` 且 `activeConversationViewModel == nil` → idle；
    /// `draft == nil` 且 `activeConversationViewModel != nil` → activeSession。
    public private(set) var draft: SessionDraft?

    /// 每次用户请求新建草稿时递增。用于驱动 compact 导航，不依赖 `SessionDraft` 的值相等性。
    public private(set) var draftNavigationRevision = 0

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

    /// Host-owned Timeline additions. AgentKit does not interpret their state.
    private let timelineExtensions: [any TimelineExtension]

    /// Host 注入的 auth 恢复钩子，透传给每个 ConversationViewModel。
    private let onAuthExpired: (@MainActor () async -> Void)?

    // MARK: - ViewModels

    /// 侧栏会话列表的 ViewModel。
    public let listViewModel: ConversationListViewModel

    /// Retains one independent controller/channel per active conversation.
    public let supervisor: ConversationSupervisor

    /// 当前展示的 ViewModel。Changing selection never destroys other controllers.
    public var activeConversationViewModel: ConversationViewModel? {
        guard let id = selectedConversation?.id else { return nil }
        return supervisor.controller(sessionID: id)
    }

    /// Managed creation is shown only when Runtime guarantees provisioning and
    /// workspace policy enforcement. A missing capability is a safe hide.
    public var supportsManagedWorktreeCreation: Bool {
        supervisor.runtimeCapabilities.supportsManagedWorktree
    }

    public var runtimeCapabilityDiscoveryState: RuntimeCapabilityDiscoveryState {
        supervisor.runtimeCapabilityDiscoveryState
    }

    public var runtimeCapabilityErrorMessage: String? {
        supervisor.runtimeCapabilityErrorMessage
    }

    /// 手动续跑 paused 会话时的短暂状态。
    public private(set) var isResumingPausedConversation = false

    /// lifecycle 操作错误（如 ResumeSession 启动失败）。
    public private(set) var lifecycleErrorMessage: String?

    #if os(iOS)
    @ObservationIgnored private var networkMonitor: NWPathMonitor?
    @ObservationIgnored private let networkQueue = DispatchQueue(label: "agentkit.lifecycle.network.monitor")
    private var hasSeenNetworkPath = false
    private var isNetworkSatisfied = true
    private var lastNetworkResumeAttempt: Date?
    #endif

    // MARK: - Init

    public init(
        client: RuntimeClient = DefaultAgentClient(),
        toolRegistry: ToolRegistry = ToolRegistry(),
        timelineExtensions: [any TimelineExtension] = [],
        onAuthExpired: (@MainActor () async -> Void)? = nil,
        attentionReadStore: any ConversationAttentionReadStore = UserDefaultsConversationAttentionReadStore.shared,
        onAttentionEvent: (@MainActor (ConversationAttentionEvent) -> Void)? = nil
    ) {
        self.client = client
        self.toolRegistry = toolRegistry
        self.timelineExtensions = timelineExtensions
        self.onAuthExpired = onAuthExpired
        self.listViewModel = ConversationListViewModel(client: client)
        self.supervisor = ConversationSupervisor(
            client: client,
            toolRegistry: toolRegistry,
            timelineExtensions: timelineExtensions,
            onAuthExpired: onAuthExpired,
            attentionReadStore: attentionReadStore,
            onAttentionEvent: onAttentionEvent
        )
    }

    // MARK: - Conversation Management

    /// Select a retained/background conversation without changing any other session's
    /// execution. Used by the global approval inbox and notifications.
    public func selectConversation(sessionID: String) {
        if let ref = listViewModel.conversations.first(where: { $0.id == sessionID })
            ?? supervisor.controller(sessionID: sessionID)?.conversation {
            selectedConversation = ref
        }
    }

    public func canDeleteConversation(_ conversation: ConversationRef) -> Bool {
        switch supervisor.activity(for: conversation) {
        case .idle, .succeeded, .failed, .cancelled:
            return true
        case .connecting, .queued, .running, .waitingForApproval,
             .waitingForClientTool, .paused:
            return false
        }
    }

    /// Permanent deletion is allowed only after the turn reaches a terminal/idle
    /// state. Managed checkout disposition is always an explicit user choice.
    public func deleteConversation(
        _ conversation: ConversationRef,
        worktreeDisposition: ConversationWorktreeDisposition,
        forceWorktreeRemoval: Bool = false
    ) async throws {
        let activity = supervisor.activity(for: conversation)
        guard canDeleteConversation(conversation) else {
            throw ConversationDeletionError.active(activity.rawValue)
        }
        try await listViewModel.deleteConversation(
            conversation,
            worktreeDisposition: worktreeDisposition,
            forceWorktreeRemoval: forceWorktreeRemoval
        )
        if selectedConversation?.id == conversation.id {
            selectedConversation = nil
        }
        await supervisor.removeDeletedConversation(sessionID: conversation.id)
    }

    // MARK: - Runtime lifecycle

    /// Refresh capability/activity snapshots and reconnect every live background session.
    public func refreshRuntimeState() async {
        await supervisor.refreshRuntimeState(conversations: listViewModel.conversations)
    }

    /// 启动 host 侧网络恢复监听。用于修复静默 resume transient 失败后卡在 paused 的情况。
    public func startLifecycleNetworkMonitor() {
        #if os(iOS)
        guard networkMonitor == nil else { return }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.handleNetworkPathUpdate(isSatisfied: satisfied)
            }
        }
        monitor.start(queue: networkQueue)
        networkMonitor = monitor
        #endif
    }

    /// 前台恢复：同进程 thaw 自动续跑当前会话；冷启动仅刷新 paused 列表，等用户点「继续」。
    public func handleAppBecameActive() async {
        #if os(iOS)
        let wasAlive = AgentRuntime.shared.isAlive
        // 前台探活：iOS 挂起会回收回环 listening socket，但指针/端口仍在 → 指针存活≠listener存活。
        // ensureHealthy() 探 /healthz，死则重启 runtime（新端口，会话从 DB 重载），杜绝「回来后恒 -1004」。
        let healthy = await RuntimeConnectionMonitor.shared.ensureHealthy()
        await listViewModel.refresh()
        await refreshRuntimeState()

        guard wasAlive, healthy else { return }
        await resumePausedConversationsAfterThaw()
        #else
        await listViewModel.refresh()
        await refreshRuntimeState()
        #endif
    }

    #if os(iOS)
    private func handleNetworkPathUpdate(isSatisfied: Bool) {
        let wasSatisfied = isNetworkSatisfied
        isNetworkSatisfied = isSatisfied

        guard hasSeenNetworkPath else {
            hasSeenNetworkPath = true
            return
        }

        guard !wasSatisfied, isSatisfied else { return }
        Task { await retryPausedConversationAfterNetworkRecovery() }
    }

    private func retryPausedConversationAfterNetworkRecovery() async {
        let hasPausedConversation = isCurrentConversationPaused
            || !pausedRetainedSessionIDs.isEmpty
            || listViewModel.conversations.contains(where: \.isPaused)
        guard hasPausedConversation else { return }

        let now = Date()
        if let lastNetworkResumeAttempt,
           now.timeIntervalSince(lastNetworkResumeAttempt) < 2 {
            return
        }
        lastNetworkResumeAttempt = now

        await resumePausedConversationsAfterThaw()
    }

    private var pausedRetainedSessionIDs: [String] {
        supervisor.controllers.compactMap { id, controller in
            controller.lifecycleStatus == "paused" ? id : nil
        }
    }

    /// Embedded iOS Runtime suspends all active sessions together. Resume every paused
    /// session after a same-process thaw; selection only controls which one is visible.
    private func resumePausedConversationsAfterThaw() async {
        let ids = Set(pausedRetainedSessionIDs + listViewModel.conversations.filter(\.isPaused).map(\.id))
        for sessionID in ids {
            do {
                try AgentRuntime.shared.resumeRuntime(sessionID: sessionID)
                supervisor.controller(sessionID: sessionID)?.markResumeRequested()
            } catch {
                // Silent lifecycle recovery is best-effort. A selected paused session
                // keeps its explicit Resume button for user-visible retry.
            }
        }
        await listViewModel.refresh()
    }

    /// 当前 active/selected 会话是否真处于 `paused`。所有**静默自动续跑**（thaw、网络恢复重试）
    /// 都必须先过这道闸——否则对 `done`/`running` 的会话也会触发 ResumeSession，导致每次前台重复跑 turn。
    private var isCurrentConversationPaused: Bool {
        if activeConversationViewModel?.lifecycleStatus == "paused" {
            return true
        }
        if activeConversationViewModel?.lifecycleStatus == nil,
           selectedConversation?.isPaused == true {
            return true
        }
        return false
    }
    #endif

    /// 后台进入：请求 runtime 做有界 suspend/checkpoint，不销毁 server。
    public func handleAppEnteredBackground() {
        #if os(iOS)
        supervisor.stopActivityMonitoring()
        AgentRuntime.shared.suspendRuntime()
        #endif
    }

    /// Release workspace-scoped polling and sockets when the host removes the
    /// workspace root view. Runtime sessions remain server-owned and resumable.
    public func handleWorkspaceDisappeared() {
        supervisor.stopActivityMonitoring()
        Task { await supervisor.disconnectAll() }
    }

    /// 用户点击「继续」时调用，显式续跑当前 selected/active session。
    public func resumeSelectedConversation() async {
        await resumeCurrentConversation(silent: false)
    }

    private func resumeCurrentConversation(silent: Bool) async {
        guard let sessionID = activeConversationViewModel?.conversation?.id ?? selectedConversation?.id else { return }

        #if os(iOS)
        // 静默续跑（thaw / 网络恢复）只对真正 paused 的会话生效：done/running 时直接 no-op，
        // 杜绝「每次前台都触发 ResumeSession → 重复 turn」。显式点「继续」(silent==false) 由 UI 保证只在 paused 会话上出现。
        if silent, !isCurrentConversationPaused { return }
        #endif

        lifecycleErrorMessage = nil
        if !silent {
            isResumingPausedConversation = true
        }
        defer {
            if !silent {
                isResumingPausedConversation = false
            }
        }

        #if os(iOS)
        do {
            try AgentRuntime.shared.resumeRuntime(sessionID: sessionID)
            activeConversationViewModel?.markResumeRequested()
            await listViewModel.refresh()
        } catch {
            if !silent {
                lifecycleErrorMessage = error.localizedDescription
            }
        }
        #else
        if !silent {
            lifecycleErrorMessage = "当前平台不支持端侧续跑。"
        }
        #endif
    }

    // MARK: - Draft lifecycle (P5.0)

    /// 点击「+」：不调用任何 API，仅创建本地草稿。预选最近使用的工作区。
    public func beginDraft() {
        selectedConversation = nil          // only clears presentation selection
        projects.reload()                   // 项目目录可能被「文件」App 改动，开草稿时刷新
        draft = SessionDraft(workspace: recentWorkspaces.mostRecent)
        draftNavigationRevision += 1
        if runtimeCapabilityDiscoveryState != .available {
            Task { await refreshRuntimeState() }
        }
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
        if workspace.branch == nil {
            draft?.usesManagedWorktree = false
        }
        draft?.state = .ready
        recentWorkspaces.touch(workspace)
    }

    public func setDraftManagedWorktreeEnabled(_ enabled: Bool) {
        guard draft != nil else { return }
        guard !enabled || supportsManagedWorktreeCreation else { return }
        draft?.usesManagedWorktree = enabled
    }

    public func setDraftManagedWorktreeBaseRef(_ baseRef: ManagedWorktreeBaseRef) {
        guard draft?.usesManagedWorktree == true else { return }
        draft?.managedWorktreeBaseRef = baseRef
    }

    /// 放弃当前草稿。
    public func cancelDraft() {
        draft = nil
    }

    /// 提交草稿（发送首条消息）：创建真实 Session → 连接 → 发送首条消息 → 替换为活跃会话。
    /// 这是唯一的 Session 创建点。失败时草稿进入 `.failed`，保留用户输入以便重试。
    public func commitDraft(firstMessage: String, model: String = "") async {
        guard let current = draft, let workspace = current.workspace else { return }
        if current.usesManagedWorktree && !supportsManagedWorktreeCreation {
            draft?.state = .failed("当前 Runtime 暂不支持托管 Worktree。")
            return
        }
        draft?.state = .committing
        do {
            let managedRequest = current.usesManagedWorktree
                ? ManagedWorktreeCreateRequest(
                    // Never derive this from firstMessage. The draft owns one
                    // prompt-independent ASCII hint so idempotent retries cannot
                    // change the Runtime reservation identity.
                    suggestedName: current.managedWorktreeSuggestedName,
                    baseRef: current.managedWorktreeBaseRef
                )
                : nil
            let ref = try await client.createConversation(request: CreateConversationRequest(
                clientRequestID: current.clientRequestID,
                workspacePath: workspace.url.path,
                executionPolicy: current.usesManagedWorktree ? .isolatedWorktree : .sharedWorkspace,
                workspaceID: workspace.id,
                baseWorkspaceID: workspace.id,
                worktree: managedRequest
            ))
            let vm = supervisor.controller(
                for: ref,
                workspace: workspace,
                model: model
            )
            await vm.connect(to: ref)
            await vm.send(input: .text(firstMessage, model: model))

            // 草稿 → 真实会话
            listViewModel.prepend(ref)
            selectedConversation = ref  // supervisor reuses the connected controller
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
