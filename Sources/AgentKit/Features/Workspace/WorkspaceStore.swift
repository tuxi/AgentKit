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
import ClientToolProtocol
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
            switchInspectorWorkspace(to: selectedConversation?.id)
            supervisor.setSelectedSessionID(selectedConversation?.id)
            if let conversation = selectedConversation {
                // 选中一个真实会话即丢弃未提交的草稿。
                draft = nil
                let controller = supervisor.controller(for: conversation)
                #if os(macOS)
                if !residentConversationIDs.contains(conversation.id) {
                    residentConversationIDs.append(conversation.id)
                }
                residentConversationViewModels[conversation.id] = controller
                #endif
                // Controller installation is synchronous; history/socket loading cannot
                // later overwrite selection because it only mutates this session.
                Task { await controller.connect(to: conversation) }
            }
        }
    }

    #if os(macOS)
    /// Conversation workbenches visited in this window. Their timeline
    /// views remain mounted while another conversation is selected, preserving
    /// each WKWebView's DOM, viewport, selection, and disclosure state.
    public private(set) var residentConversationIDs: [String] = []
    public private(set) var residentConversationViewModels: [String: ConversationViewModel] = [:]
    #endif

    // MARK: - Session Draft (P5.0 延迟创建)

    /// 未提交的本地占位会话。非 nil 时中间栏展示草稿视图。
    /// `draft == nil` 且 `activeConversationViewModel == nil` → idle；
    /// `draft == nil` 且 `activeConversationViewModel != nil` → activeSession。
    public private(set) var draft: SessionDraft?

    /// 每次用户请求新建草稿时递增。用于驱动 compact 导航，不依赖 `SessionDraft` 的值相等性。
    public private(set) var draftNavigationRevision = 0

    /// 最近打开的工作区（持久化，供草稿选择/预选）。
    public let recentWorkspaces: RecentWorkspacesStore

    /// Documents 下的项目目录（供草稿选择 / 新建）。
    public let projects: ProjectsStore
    /// v1.3 — Workflow DAG 状态中心。所有 workflow_* 事件汇聚于此。
    public let workflowStore = WorkflowStore()

    /// 是否正在准备草稿的工作区（clone / import 进行中）。
    /// 此间 workspace 尚未就绪 → UI 应禁止再选目录、禁止发消息。
    public private(set) var isPreparingWorkspace = false

    public private(set) var inspectorSelection: InspectorSelection? {
        didSet {
            inspectorWorkspaceState.selection = inspectorSelection
        }
    }

    public var isInspectorPresented: Bool = false {
        didSet {
            inspectorWorkspaceState.isPresented = isInspectorPresented
            // 产物 selection 是临时详情，不是长期 session。关闭面板时丢弃它，
            // 但保留入口标签、宿主资源身份与各自导航路径。
            if !isInspectorPresented, inspectorSelection != nil {
                inspectorSelection = nil
            }
        }
    }

    /// 当前 conversation 的 Inspector 会话。切换 conversation 时替换引用，
    /// 再切回来会恢复同一批标签与导航路径。
    public private(set) var inspectorWorkspaceState = InspectorWorkspaceState()

    @ObservationIgnored
    private var inspectorWorkspaceStates: [String: InspectorWorkspaceState] = [:]

    /// P4.5: Workbench 预览面板状态（独立状态树）。
    public let workbench = WorkbenchState()

    // MARK: - Runtime Client

    /// 与 Agent Runtime 通信的客户端（agent-wire v1）。
    public let client: RuntimeClient

    /// Device-local durable state for drafts, model choices and read cursors.
    public let localStateStore: any ConversationLocalStateStore
    private let userAssetPicker: UserAssetPicking?
    private let userAssetDraftCoordinator: UserAssetDraftCoordinator?
    private let hasLocalUserAssetStager: Bool
    private let hasUserAssetUploader: Bool
    public let userAssetDraftPreviewResolver: (any UserAssetDraftPreviewResolving)?
    public let userAssetPreviewResolver: (any UserAssetPreviewResolving)?
    public let localUserAssetPreviewResolver: (any LocalUserAssetPreviewResolving)?

    public var canSelectUserAssets: Bool {
        userAssetPicker != nil && canStageLocalUserAssets
    }

    public var canStageLocalUserAssets: Bool {
        hasLocalUserAssetStager
    }

    public var canUploadUserAssetsToGateway: Bool {
        hasUserAssetUploader
    }

    /// 客户端工具注册表。
    private let toolRegistry: ToolRegistry

    /// Host-owned Timeline additions. AgentKit does not interpret their state.
    private let timelineExtensions: [any TimelineExtension]

    /// Renderer rollout policy injected by the host.
    public let conversationRendererMode: ConversationRendererMode

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

    public var supportsConversationArchive: Bool {
        supervisor.runtimeCapabilities.supportsConversationArchive
    }

    public var supportsPublicGitClone: Bool {
        supervisor.runtimeCapabilities.supportsPublicGitClone
    }

    public var runtimeProjectsRoot: String? {
        supervisor.runtimeCapabilities.projectsRoot
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

    // MARK: - Conversation list refresh lifecycle

    @ObservationIgnored private var conversationListPollingTask: Task<Void, Never>?
    private var isConversationListVisible = false
    private var isAppActive = true

    /// The host calls this as the sidebar/drawer enters and leaves view. Polling
    /// never runs for a hidden list, which also avoids background network work.
    public func setConversationListVisible(_ visible: Bool) {
        guard isConversationListVisible != visible else { return }
        isConversationListVisible = visible
        updateConversationListPolling()
        if visible, isAppActive {
            Task { await refreshConversationList() }
        }
    }

    /// The canonical list refresh path. `ConversationListViewModel` coalesces
    /// overlapping calls, so an older response cannot overwrite a newer one.
    public func refreshConversationList() async {
        await listViewModel.refresh()
        await refreshRuntimeState()
    }

    private func updateConversationListPolling() {
        conversationListPollingTask?.cancel()
        conversationListPollingTask = nil
        guard isAppActive, isConversationListVisible else { return }

        conversationListPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self else { return }
                await self.refreshConversationList()
            }
        }
    }

    // MARK: - Init

    public init(
        client: RuntimeClient = DefaultAgentClient(),
        toolRegistry: ToolRegistry = ToolRegistry(),
        timelineExtensions: [any TimelineExtension] = [],
        conversationRendererMode: ConversationRendererMode = .auto,
        onAuthExpired: (@MainActor () async -> Void)? = nil,
        localStateStore: any ConversationLocalStateStore = SQLiteConversationLocalStateStore.shared,
        userAssetPicker: UserAssetPicking? = nil,
        localUserAssetStager: (any LocalUserAssetStaging)? = nil,
        userAssetUploader: (any UserAssetUploading)? = nil,
        userAssetDraftPreviewResolver: (any UserAssetDraftPreviewResolving)? = nil,
        userAssetPreviewResolver: (any UserAssetPreviewResolving)? = nil,
        localUserAssetPreviewResolver: (any LocalUserAssetPreviewResolving)? = nil,
        attentionReadStore: (any ConversationAttentionReadStore)? = nil,
        onAttentionEvent: (@MainActor (ConversationAttentionEvent) -> Void)? = nil,
        recentWorkspaces: RecentWorkspacesStore = RecentWorkspacesStore(),
        projects: ProjectsStore = ProjectsStore()
    ) {
        self.client = client
        self.localStateStore = localStateStore
        self.userAssetPicker = userAssetPicker
        self.userAssetDraftCoordinator = (localUserAssetStager != nil || userAssetUploader != nil)
            ? UserAssetDraftCoordinator(
                store: localStateStore,
                stager: localUserAssetStager,
                uploader: userAssetUploader
            )
            : nil
        self.hasLocalUserAssetStager = localUserAssetStager != nil
        self.hasUserAssetUploader = userAssetUploader != nil
        self.userAssetDraftPreviewResolver = userAssetDraftPreviewResolver
        self.userAssetPreviewResolver = userAssetPreviewResolver
        self.localUserAssetPreviewResolver = localUserAssetPreviewResolver
        self.recentWorkspaces = recentWorkspaces
        self.projects = projects
        self.toolRegistry = toolRegistry
        self.timelineExtensions = timelineExtensions
        self.conversationRendererMode = conversationRendererMode
        self.onAuthExpired = onAuthExpired
        self.listViewModel = ConversationListViewModel(client: client)
        let resolvedAttentionStore = attentionReadStore
            ?? ConversationLocalStateAttentionReadStore(localStateStore: localStateStore)
        self.supervisor = ConversationSupervisor(
            client: client,
            toolRegistry: toolRegistry,
            timelineExtensions: timelineExtensions,
            onAuthExpired: onAuthExpired,
            localStateStore: localStateStore,
            attentionReadStore: resolvedAttentionStore,
            onAttentionEvent: onAttentionEvent,
            workflowStore: workflowStore
        )
    }

    /// Canonical dependency-container bridge used by Host app factories.
    /// Keeping this mapping in AgentKit prevents newly added attachment
    /// dependencies from being silently omitted by individual app targets.
    public convenience init(
        dependencies: AgentDependencies,
        recentWorkspaces: RecentWorkspacesStore = RecentWorkspacesStore(),
        projects: ProjectsStore = ProjectsStore()
    ) {
        self.init(
            client: dependencies.client,
            toolRegistry: dependencies.toolRegistry,
            timelineExtensions: dependencies.timelineExtensions,
            conversationRendererMode: dependencies.conversationRendererMode,
            onAuthExpired: dependencies.onAuthExpired,
            localStateStore: dependencies.localStateStore,
            userAssetPicker: dependencies.userAssetPicker,
            localUserAssetStager: dependencies.localUserAssetStager,
            userAssetUploader: dependencies.userAssetUploader,
            userAssetDraftPreviewResolver: dependencies.userAssetDraftPreviewResolver,
            userAssetPreviewResolver: dependencies.userAssetPreviewResolver,
            localUserAssetPreviewResolver: dependencies.localUserAssetPreviewResolver,
            attentionReadStore: dependencies.attentionReadStore,
            onAttentionEvent: dependencies.onAttentionEvent,
            recentWorkspaces: recentWorkspaces,
            projects: projects
        )
    }

    /// Host-driven picker bridge. Selection only records durable draft state;
    /// local staging targets the active conversation workspace and never invokes
    /// the Gateway uploader.
    public func selectUserAssets(
        for key: ConversationLocalStateKey,
        remainingSlots: Int,
        onStateChange: @escaping @MainActor @Sendable () -> Void = {}
    ) async {
        guard let userAssetPicker,
              let coordinator = userAssetDraftCoordinator else { return }
        do {
            // Sending residues are owned by the submission snapshot. Failed local
            // imports remain visible and retryable.
            try localStateStore.updateState(for: key) { state in
                state.composerDraft.attachments.removeAll {
                    $0.state == .sending
                }
                state.composerDraft.revision += 1
            }
            onStateChange()

            let currentCount = (try? localStateStore.state(for: key))?
                .composerDraft.attachments.count ?? 0
            let available = max(0, min(remainingSlots, min(4, 4 - currentCount)))
            guard available > 0 else { return }

            let selected = Array(try await userAssetPicker().prefix(available))
            guard !selected.isEmpty else { return }
            try localStateStore.updateState(for: key) { state in
                let existingIDs = Set(state.composerDraft.attachments.map(\.id))
                state.composerDraft.attachments.append(
                    contentsOf: selected.filter { !existingIDs.contains($0.id) }
                )
                state.composerDraft.revision += 1
            }
            onStateChange()
            if let workspaceRoot = workspaceRoot(for: key) {
                _ = try? await coordinator.stageLocalAssets(
                    for: key,
                    workspaceRoot: workspaceRoot,
                    onStateChange: onStateChange
                )
            }
        } catch {
            onStateChange()
        }
    }

    /// User-confirmed cloud visual delivery. This is the only automatic-composer
    /// path that invokes `UserAssetUploading`.
    public func uploadUserAssetToGateway(
        id: String,
        for key: ConversationLocalStateKey,
        onStateChange: @escaping @MainActor @Sendable () -> Void = {}
    ) async {
        guard let coordinator = userAssetDraftCoordinator else { return }
        try? await coordinator.upload(id: id, in: key, onStateChange: onStateChange)
    }

    public func retryLocalUserAssetStaging(
        id: String,
        for key: ConversationLocalStateKey,
        onStateChange: @escaping @MainActor @Sendable () -> Void = {}
    ) async {
        guard let coordinator = userAssetDraftCoordinator,
              let workspaceRoot = workspaceRoot(for: key) else { return }
        try? await coordinator.stage(
            id: id,
            in: key,
            workspaceRoot: workspaceRoot,
            onStateChange: onStateChange
        )
    }

    /// 拖拽文件到输入框时仅创建本地附件；活跃会话会立即 stage，
    /// 新会话草稿则等 Runtime 返回最终 workspacePath 后再 stage。
    public func addDroppedFiles(
        _ urls: [URL],
        for key: ConversationLocalStateKey,
        onStateChange: @escaping @MainActor @Sendable () -> Void = {}
    ) async {
        guard canStageLocalUserAssets,
              let coordinator = userAssetDraftCoordinator,
              !urls.isEmpty else { return }
        do {
            // 先清掉已失败/已发送的残留附件，再算真实可用槽位
            try localStateStore.updateState(for: key) { state in
                state.composerDraft.attachments.removeAll {
                    $0.state == .sending
                }
                state.composerDraft.revision += 1
            }
            onStateChange()

            let currentCount = (try? localStateStore.state(for: key))?
                .composerDraft.attachments.count ?? 0
            let remaining = max(0, 4 - currentCount)
            guard remaining > 0 else { return }

            let toAdd = Array(urls.prefix(remaining))

            let generatedItems = toAdd.map { url -> (id: String, ref: DraftAttachmentReference) in
                let id = UUID().uuidString
                let ref = DraftAttachmentReference(
                    id: id,
                    displayName: url.lastPathComponent,
                    resourceURI: url.absoluteString
                )
                return (id, ref)
            }

            let newAttachments = generatedItems.map(\.ref)

            // 闭包内部只更新状态，不再对外部变量进行 mutation
            try localStateStore.updateState(for: key) { state in
                let existingIDs = Set(state.composerDraft.attachments.map(\.id))
                
                // 过滤掉极其罕见的 UUID 冲突（如果有）
                let validAttachments = newAttachments.filter { !existingIDs.contains($0.id) }
                
                if !validAttachments.isEmpty {
                    state.composerDraft.attachments.append(contentsOf: validAttachments)
                    state.composerDraft.revision += 1
                }
            }
            
            onStateChange()
            if let workspaceRoot = workspaceRoot(for: key) {
                _ = try? await coordinator.stageLocalAssets(
                    for: key,
                    workspaceRoot: workspaceRoot,
                    onStateChange: onStateChange
                )
            }
        } catch {
            onStateChange()
        }
    }

    /// Stages and resolves the attachment payload in persisted draft order.
    /// Delivery is exclusive: a Gateway attachment never appears in localAssets.
    public func prepareUserAssets(
        for key: ConversationLocalStateKey,
        workspaceRoot: URL,
        onStateChange: @escaping @MainActor @Sendable () -> Void = {}
    ) async throws -> (assets: [UserAssetRef], localAssets: [LocalUserAssetRef]) {
        guard let coordinator = userAssetDraftCoordinator else {
            let attachments = try localStateStore.state(for: key)?.composerDraft.attachments ?? []
            guard attachments.isEmpty else {
                throw AgentInputRejection(
                    code: "local_asset_staging_unavailable",
                    message: "当前 Host 未提供本地附件工作区导入能力"
                )
            }
            return ([], [])
        }
        let localAssets = try await coordinator.stageLocalAssets(
            for: key,
            workspaceRoot: workspaceRoot,
            onStateChange: onStateChange
        )
        let assets = try await coordinator.readyAssets(for: key)
        return (assets, localAssets)
    }

    public func sendUserMessage(
        _ text: String,
        model: String,
        through viewModel: ConversationViewModel,
        onStateChange: @escaping @MainActor @Sendable () -> Void = {}
    ) async -> Bool {
        guard let conversation = viewModel.conversation else { return false }
        do {
            let key = ConversationLocalStateKey.session(conversation.id)
            let payload = try await prepareUserAssets(
                for: key,
                workspaceRoot: URL(fileURLWithPath: conversation.workspacePath, isDirectory: true),
                onStateChange: onStateChange
            )
            return await viewModel.send(input: .text(
                text,
                model: model,
                assets: payload.assets,
                localAssets: payload.localAssets
            ))
        } catch {
            return false
        }
    }

    private func workspaceRoot(for key: ConversationLocalStateKey) -> URL? {
        guard case .session(let sessionID) = key,
              let path = supervisor.controller(sessionID: sessionID)?.conversation?.workspacePath,
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
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

    public func canArchiveConversation(_ conversation: ConversationRef) -> Bool {
        supportsConversationArchive
            && !conversation.isArchived
            && canDeleteConversation(conversation)
    }

    @discardableResult
    public func archiveConversation(_ conversation: ConversationRef) async throws -> ConversationRef {
        guard supportsConversationArchive else {
            throw ConversationArchiveError.notSupported
        }
        let activity = supervisor.activity(for: conversation)
        guard canArchiveConversation(conversation) else {
            throw ConversationArchiveError.inUse(state: activity.rawValue)
        }
        let archived = try await listViewModel.archiveConversation(conversation)
        await supervisor.detachArchivedConversation(sessionID: conversation.id)
        if selectedConversation?.id == conversation.id {
            selectedConversation = nil
            selectedConversation = archived
        }
        return archived
    }

    @discardableResult
    public func restoreConversation(_ conversation: ConversationRef) async throws -> ConversationRef {
        guard supportsConversationArchive else {
            throw ConversationArchiveError.notSupported
        }
        let restored = try await listViewModel.restoreConversation(conversation)
        if selectedConversation?.id == conversation.id {
            selectedConversation = nil
            selectedConversation = restored
        }
        return restored
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
        #if os(macOS)
        residentConversationIDs.removeAll { $0 == conversation.id }
        residentConversationViewModels.removeValue(forKey: conversation.id)
        #endif
        try? localStateStore.removeState(for: .session(conversation.id))
    }

    // MARK: - Runtime lifecycle

    /// Refresh capability/activity snapshots and reconnect every live background session.
    public func refreshRuntimeState() async {
        await supervisor.refreshRuntimeState(conversations: listViewModel.conversations)
        if supportsConversationArchive {
            await listViewModel.refreshArchived()
        } else {
            listViewModel.clearArchived()
        }
        await reconcileSelectedConversationPartition()
    }

    /// A conversation can be archived/restored by another client while selected.
    /// Move the local selection to the Runtime-owned partition and ensure archived
    /// history cannot keep an old live control channel.
    private func reconcileSelectedConversationPartition() async {
        guard let selectedConversation else { return }
        if let active = listViewModel.conversations.first(where: { $0.id == selectedConversation.id }) {
            if selectedConversation.isArchived {
                self.selectedConversation = nil
                self.selectedConversation = active
            } else {
                self.selectedConversation = active
            }
            return
        }
        if let archived = listViewModel.archivedConversations.first(where: { $0.id == selectedConversation.id }) {
            if !selectedConversation.isArchived {
                await supervisor.detachArchivedConversation(sessionID: selectedConversation.id)
                self.selectedConversation = nil
            }
            self.selectedConversation = archived
            return
        }

        self.selectedConversation = nil
        await supervisor.removeDeletedConversation(sessionID: selectedConversation.id)
        #if os(macOS)
        residentConversationIDs.removeAll { $0 == selectedConversation.id }
        residentConversationViewModels.removeValue(forKey: selectedConversation.id)
        #endif
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
        isAppActive = true
        updateConversationListPolling()
        #if os(iOS)
        let wasAlive = AgentRuntime.shared.isAlive
        // 前台探活：iOS 挂起会回收回环 listening socket，但指针/端口仍在 → 指针存活≠listener存活。
        // ensureHealthy() 探 /healthz，死则重启 runtime（新端口，会话从 DB 重载），杜绝「回来后恒 -1004」。
        let healthy = await RuntimeConnectionMonitor.shared.ensureHealthy()
        await refreshConversationList()

        guard wasAlive, healthy else { return }
        await resumePausedConversationsAfterThaw()
        #else
        await refreshConversationList()
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
        isAppActive = false
        updateConversationListPolling()
        try? localStateStore.flush()
        #if os(iOS)
        supervisor.stopActivityMonitoring()
        AgentRuntime.shared.suspendRuntime()
        #endif
    }

    /// Release workspace-scoped polling and sockets when the host removes the
    /// workspace root view. Runtime sessions remain server-owned and resumable.
    public func handleWorkspaceDisappeared() {
        isConversationListVisible = false
        updateConversationListPolling()
        try? localStateStore.flush()
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
        selectedConversation = nil
        projects.reload()

        if draft == nil {
            if let recovered = try? localStateStore.latestDraft() {
                let restoredDraft = makeSessionDraft(from: recovered)
                draft = restoredDraft

                let oldPath = recovered.state.composerDraft.workspacePath
                let newPath = restoredDraft.workspace?.url.path

                // 只在成功恢复且路径确实发生变化时写回。
                if let oldPath,
                   let newPath,
                   !oldPath.isEmpty,
                   oldPath != newPath {
                    persistDraftMetadata()
                }
            } else {
                draft = SessionDraft(workspace: recentWorkspaces.mostRecent)
                persistDraftMetadata()
            }
        }

        draftNavigationRevision += 1

        if runtimeCapabilityDiscoveryState != .available {
            Task { await refreshRuntimeState() }
        }
    }

    /// Cold-start entry used by the empty detail page. It restores the most recent
    /// unsent draft before creating a new one, so App restarts never flash an empty
    /// composer over durable text.
    public func restoreDraftOrBegin() {
        beginDraft()
    }

    /// 在 Documents 根下创建新项目并选入当前草稿（iOS）。失败时抛 `ProjectsError`。
    public func createAndSelectProject(named name: String) throws {
        guard draft != nil else { return }
        let workspace = try projects.createProject(named: name)
        // 新建项目只初始化主工作区。即使用户之前在另一个项目中
        // 勾选过 Managed Worktree，也不应将该选择泄漏到新项目。
        draft?.usesManagedWorktree = false
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

    /// Clone a public HTTPS Git repository into Runtime's declared projects root.
    /// This prepares only the local draft workspace; no Conversation or Worktree is created.
    public func cloneAndSelectProject(request: PublicGitCloneRequest) async throws {
        guard draft != nil else { return }
        guard supportsPublicGitClone, let projectsRoot = runtimeProjectsRoot else {
            throw RuntimeHTTPError.unsupported
        }
        isPreparingWorkspace = true
        defer { isPreparingWorkspace = false }
        let cloned = try await client.cloneRepo(request: request)
        try Task.checkCancellation()

        let rootURL = URL(fileURLWithPath: projectsRoot).standardizedFileURL
        let workspaceURL = URL(fileURLWithPath: cloned.workspacePath).standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard workspaceURL.path.hasPrefix(rootPath) else {
            throw RuntimeHTTPError.invalidResponse
        }

        projects.reload()
        draft?.usesManagedWorktree = false
        selectWorkspace(Workspace(url: workspaceURL))
    }

    /// Legacy convenience wrapper. New UI should create and retain an explicit request.
    public func cloneAndSelectProject(url: String, ref: String? = nil) async throws {
        try await cloneAndSelectProject(request: PublicGitCloneRequest(url: url, ref: ref))
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
        persistDraftMetadata()
    }

    public func setDraftManagedWorktreeEnabled(_ enabled: Bool) {
        guard draft != nil else { return }
        guard !enabled || supportsManagedWorktreeCreation else { return }
        draft?.usesManagedWorktree = enabled
        persistDraftMetadata()
    }

    public func setDraftManagedWorktreeBaseRef(_ baseRef: ManagedWorktreeBaseRef) {
        guard draft?.usesManagedWorktree == true else { return }
        draft?.managedWorktreeBaseRef = baseRef
        persistDraftMetadata()
    }

    /// 放弃当前草稿。
    public func cancelDraft() {
        if let id = draft?.id {
            try? localStateStore.removeState(for: .draft(id))
        }
        draft = nil
    }

    /// 提交草稿（发送首条消息）：创建真实 Session → 连接 → 发送首条消息 → 替换为活跃会话。
    /// 这是唯一的 Session 创建点。失败时草稿进入 `.failed`，保留用户输入以便重试。
    public func commitDraft(
        firstMessage: String,
        model: String = "",
        assets: [UserAssetRef] = []
    ) async {
        guard let current = draft, let workspace = current.workspace else { return }
        if current.usesManagedWorktree && !supportsManagedWorktreeCreation {
            draft?.state = .failed("当前 Runtime 暂不支持托管 Worktree。")
            return
        }
        draft?.state = .committing
        var createdConversation: ConversationRef?
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
            var ref = try await client.createConversation(request: CreateConversationRequest(
                clientRequestID: current.clientRequestID,
                workspacePath: workspace.url.path,
                executionPolicy: current.usesManagedWorktree ? .isolatedWorktree : .sharedWorkspace,
                workspaceID: workspace.id,
                baseWorkspaceID: workspace.id,
                worktree: managedRequest
            ))
            ref.name = String(firstMessage.trimmingCharacters(in: .whitespacesAndNewlines).prefix(18))
            createdConversation = ref
            let vm = supervisor.controller(
                for: ref,
                workspace: workspace,
                model: model
            )
            try localStateStore.migrateDraft(current.id, to: ref.id)
            let preparedAssets = try await prepareUserAssets(
                for: .session(ref.id),
                workspaceRoot: URL(fileURLWithPath: ref.workspacePath, isDirectory: true)
            )
            // 加固：显式写入 selectedModelID 到 session state。
            // migrateDraft 已从 draft state merge，此处提供第二条恢复路径，
            // 防止因 WAL 时序或状态覆盖导致 active view 显示回退到默认模型（Bug 1）。
            if !model.isEmpty {
                try? localStateStore.updateState(for: .session(ref.id)) { state in
                    state.selectedModelID = model
                }
            }
            await vm.connect(to: ref)
            let firstInput = AgentInput.text(
                firstMessage,
                model: model,
                assets: preparedAssets.assets.isEmpty ? assets : preparedAssets.assets,
                localAssets: preparedAssets.localAssets
            )
            _ = try localStateStore.markSubmissionPending(
                key: .session(ref.id),
                input: firstInput
            )
            guard await vm.send(input: firstInput) else {
                throw ConversationLocalDraftError.turnNotAccepted
            }
            // 草稿 → 真实会话
            listViewModel.prepend(ref)
            selectedConversation = ref  // supervisor reuses the connected controller
            draft = nil
            await refreshConversationList()
        } catch {
            if let createdConversation,
               (try? localStateStore.state(for: .session(createdConversation.id))) != nil {
                // createConversation succeeded and the durable draft already moved
                // to the session. Keep that session selected so text and staged
                // attachment state remain retryable instead of pointing the UI at
                // a migrated-away draft key.
                listViewModel.prepend(createdConversation)
                selectedConversation = createdConversation
                draft = nil
                await refreshConversationList()
            } else {
                draft?.state = .failed(error.localizedDescription)
                persistDraftMetadata()
            }
        }
    }

    private func persistDraftMetadata() {
        guard let draft else { return }
        do {
            try localStateStore.updateState(for: .draft(draft.id)) { state in
                state.composerDraft.workspaceID = draft.workspace?.id
                state.composerDraft.workspacePath = draft.workspace?.url.path
                state.composerDraft.workspaceBranch = draft.workspace?.branch
                state.composerDraft.executionPolicy = draft.usesManagedWorktree
                    ? WorkspaceExecutionPolicy.isolatedWorktree.rawValue
                    : WorkspaceExecutionPolicy.sharedWorkspace.rawValue
                state.composerDraft.wantsManagedWorktree = draft.usesManagedWorktree
                state.composerDraft.managedWorktreeBaseRef = draft.managedWorktreeBaseRef.rawValue
                state.composerDraft.managedWorktreeSuggestedName = draft.managedWorktreeSuggestedName
                state.composerDraft.clientRequestID = draft.clientRequestID
            }
        } catch {
            DLLog("Failed to harden selectedModelID after migration: \(error)")
        }
    }

    private func makeSessionDraft(
        from recovered: (id: UUID, state: ConversationLocalState)
    ) -> SessionDraft {
        let composer = recovered.state.composerDraft
        let workspace = composer.workspacePath.flatMap { path -> Workspace? in
            guard !path.isEmpty else { return nil }
            let newPath = path.resolvingCurrentSandboxPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: newPath,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                return nil
            }
            return Workspace(
                url: URL(fileURLWithPath: newPath),
                branch: composer.workspaceBranch
            )
        }
        return SessionDraft(
            id: recovered.id,
            workspace: workspace,
            clientRequestID: composer.clientRequestID ?? "create_\(UUID().uuidString)",
            usesManagedWorktree: composer.wantsManagedWorktree,
            managedWorktreeBaseRef: ManagedWorktreeBaseRef(rawValue: composer.managedWorktreeBaseRef ?? "") ?? .head,
            managedWorktreeSuggestedName: composer.managedWorktreeSuggestedName
        )
    }

    // MARK: - Inspector

    private func switchInspectorWorkspace(to conversationID: String?) {
        let previousState = inspectorWorkspaceState
        previousState.selection = inspectorSelection
        previousState.isPresented = isInspectorPresented
        inspectorWorkspaceStates[inspectorWorkspaceKey(previousState.conversationID)] = previousState

        let key = inspectorWorkspaceKey(conversationID)
        let nextState: InspectorWorkspaceState
        if let existing = inspectorWorkspaceStates[key] {
            nextState = existing
        } else {
            nextState = InspectorWorkspaceState(conversationID: conversationID)
            inspectorWorkspaceStates[key] = nextState
        }

        inspectorWorkspaceState = nextState
        inspectorSelection = nextState.selection
        isInspectorPresented = nextState.isPresented
    }

    private func inspectorWorkspaceKey(_ conversationID: String?) -> String {
        conversationID ?? "__agentkit_draft__"
    }

    /// 点击对话详情里的某个内容时调用，弹出右侧检查器。
    public func showInspector(_ selection: InspectorSelection) {
        inspectorWorkspaceState.selectionPathState.popToRoot()
        inspectorSelection = selection
        isInspectorPresented = true
    }

    public func dismissInspector() {
        inspectorSelection = nil
        isInspectorPresented = false
    }
}

private enum ConversationLocalDraftError: Error, LocalizedError {
    case turnNotAccepted

    var errorDescription: String? {
        "会话已创建，但首条消息尚未被本地控制通道接收，请重试。"
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
