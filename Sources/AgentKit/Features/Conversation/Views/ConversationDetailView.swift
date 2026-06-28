//
//  ConversationDetailView.swift
//  AgentKit
//
//  中间内容，三态外壳（P5.0）：
//    1. 草稿（store.draft != nil）→ 占位空视图 + 工作区选择 chip + 提交首条消息的输入框
//    2. 活跃会话 → 事件时间线 + 冻结的工作区 chip + 发送消息的输入框
//    3. 未选中 → ContentUnavailableView
//
//  iOS: 采用 ScrollView + safeAreaInset(.bottom) 模式，输入栏自动浮于键盘之上。
//  macOS: safeAreaInset(.bottom) 无视觉影响，布局与原先 VStack 一致。
//

import SwiftUI

public struct ConversationDetailView: View {

    @Environment(WorkspaceStore.self) private var store
    @Environment(AgentRouter.self) private var router

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
                ContentUnavailableView(
                    "选择一个会话",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("从左侧列表选择，或点击 + 新建会话")
                )
            }
        }
        .toolbar { toolbarContent }
    }

    // MARK: - Draft (no session yet)

    private var draftView: some View {
        ScrollView {
            VStack(spacing: 0) {
                ContentUnavailableView {
                    Label("新建会话", systemImage: "sparkles")
                } description: {
                    Text(store.draft?.workspace == nil
                         ? "先选择一个工作区，再描述你的任务"
                         : "描述一个任务，发送后将创建会话并锁定工作区")
                }
                .frame(maxHeight: .infinity)

                if case .failed(let message) = store.draft?.state {
                    failureBanner(message)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                WorkspaceChipBar()

                ChatComposer(
                    placeholder: "描述一个任务…",
                    isEnabled: store.draft?.canCommit ?? false
                ) { text in
                    await store.commitDraft(firstMessage: text)
                    return store.draft == nil   // draft 被清空 = 提交成功
                }
            }
            .background(.bar)
        }
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
        ConversationTimelineView(viewModel: vm)
            .safeAreaInset(edge: .bottom, spacing: 0) {
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
                            onApprove: {
                                Task { await vm.approve(id: approval.id, approved: true) }
                            },
                            onReject: {
                                Task { await vm.approve(id: approval.id, approved: false) }
                            }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    WorkspaceChipBar()          // 冻结：只读 chip

                    ChatComposer(
                        placeholder: (vm.snapshot.pendingApproval != nil || vm.snapshot.pendingPlanApproval != nil)
                            ? "审批中 — 请选择「允许」或「拒绝」"
                            : "输入消息…",
                        isEnabled: vm.snapshot.pendingApproval == nil && vm.snapshot.pendingPlanApproval == nil
                    ) { text in
                        await vm.send(input: .text(text))
                        return true
                    }
                }
                .background(.bar)
                .animation(.easeOut(duration: 0.25), value: vm.snapshot.pendingApproval != nil)
                .animation(.easeOut(duration: 0.25), value: vm.snapshot.pendingPlanApproval != nil)
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
                store.isInspectorPresented.toggle()
            } label: {
                Label("详情", systemImage: "sidebar.right")
            }
            .disabled(store.selectedConversation == nil)
        }
    }
}

// MARK: - ChatComposer

/// 共享输入框。`onSend` 返回是否成功——成功时清空输入，失败时保留用户文本。
private struct ChatComposer: View {

    let placeholder: String
    let isEnabled: Bool
    let onSend: (String) async -> Bool

    @State private var text = ""
    @State private var isSending = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .disabled(!isEnabled)

                Button {
                    send()
                } label: {
                    if isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                }
                .disabled(!canSend)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        isEnabled && !trimmed.isEmpty && !isSending
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

/// 审批拦截栏 — 显示在输入框上方，阻断 input pipeline。
/// 对标 Claude Code / Cursor：审批不是消息，而是阻塞输入的状态。
private struct ApprovalBar: View {
    let request: ApprovalRequest
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.yellow)
                    Text("需要审批")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }

                Text("工具: \(request.toolName)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                if let args = request.toolArgs, case .object(let dict) = args, !dict.isEmpty {
                    Text(argsSummary(dict))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                }

                HStack(spacing: 8) {
                    Button("允许", action: onApprove)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("拒绝", role: .destructive, action: onReject)
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                    Spacer()

                    if let deadline = request.deadlineMs {
                        Text("超时 \(deadline / 1000)s")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func argsSummary(_ dict: [String: JSONValue]) -> String {
        dict.map { "\($0.key): \($0.value.stringValue)" }.joined(separator: ", ")
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
