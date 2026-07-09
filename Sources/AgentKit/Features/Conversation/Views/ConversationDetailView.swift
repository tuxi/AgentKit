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

    /// 草稿页的模型选择（新对话，初始值来自 modelForNewConversation）。
    @State private var draftModel: String = ""

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
    }

    // MARK: - Draft (no session yet)

    private var draftView: some View {
        ScrollView {
            VStack(spacing: 18) {
                Spacer(minLength: 120)

                Text(draftTitle)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .padding(.horizontal, 24)

                DraftComposerPanel(
                    placeholder: store.isPreparingWorkspace ? "正在准备工作区…" : "随心输入",
                    isEnabled: (store.draft?.canCommit ?? false) && !store.isPreparingWorkspace,
                    onSend: { text in
                        await store.commitDraft(firstMessage: text, model: draftModel)
                        return store.draft == nil
                    },
                    modelSettings: modelSettings,
                    selectedModel: $draftModel
                )
                .frame(maxWidth: 760)

                if case .failed(let message) = store.draft?.state {
                    failureBanner(message)
                        .frame(maxWidth: 760)
                }

                Spacer(minLength: 180)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.draftPageBackground.ignoresSafeArea())
        .task {
            if draftModel.isEmpty {
                draftModel = modelSettings.modelForNewConversation
            }
            if store.draft == nil
                && store.activeConversationViewModel == nil
                && store.selectedConversation == nil
                && conversation == nil {
                store.beginDraft()
            }
        }
    }

    private var draftTitle: String {
        let name = store.draft?.workspace?.name ?? store.recentWorkspaces.mostRecent?.name
        if let name, !name.isEmpty {
            return "我们应该在 \(name) 中构建什么？"
        }
        return "我们应该构建什么？"
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

        return VStack(spacing: 0) {
            if isPaused {
                ResumePausedBar(
                    pausedAt: vm.pausedAt ?? store.selectedConversation?.pausedDate,
                    isResuming: store.isResumingPausedConversation,
                    errorMessage: store.lifecycleErrorMessage
                ) {
                    Task { await store.resumeSelectedConversation() }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            ConversationTimelineView(viewModel: vm)
        }
            .safeAreaInset(edge: .bottom, spacing: 8) {
                VStack(spacing: 0) {
                    // ── 计划审批拦截栏（Plan Mode）──
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

                    WorkspaceChipBar()          // 冻结：只读 chip

                    DraftComposerPanel(
                        placeholder: isPaused
                            ? "会话已暂停 — 点击继续"
                            : (vm.snapshot.pendingApproval != nil || vm.snapshot.pendingPlanApproval != nil)
                            ? "审批中 — 请选择「允许」或「拒绝」"
                            : "输入消息…",
                        isEnabled: !isPaused && vm.snapshot.pendingApproval == nil && vm.snapshot.pendingPlanApproval == nil,
                        isTurnRunning: vm.lifecycleStatus == "running",
                        onStop: { Task { await vm.cancelTurn() } },
                        onSend: { text in
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            await vm.send(input: .text(trimmed, model: vm.selectedModel))
                            return true
                        },
                        modelSettings: modelSettings,
                        selectedModel: Binding(
                            get: { vm.selectedModel },
                            set: { newID in
                                vm.selectedModel = newID
                                modelSettings.didUseModel(newID)
                            }
                        ),
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
                }
                .background(.bar)
                .animation(.easeOut(duration: 0.25), value: vm.snapshot.pendingApproval != nil)
                .animation(.easeOut(duration: 0.25), value: vm.snapshot.pendingPlanApproval != nil)
                .animation(.easeOut(duration: 0.25), value: isPaused)
            }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Button {
                store.beginDraft()
            } label: {
                Label("新建", systemImage: "square.and.pencil")
            }
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

// MARK: - DraftComposerPanel

/// 统一输入面板 —— 合并了原 `ChatComposer` 和 `DraftComposerPanel`。
/// 用于草稿页（新建对话）和活跃会话两种场景。
/// 对标 Claude Code / Codex：模型选择器在输入栏中，每个对话独立管理自己的模型。
private struct DraftComposerPanel: View {

    let placeholder: String
    let isEnabled: Bool
    var isTurnRunning: Bool = false
    var onStop: (() -> Void)? = nil
    let onSend: (String) async -> Bool

    /// 可选的模型管理。非 nil 时显示模型选择器。
    var modelSettings: ModelSettingsStore? = nil
    /// 当前对话的模型 ID（binding，每个对话独立）。
    @Binding var selectedModel: String
    /// 模型切换回调。
    var onModelChange: ((String) -> Void)? = nil

    @State private var text = ""
    @State private var isSending = false
#if os(macOS)
    @State private var composerHeight: CGFloat = 56
    private let composerMinHeight: CGFloat = 56
    private let composerMaxHeight: CGFloat = 150
#endif

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                inputField
                    .padding(.horizontal, 16)
                    .padding(.top, 14)

                HStack(spacing: 12) {
                    Button { } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("添加")

                    Menu {
                        Button("请求批准") { }
                    } label: {
                        Label("请求批准", systemImage: "hand.raised")
                            .font(.system(size: 13, weight: .medium))
                            .labelStyle(.titleAndIcon)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .foregroundStyle(.secondary)

                    Spacer(minLength: 12)

                    // ── Model Selector ──
                    if let modelSettings {
                        modelSelector(modelSettings)
                    }

                    Spacer(minLength: 12)

                    Button { } label: {
                        Image(systemName: "mic")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("语音输入")

                    // ── Send / Stop button ──
                    if isTurnRunning {
                        Button {
                            onStop?()
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 12, weight: .bold))
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .background(Color.red, in: Circle())
                        .accessibilityLabel("停止")
                    } else {
                        Button {
                            send()
                        } label: {
                            if isSending {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 30, height: 30)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 16, weight: .bold))
                                    .frame(width: 30, height: 30)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(canSend ? Color.draftSendForeground : Color.draftDisabledSendForeground)
                        .background(canSend ? Color.draftSendBackground : Color.draftDisabledSendBackground, in: Circle())
                        .disabled(!canSend)
                        .accessibilityLabel("发送")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }

            WorkspaceChipBar()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.draftPanelFooterBackground)
        }
        .background(Color.draftPanelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.draftPanelStroke, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 20, y: 10)
        .task {
            await modelSettings?.fetchFromGateway()
        }
    }

    // MARK: - Model Selector

    private func modelSelector(_ modelSettings: ModelSettingsStore) -> some View {
        Menu {
            ForEach(modelSettings.availableModelIDs, id: \.self) { modelID in
                Button {
                    selectedModel = modelID
                    modelSettings.didUseModel(modelID)
                    onModelChange?(modelID)
                } label: {
                    HStack {
                        Text(modelSettings.displayName(for: modelID))
                        if modelID == selectedModel {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(modelSettings.displayName(for: selectedModel))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.secondary)
    }

    // MARK: - Input Field

    @ViewBuilder
    private var inputField: some View {
#if os(macOS)
        MacComposerTextView(
            text: $text,
            height: $composerHeight,
            placeholder: placeholder,
            isEnabled: isEnabled,
            minHeight: composerMinHeight,
            maxHeight: composerMaxHeight,
            onSend: {
                send()
            }
        )
        .frame(height: composerHeight)
#else
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(2...6)
            .frame(minHeight: 56, alignment: .topLeading)
            .disabled(!isEnabled)
#endif
    }

    // MARK: - Helpers

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        isEnabled && !trimmed.isEmpty && !isSending && !isTurnRunning
    }

    private func send() {
        guard canSend else { return }
        let toSend = text
        isSending = true
        Task {
            let ok = await onSend(toSend)
            isSending = false
            if ok { text = "" }
        }
    }
}

// MARK: - ApprovalBar

/// 文本高度测量 PreferenceKey。
private struct TextHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 审批拦截栏 — 显示在输入框上方，阻断 input pipeline。
/// 对标 Claude Code / Cursor：审批不是消息，而是阻塞输入的状态。

/// v1.2 三态审批作用域。
private enum ApprovalScope: String, CaseIterable, Hashable {
    case local = "local"
    case user = "user"

    var label: String {
        switch self {
        case .local: return "Project (local)"
        case .user: return "User (global)"
        }
    }
}

// 扩展三态选择的回调
private struct ApprovalBar: View {
    let request: ApprovalRequest

    // 三态回调映射图中的按钮
    let onDeny: () -> Void          // Deny 1
    let onAlwaysAllow: (String) -> Void    // Always allow 2 — 参数为 scope ("local" | "user")
    let onAllowOnce: () -> Void      // Allow once 3 ↩

    @State private var scope: ApprovalScope = .local
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            VStack(alignment: .leading, spacing: 0) {
                // 1. 顶部 Header 栏
                HStack(alignment: .center, spacing: 6) {
                    // 左侧黄色小圆点指示器
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)

                    Text("Allow CodeAgent to run \(request.displayToolName)?")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    // 右侧 scope 选择标签（点击切换）
                    Menu {
                        Picker("Scope", selection: $scope) {
                            ForEach(ApprovalScope.allCases, id: \.self) { s in
                                Text(s.label).tag(s)
                            }
                        }
                    } label: {
                        Text(scope.label)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.approvalPanelBackground.opacity(0.5))
                            .cornerRadius(4)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                // 2. 中间工具与参数内容区 (类似代码块容器)
                VStack(alignment: .leading, spacing: 8) {
                    // MCP 工具：显示 server → tool 解析结果
                    if request.isMCP, let server = request.mcpServer {
                        HStack(spacing: 4) {
                            Text("MCP Server:")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(server)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.blue)
                            Text("→")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(request.mcpBareToolName)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let args = request.toolArgs, case .object(let dict) = args, !dict.isEmpty {
                        // 测量文本真实高度：≤10行自适应；>10行固定180pt可滚动
                        ScrollView(.vertical, showsIndicators: true) {
                            argsText(dict)
                                .background(GeometryReader { geo in
                                    Color.clear.preference(
                                        key: TextHeightKey.self,
                                        value: geo.size.height
                                    )
                                })
                        }
                        .onPreferenceChange(TextHeightKey.self) { contentHeight = $0 }
                        .frame(height: contentHeight > 0 ? min(contentHeight, 180) : nil)
                        .animation(.none, value: contentHeight)
                        
                    } else if !request.isMCP {
                        Text("No arguments provided.")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(12)
                .background(Color.approvalSecondaryFill)
                .cornerRadius(6)
                .padding(.horizontal, 14)

                // 3. 底部三态按钮操作栏
                HStack(spacing: 8) {
                    // Deny 1
                    Button(action: onDeny) {
                        Text("Deny ") + Text("1").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()

                    // Always allow 2 — MCP 工具显示 server 级提示
                    Button(action: { onAlwaysAllow(scope.rawValue) }) {
                        VStack(alignment: .center, spacing: 1) {
                            Text("Always allow ") + Text("2").foregroundStyle(.tertiary)
                            if request.isMCP, let server = request.mcpServer {
                                Text("all from \"\(server)\"")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    // Allow once 3 ↩ (高亮主按钮)
                    Button(action: onAllowOnce) {
                        HStack(spacing: 4) {
                            Text("Allow once ") + Text("3 ⌘↩").foregroundStyle(.primary.opacity(0.7))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.primary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(Color.approvalPanelBackground)
            .layerBorder()
            .padding(12)
        }
    }

    private func argsSummary(_ dict: [String: JSONValue]) -> String {
        dict.map { "\($0.key): \($0.value.stringValue)" }.joined(separator: "\n")
    }

    private func argsText(_ dict: [String: JSONValue]) -> some View {
        Text(argsSummary(dict))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// 辅助扩展：便于快速绘制带圆角的细边框
extension View {
    func layerBorder() -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
        .cornerRadius(8)
    }
}
// MARK: - PlanApprovalBar

/// Plan Mode 审批卡片 — 展示完整 plan markdown。
/// 比工具审批更大，提供 Approve / Reject 按钮。
private struct PlanApprovalBar: View {
    let plan: PlanApprovalRequest
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            VStack(alignment: .leading, spacing: 10) {
                // Header
                HStack(spacing: 8) {
                    Image(systemName: "text.document.fill")
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.title)
                            .font(.subheadline.weight(.semibold))
                        Text("Proposed Plan")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if let deadline = plan.deadlineSeconds {
                        Text("\(deadline)s")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary)
                            .clipShape(Capsule())
                    }
                }

                // Plan content — markdown rendered in a scrollable area
                ScrollView(.vertical, showsIndicators: true) {
                    MarkdownRenderer(text: plan.content)
                        .font(.caption)
                }
                .frame(maxHeight: 300)
                .padding(12)
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Action buttons
                HStack(spacing: 8) {
                    Button(action: onApprove) {
                        Label("Approve Plan", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(role: .destructive, action: onReject) {
                        Label("Reject", systemImage: "xmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - Cross-platform surface colors

/// The approval panel uses window/fill surfaces that AppKit and UIKit name
/// differently; these bridge them so the file compiles on both platforms.
private extension Color {
    static var draftPageBackground: Color {
        #if os(macOS)
        Color(NSColor.windowBackgroundColor)
        #else
        Color(UIColor.systemBackground)
        #endif
    }

    static var draftPanelBackground: Color {
        #if os(macOS)
        Color(NSColor.controlBackgroundColor)
        #else
        Color(UIColor.secondarySystemBackground)
        #endif
    }

    static var draftPanelFooterBackground: Color {
        #if os(macOS)
        Color(NSColor.separatorColor).opacity(0.12)
        #else
        Color(UIColor.tertiarySystemBackground)
        #endif
    }

    static var draftPanelStroke: Color {
        #if os(macOS)
        Color(NSColor.separatorColor).opacity(0.35)
        #else
        Color(UIColor.separator).opacity(0.28)
        #endif
    }

    static var draftSendBackground: Color {
        #if os(macOS)
        Color(NSColor.labelColor)
        #else
        Color(UIColor.label)
        #endif
    }

    static var draftSendForeground: Color {
        #if os(macOS)
        Color(NSColor.windowBackgroundColor)
        #else
        Color(UIColor.systemBackground)
        #endif
    }

    static var draftDisabledSendBackground: Color {
        #if os(macOS)
        Color(NSColor.separatorColor).opacity(0.45)
        #else
        Color(UIColor.tertiaryLabel).opacity(0.35)
        #endif
    }

    static var draftDisabledSendForeground: Color {
        #if os(macOS)
        Color(NSColor.secondaryLabelColor)
        #else
        Color(UIColor.secondaryLabel)
        #endif
    }

    static var approvalPanelBackground: Color {
        #if os(macOS)
        Color(NSColor.windowBackgroundColor)
        #else
        Color(UIColor.systemBackground)
        #endif
    }

    static var approvalSecondaryFill: Color {
        #if os(macOS)
        Color(NSColor.secondarySystemFill)
        #else
        Color(UIColor.secondarySystemFill)
        #endif
    }
}
