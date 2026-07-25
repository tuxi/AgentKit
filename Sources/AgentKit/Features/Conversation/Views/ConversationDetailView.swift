//
//  ConversationDetailView.swift
//  AgentKit
//
//  中间内容，三态外壳（P5.0）：
//    1. 草稿（store.draft != nil）→ 占位空视图 + 工作区选择 chip + 提交首条消息的输入框
//    2. 活跃会话 → 事件时间线 + 冻结的工作区 chip + 发送消息的输入框
//    3. 未选中 → 草稿式占位页
//
//  iOS: 采用 ScrollView + safeAreaInset(.bottom) 模式，输入栏自动浮于键盘之上。
//  macOS: safeAreaInset(.bottom) 无视觉影响，布局与原先 VStack 一致。
//

import SwiftUI

public struct ConversationDetailView: View {
    
    @Environment(WorkspaceStore.self) private var store
    @Environment(AgentRouter.self) private var router
    @Environment(ModelSettingsStore.self) private var modelSettings
    
    private let conversation: ConversationRef?
    private let viewModel: ConversationViewModel?
    
    public init(conversation: ConversationRef? = nil) {
        self.conversation = conversation
        self.viewModel = nil
    }
    
    /// 带 ViewModel 的初始化。
    public init(conversation: ConversationRef?, viewModel: ConversationViewModel) {
        self.conversation = conversation
        self.viewModel = viewModel
        
    }
    
    public var body: some View {
        Group {
            if store.draft != nil {
                draftView
            } else if let vm = viewModel ?? store.activeConversationViewModel {
                activeView(vm: vm)
            } else {
                draftView
            }
        }
        .toolbar { toolbarContent }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
    
    // MARK: - Draft (no session yet)
    
    private var draftView: some View {
        Group {
            #if os(iOS)
            ScrollView {
                VStack(spacing: 18) {
                    Spacer(minLength: 150)
                    draftTitleView
                    draftFailureBanner
                    Spacer(minLength: 240)
                }
                .frame(maxWidth: .infinity)
            }
            .scrollDisabled(true)
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom, spacing: 6) {
                draftComposer
            }
            #else
            ScrollView {
                VStack(spacing: 18) {
                    Spacer(minLength: 120)
                    draftTitleView
                    draftComposer
                    draftFailureBanner
                    Spacer(minLength: 180)
                }
                .frame(maxWidth: .infinity)
            }
            #endif
        }
        .scrollDismissesKeyboard(.interactively)
        .background(.bar)
        .task {
            if store.draft == nil
                && store.activeConversationViewModel == nil
                && store.selectedConversation == nil
                && conversation == nil {
                store.restoreDraftOrBegin()
            }
        }
    }

