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
    
    /// Height of the floating macOS bottom bar. The timeline pins its newest
    /// content just above this bar instead of hiding it behind the bar, while
    /// the scroll range still extends behind the bar for manual scrolling.
    @State private var bottomBarHeight: CGFloat = 0
    
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
        .frame(maxWidth: 800) // 仅限制内部 content 宽度
        .frame(maxWidth: .infinity) // 保持整体居中
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
            .background(.bar)
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
            .background(.bar)
#endif
        }
        .scrollDismissesKeyboard(.interactively)
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
            placeholder: store.isPreparingWorkspace ? AgentKitLocalized.string("conversation.preparing_workspace") : AgentKitLocalized.string("conversation.describe_placeholder"),
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
            return AttributedString(AgentKitLocalized.string("conversation.what_should_we_build"))
        }
        
        // 1. 获取动态校正后的“当前可用真实路径”
        let rawPath = workspace?.url.path() ?? ""
        let currentValidPath = rawPath.resolvingCurrentSandboxPath
        
        // 中文/特殊字符安全编码
        guard let encodedPath = currentValidPath.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed),
              let url = URL(string: "codeagent://workspace?path=\(encodedPath)") else {
            return AttributedString(String(format: AgentKitLocalized.string("conversation.what_should_we_build_in"), name))
        }
        
        let prefix = AttributedString(AgentKitLocalized.string("conversation.we_should_build_prefix"))
        let suffix = AttributedString(AgentKitLocalized.string("conversation.we_should_build_suffix"))
        var highlighted = AttributedString(name)
        highlighted.foregroundColor = .accentColor
        highlighted.font = .system(size: 28, weight: .bold)
        highlighted.link = url
        return prefix + highlighted + suffix
    }
    
    private func failureBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(String(format: AgentKitLocalized.string("conversation.create_failed"), message))
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
        let isPaused = false// vm.lifecycleStatus == "paused"
        || (vm.lifecycleStatus == nil && store.selectedConversation?.isPaused == true)
        let isArchived = vm.isArchived
        
        let banner: some View = Group {
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
        }
        
#if os(macOS)
        // macOS: Use VStack layout instead of safeAreaInset to avoid
        // Auto Layout os_unfair_lock deadlock between NSISEngine and
        // performSelector:withObject:afterDelay: during constraint updates.
        return ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                banner
                residentTimelines(activeViewModel: vm, bottomInset: bottomBarHeight)
            }
            activeBottomBar(vm: vm, isPaused: isPaused, isArchived: isArchived)
            // Measure the floating bar's own height directly. A PreferenceKey
            // set from a `.background` GeometryReader does not propagate on
            // macOS (reduce only ever sees the default 0), so the inset
            // never reached the timeline. onGeometryChange observes the
            // bar's real frame instead.
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    bottomBarHeight = height
                }
        }
        .padding(.horizontal, 20)
#else
        return VStack(spacing: 0) {
            banner
            residentTimelines(activeViewModel: vm)
        }
        .background(.bar)
        .background {
            ClientToolPresentationHost(
                presentationCoordinator: vm.clientToolPresentationCoordinator
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .safeAreaInset(edge: .bottom, spacing: 8) {
            activeBottomBar(vm: vm, isPaused: isPaused, isArchived: isArchived)
        }
#endif
    }
    
    private var inputAreaBackgroundColor: Color {
#if os(iOS)
        Color(UIColor.systemBackground)
#else
        Color(NSColor.underPageBackgroundColor) // 或 controlBackgroundColor
#endif
    }
   
    /// Bottom bar shared by both macOS (inline VStack) and iOS (safeAreaInset).
    @ViewBuilder
    private func activeBottomBar(vm: ConversationViewModel, isPaused: Bool, isArchived: Bool) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                // ── ask_user ──
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
            }
            
            //            #if os(macOS)
            //            WorkspaceChipBar()
            //            #endif
            
            DraftComposerPanel(
                placeholder: vm.isAwaitingTurnAcceptance
                ? AgentKitLocalized.string("conversation.submitting_task")
                : vm.isLocallyQueued
                ? AgentKitLocalized.string("conversation.queued_no_parallel")
                : vm.lifecycleStatus == "queued"
                ? vm.runtimeQueueDescription
                : vm.lifecycleStatus == "accepted"
                ? AgentKitLocalized.string("conversation.runtime_received")
                : isPaused
                ? AgentKitLocalized.string("conversation.paused_click_to_resume")
                : isArchived
                ? AgentKitLocalized.string("conversation.archived_restore_to_continue")
                : (vm.snapshot.pendingAskUser != nil)
                ? AgentKitLocalized.string("conversation.answer_questions_to_continue")
                : (vm.snapshot.pendingApproval != nil || vm.snapshot.pendingPlanApproval != nil)
                ? AgentKitLocalized.string("conversation.approval_needed_allow_deny")
                : AgentKitLocalized.string("conversation.input_message"),
                isEnabled: !isArchived && !isPaused && !vm.isTurnActive
                && vm.snapshot.pendingAskUser == nil
                && vm.snapshot.pendingApproval == nil
                && vm.snapshot.pendingPlanApproval == nil,
                isDraft: false,
                isTurnRunning: vm.isTurnActive,
                onStop: { Task { await vm.cancelTurn() } },
                onSend: { text, model, assets in
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return await store.sendUserMessage(
                        trimmed,
                        model: model,
                        through: vm
                    )
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
            .background {
                GeometryReader { proxy in
                    ZStack(alignment: .top) {
                        // 1. 渐变背景
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: inputAreaBackgroundColor.opacity(0.6), location: 0.3),
                                .init(color: inputAreaBackgroundColor, location: 0.8)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .background(Color.approvalSecondaryFill) // 叠加轻微毛玻璃效果
                        .mask {
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.6), .black],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                        
                        // 2. 顶部分隔线（极轻微，增强物理边界感）
                        LinearGradient(
                            colors: [.clear, Color.primary.opacity(0.08), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(height: 1)
                    }
                }
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .animation(.easeOut(duration: 0.25), value: vm.snapshot.pendingAskUser != nil)
        .animation(.easeOut(duration: 0.25), value: vm.snapshot.pendingApproval != nil)
        .animation(.easeOut(duration: 0.25), value: vm.snapshot.pendingPlanApproval != nil)
        .animation(.easeOut(duration: 0.25), value: isPaused)
        .animation(.easeOut(duration: 0.25), value: isArchived)
    }
    
    @ViewBuilder
    private func residentTimelines(activeViewModel: ConversationViewModel, bottomInset: CGFloat = 0) -> some View {
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
                        isVisible: isVisible,
                        bottomInset: bottomInset
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
                        String(format: AgentKitLocalized.string("conversation.pending_approvals_count"), String(store.supervisor.pendingApprovals.count)),
                        systemImage: "hand.raised.fill"
                    )
                }
                .help(AgentKitLocalized.string("conversation.view_all_pending"))
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
                    Label(AgentKitLocalized.string("conversation.share"), systemImage: "square.and.arrow.up")
                }
                .disabled(store.activeConversationViewModel?.snapshot.turns.isEmpty ?? true)
                .help(AgentKitLocalized.string("conversation.share_full"))
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
                    Label(AgentKitLocalized.string("conversation.assets"), systemImage: "tray.full")
                }
                .disabled(store.activeConversationViewModel?.assetRefs.isEmpty ?? true)
            }
            ToolbarItem {
                Button {
                    store.isInspectorPresented.toggle()
                } label: {
                    Label(AgentKitLocalized.string("conversation.details"), systemImage: "sidebar.right")
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
                Text(verbatim: AgentKitLocalized.string("conversation.archived_banner"))
                    .font(.subheadline.weight(.semibold))
                Text(errorMessage ?? AgentKitLocalized.string("conversation.archived_desc"))
                    .font(.caption)
                    .foregroundStyle(errorMessage == nil ? Color.secondary : Color.orange)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(AgentKitLocalized.string("conversation.restore")) { onRestore() }
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
                    Text(verbatim: AgentKitLocalized.string("conversation.last_task_interrupted"))
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
                        Label(AgentKitLocalized.string("conversation.continue"), systemImage: "play.fill")
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
            return AgentKitLocalized.string("conversation.resume_from_checkpoint")
        }
        let interval = Int(Date().timeIntervalSince(pausedAt))
        if interval < 60 {
            return AgentKitLocalized.string("conversation.interrupted_just_now")
        }
        if interval < 3600 {
            return String(format: AgentKitLocalized.string("conversation.interrupted_minutes_ago"), String(interval / 60))
        }
        return String(format: AgentKitLocalized.string("conversation.interrupted_hours_ago"), String(interval / 3600))
    }
}