    private var draftTitleView: some View {
        Text(draftTitle)
            .font(.system(size: 28, weight: .medium))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 24)
    }

    @ViewBuilder
    private var draftFailureBanner: some View {
        if case .failed(let message) = store.draft?.state {
            failureBanner(message)
        }
    }

    private var draftComposer: some View {
        DraftComposerPanel(
            placeholder: store.isPreparingWorkspace ? "正在准备工作区…" : "描述你想构建什么…",
            isEnabled: (store.draft?.canCommit ?? false) && !store.isPreparingWorkspace,
            isDraft: true,
            onSend: { text, model, assets in
                await store.commitDraft(firstMessage: text, model: model, assets: assets)
                return store.draft == nil
            },
            viewModel: viewModel,
            draftRevision: store.draftNavigationRevision,
        )
        .environment(modelSettings)
    }
    
    private var draftTitle: AttributedString {
        let workspace = store.draft?.workspace ?? store.recentWorkspaces.mostRecent
        guard let name = workspace?.name, !name.isEmpty else {
            return AttributedString("我们应该构建什么？")
        }
        
        // 1. 获取动态校正后的“当前可用真实路径”
        let rawPath = workspace?.url.path() ?? ""
        let currentValidPath = rawPath.resolvingCurrentSandboxPath
        
        // 中文/特殊字符安全编码
        guard let encodedPath = currentValidPath.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed),
              let url = URL(string: "codeagent://workspace?path=\(encodedPath)") else {
            return AttributedString("我们应该在 \(name) 中构建什么？")
        }
        
        let prefix = AttributedString("我们应该在")
        let suffix = AttributedString("中构建什么？")
        var highlighted = AttributedString(name)
        highlighted.foregroundColor = .accentColor
        highlighted.font = .system(size: 28, weight: .bold)
        highlighted.link = url
        return prefix + highlighted + suffix
    }
    
    private func failureBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("创建会话失败：\(message)")
                .lineLimit(2)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
    
    // MARK: - Active session
    
    private func activeView(vm: ConversationViewModel) -> some View {
        let isPaused = vm.lifecycleStatus == "paused"
        || (vm.lifecycleStatus == nil && store.selectedConversation?.isPaused == true)
        let isArchived = vm.isArchived
        
        return VStack(spacing: 0) {
            if isArchived, let conversation = vm.conversation {
                ArchivedConversationBar(
                    isRestoring: store.listViewModel.restoringConversationIDs.contains(conversation.id),
                    errorMessage: store.listViewModel.errorMessage
                ) {
                    Task { _ = try? await store.restoreConversation(conversation) }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if isPaused {
                ResumePausedBar(
                    pausedAt: vm.pausedAt ?? store.selectedConversation?.pausedDate,
                    isResuming: store.isResumingPausedConversation,
                    errorMessage: store.lifecycleErrorMessage
                ) {
                    Task { await store.resumeSelectedConversation() }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            
            residentTimelines(activeViewModel: vm)
        }
        .background(.bar)
        #if os(iOS)
        .background {
            ClientToolPresentationHost(
                presentationCoordinator: vm.clientToolPresentationCoordinator
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        #endif
        #if os(macOS)
        .padding(.horizontal, 20)
        #endif
        .safeAreaInset(edge: .bottom, spacing: 8) {
            VStack(spacing: 0) {
                // ── ask_user 卡片（优先级最高：AskUser > Plan > Approval）──
                if let askUser = vm.snapshot.pendingAskUser {
                    AskUserBar(
                        request: askUser,
                        onSubmit: { selected, notes in
                            Task { await vm.resolveAskUser(id: askUser.id, selected: selected, notes: notes) }
                        },
                        onSkip: {
                            Task { await vm.resolveAskUser(id: askUser.id, selected: [], notes: nil) }
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Plan 是阻塞输入的审批状态，不是对话消息。完整规划只在
                // 这里展示一次，批准后才进入后续执行阶段。
                if let plan = vm.snapshot.pendingPlanApproval {
                    PlanApprovalBar(
                        plan: plan,
                        onApprove: {
                            Task { await vm.approvePlan(id: plan.id, approved: true) }
                        },
                        onReject: {
                            Task { await vm.approvePlan(id: plan.id, approved: false) }
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // ── 工具审批拦截栏（阻断 input pipeline）──
                if let approval = vm.snapshot.pendingApproval {
                    ApprovalBar(
                        request: approval,
                        onDeny: {
                            Task { await vm.approve(id: approval.id, decision: "deny") }
                        },
                        onAlwaysAllow: { scope in
                            Task { await vm.approve(id: approval.id, decision: "always", scope: scope) }
                        },
                        onAllowOnce: {
                            Task { await vm.approve(id: approval.id, decision: "once") }
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                
                #if os(macOS)
                WorkspaceChipBar()          // macOS 保持独立的只读工作区工具栏
                    .padding(.horizontal, 20)
                #endif
                
                DraftComposerPanel(
                    placeholder: vm.isAwaitingTurnAcceptance
                    ? "正在提交任务…"
                    : vm.isLocallyQueued
                    ? "已排队 — 当前 Runtime 暂不支持跨会话并行"
                    : vm.lifecycleStatus == "queued"
                    ? vm.runtimeQueueDescription
                    : vm.lifecycleStatus == "accepted"
                    ? "Runtime 已接收 — 等待调度"
                    : isPaused
                    ? "会话已暂停 — 点击继续"
                    : isArchived
                    ? "会话已归档 — 恢复后可继续"
                    : (vm.snapshot.pendingAskUser != nil)
                    ? "请回答以下问题以继续…"
                    : (vm.snapshot.pendingApproval != nil || vm.snapshot.pendingPlanApproval != nil)
                    ? "审批中 — 请选择「允许」或「拒绝」"
                    : "输入消息…",
                    isEnabled: !isArchived && !isPaused && !vm.isTurnActive
                        && vm.snapshot.pendingAskUser == nil
                        && vm.snapshot.pendingApproval == nil
                        && vm.snapshot.pendingPlanApproval == nil,
                    isDraft: false,
                    isTurnRunning: vm.isTurnActive,
                    onStop: { Task { await vm.cancelTurn() } },
                    onSend: { text, model, assets in
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        return await vm.send(input: .text(trimmed, model: model, assets: assets))
                    },
                    viewModel: vm,
                    onModelChange: { newID in
#if os(iOS)
                        Task {
                            try? AgentRuntime.shared.reconfigure(
                                secretsJSON: await CredentialSettings.currentSecretsJSON(),
                                modelName: newID
                            )
                        }
#endif
                    }
                )
                .environment(modelSettings)
            }
            .animation(.easeOut(duration: 0.25), value: vm.snapshot.pendingAskUser != nil)
            .animation(.easeOut(duration: 0.25), value: vm.snapshot.pendingApproval != nil)
            .animation(.easeOut(duration: 0.25), value: vm.snapshot.pendingPlanApproval != nil)
            .animation(.easeOut(duration: 0.25), value: isPaused)
            .animation(.easeOut(duration: 0.25), value: isArchived)
        }
    }
    
    @ViewBuilder
    private func residentTimelines(activeViewModel: ConversationViewModel) -> some View {
#if os(macOS)
        let activeID = activeViewModel.conversation?.id
        let residentIDs = activeID.map { id in
            store.residentConversationIDs.contains(id)
            ? store.residentConversationIDs
            : store.residentConversationIDs + [id]
        } ?? store.residentConversationIDs
        
        ZStack {
            ForEach(residentIDs, id: \.self) { conversationID in
                if let resident = store.residentConversationViewModels[conversationID]
                    ?? (conversationID == activeID ? activeViewModel : nil) {
                    let isVisible = conversationID == activeID
                    ConversationTimelineView(
                        viewModel: resident,
                        isVisible: isVisible
                    )
                    .opacity(isVisible ? 1 : 0)
                    .allowsHitTesting(isVisible)
                    .accessibilityHidden(!isVisible)
                    .zIndex(isVisible ? 1 : 0)
                }
            }
        }
        // The Web workbench is transparent. Keep one background source across
        // its loading gate and rendered state so no inset color seam appears.
        .background(.bar)
#else
        ConversationTimelineView(viewModel: activeViewModel)
#endif
    }
    
    // MARK: - Toolbar
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !store.supervisor.pendingApprovals.isEmpty {
            ToolbarItem {
                Menu {
                    ForEach(store.supervisor.pendingApprovals) { approval in
                        Button {
                            store.selectConversation(sessionID: approval.sessionID)
                        } label: {
                            Label(
                                approval.conversationName,
                                systemImage: approval.kind == .plan
				        ? "list.clipboard"
				        : approval.kind == .askUser
				        ? "questionmark.bubble"
				        : "hand.raised"
                            )
                        }
                    }
                } label: {
                    Label(
                        "待审批 \(store.supervisor.pendingApprovals.count)",
                        systemImage: "hand.raised.fill"
                    )
                }
                .help("查看所有会话的待审批请求")
            }
        }
     
        if viewModel != nil || store.activeConversationViewModel != nil {
            ToolbarItem {
                Menu {
                    Button {
                        shareConversation(as: .pdf)
                    } label: {
                        Label(ConversationShareFormat.pdf.title, systemImage: ConversationShareFormat.pdf.systemImage)
                    }
                    Button {
                        shareConversation(as: .markdown)
                    } label: {
                        Label(ConversationShareFormat.markdown.title, systemImage: ConversationShareFormat.markdown.systemImage)
                    }
                } label: {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                .disabled(store.activeConversationViewModel?.snapshot.turns.isEmpty ?? true)
                .help("分享完整会话")
            }
            ToolbarItem {
                Button {
                    guard let vm = store.activeConversationViewModel else { return }
                    store.showInspector(.assets(AssetPanelPayload(
                        title: "Conversation Assets",
                        assets: vm.assetRefs,
                        conversationID: vm.conversation?.id,
                        workspace: vm.workspaceAnchor
                    )))
                } label: {
                    Label("资产", systemImage: "tray.full")
                }
                .disabled(store.activeConversationViewModel?.assetRefs.isEmpty ?? true)
            }
            ToolbarItem {
                Button {
                    store.isInspectorPresented.toggle()
                } label: {
                    Label("详情", systemImage: "sidebar.right")
                }
                .disabled(store.selectedConversation == nil)
            }
        }
    }

    private func shareConversation(as format: ConversationShareFormat) {
        guard let vm = store.activeConversationViewModel, !vm.snapshot.turns.isEmpty else { return }
        let rawTitle = vm.conversation?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = rawTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Conversation"
        let document = ConversationShareService.document(for: vm.snapshot, title: title)
        ConversationShareService.share(document, as: format)
    }
}

private struct ArchivedConversationBar: View {
    let isRestoring: Bool
    let errorMessage: String?
    let onRestore: () -> Void
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("此任务已归档")
                    .font(.subheadline.weight(.semibold))
                Text(errorMessage ?? "历史记录和 Worktree 均已保留；恢复后可以继续执行。")
                    .font(.caption)
                    .foregroundStyle(errorMessage == nil ? Color.secondary : Color.orange)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("恢复") { onRestore() }
                .disabled(isRestoring)
            if isRestoring {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }
}

// MARK: - ResumePausedBar

private struct ResumePausedBar: View {
    let pausedAt: Date?
    let isResuming: Bool
    let errorMessage: String?
    let onResume: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.orange)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("上次任务被系统中断")
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(errorMessage == nil ? Color.secondary : Color.orange)
                        .lineLimit(2)
                }
                
                Spacer()
                
                Button {
                    onResume()
                } label: {
                    if isResuming {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("继续", systemImage: "play.fill")
                    }
                }
                .disabled(isResuming)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            
            Divider()
        }
        .background(.bar)
    }
    
    private var subtitle: String {
        if let errorMessage {
            return errorMessage
        }
        guard let pausedAt else {
            return "点击继续后，Agent 会从 checkpoint 恢复。"
        }
        let interval = Int(Date().timeIntervalSince(pausedAt))
        if interval < 60 {
            return "中断于刚刚，点击继续恢复执行。"
        }
        if interval < 3600 {
            return "中断于 \(interval / 60) 分钟前，点击继续恢复执行。"
        }
        return "中断于 \(interval / 3600) 小时前，点击继续恢复执行。"
    }
}
