//
//  SwiftUIView.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/7/10.
//

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif


// MARK: - DraftComposerPanel

/// 统一输入面板 —— 合并了原 `ChatComposer` 和 `DraftComposerPanel`。
/// 用于草稿页（新建对话）和活跃会话两种场景。
/// 对标 Claude Code / Codex：模型选择器在输入栏中，每个对话独立管理自己的模型。
struct DraftComposerPanel: View {
    @Environment(WorkspaceStore.self) private var workspaceStore
    @Environment(ModelSettingsStore.self) private var modelSettings
    @Environment(\.scenePhase) private var scenePhase

    let placeholder: String
    let isEnabled: Bool
    let isDraft: Bool
    var isTurnRunning: Bool = false
    var onStop: (() -> Void)? = nil
    let onSend: (_ text: String, _ model: String, _ assets: [UserAssetRef]) async -> Bool
    var onAddAttachment: (() -> Void)? = nil

    let viewModel: ConversationViewModel?
    /// 草稿代次（WorkspaceStore.draftNavigationRevision）。草稿模式下 viewModel 为 nil，
    /// `.task(id:)` 靠它区分「新一次草稿」—— 否则取消草稿再新建时 id 恒为 nil，
    /// selectedModel 残留上一次的选择。活跃会话场景不需要传。
    var draftRevision: Int = 0
    /// 当前对话的模型 ID（binding，每个对话独立）。
    @State var selectedModel: String?
    /// 模型切换回调。
    var onModelChange: ((String) -> Void)? = nil

    @State private var text = ""
    @State private var attachments: [DraftAttachmentReference] = []
    @State private var submittedTextSnapshot: String?
    @State private var isSending = false
    @State private var loadedStateKey: ConversationLocalStateKey?
    @State private var pendingSaveTask: Task<Void, Never>?
    @State private var isRestoringLocalState = false
#if os(macOS)
    @State private var composerHeight: CGFloat = 56
    private let composerMinHeight: CGFloat = 56
    private let composerMaxHeight: CGFloat = 150
#endif
    
    // MARK: - Model Selector
    @State private var isMenuPresented = false
    @State private var hoveredID: String? = nil // 用于追踪当前鼠标悬停的 Item

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                if !attachments.isEmpty {
                    attachmentStrip
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }
                inputField
                    .padding(.horizontal, 16)
                    .padding(.top, attachments.isEmpty ? 14 : 2)

                HStack(spacing: 12) {
                    Button {
                        if let onAddAttachment {
                            onAddAttachment()
                        } else {
                            pickAndUploadAttachments()
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("添加")
                    .disabled(
                        attachments.count >= 4
                            || (onAddAttachment == nil && !workspaceStore.canSelectUserAssets)
                    )

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
//                    .foregroundStyle(.secondary)

                    Spacer(minLength: 12)

                    // ── Model Selector ──
                    Menu {
                        // 优雅的 Popover 内部视图
                        VStack(alignment: .leading, spacing: 4) {
                            #if os(macOS)
                            // 顶部类别标题 (类似原生)
                            Text("Models")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, 6)
                                .padding(.bottom, 2)
                            
                            #endif
                            
                            ForEach(modelSettings.availableModelIDs, id: \.self) { modelID in
                                let isSelected = modelID == selectedModel
                                let isHovered = hoveredID == modelID
                                
                                Button {
                                    selectedModel = modelID
                                    viewModel?.selectedModel = modelID
                                    modelSettings.didUseModel(modelID, conversation: viewModel?.conversation?.id ?? "")
                                    persistModel(modelID)
                                    onModelChange?(modelID)
                                    isMenuPresented = false
                                } label: {
                                    HStack(spacing: 8) {
                                        // 1. 模型名称
                                        Text(modelSettings.displayName(for: modelID))
                                            .font(.system(size: 13))
                                            .foregroundColor(isHovered ? .white : .primary) // 悬停时文字变白更清晰
                                            .lineLimit(1)
                                        
                                        // 2. 这里可以预留像截图那样的 "Included until..." 标签空间 (可选)
                                        
                                        Spacer()
                                        
                                        // 3. 勾选状态
                                        if isSelected {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundColor(isHovered ? .white : .accentColor)
                                        }
                                    }
                                    // 核心支撑：撑满整行，让整行都能响应点击和高亮
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                // 悬停高亮背景：苹果经典的蓝底或者灰色半透明
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(isHovered ? Color.accentColor : Color.clear)
                                )
                                .padding(.horizontal, 4) // 给高亮圆角留出一点点边缘呼吸感
                                #if os(macOS)
                                .onHover { hovering in
                                    // 鼠标移入移出时切换状态
                                    withAnimation(.easeOut(duration: 0.08)) {
                                        hoveredID = hovering ? modelID : nil
                                    }
                                }
                                #endif
                            }
                        }
                        .padding(.vertical, 4)
                        #if os(macOS)
                        .frame(width: 200) // 固定宽度，防止长短文字抖动
                        #endif
                    } label: {
                        // 触发按钮增加一个微小的背景反馈，让点击体验更好
                        HStack(spacing: 4) {
                            Text(modelSettings.displayName(for: selectedModel ?? ""))
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Image(systemName: "chevron.up")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(isMenuPresented ? Color.primary.opacity(0.05) : Color.clear)
                        .cornerRadius(4)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
//                    .foregroundStyle(.secondary)

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
            
            if isDraft {
                WorkspaceChipBar()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.draftPanelFooterBackground)
            }
        }
        .background(Color.draftPanelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding()
//        .overlay {
//            RoundedRectangle(cornerRadius: 20, style: .continuous)
//                .stroke(Color.draftPanelStroke, lineWidth: 1)
//        }
        .shadow(color: .black.opacity(0.10), radius: 20, y: 10)
        .task(id: persistenceKey?.storageKey ?? "none-\(draftRevision)") {
            restoreLocalState()
        }
        .onChange(of: text) { _, newValue in
            guard !isRestoringLocalState, let key = loadedStateKey else { return }
            scheduleTextSave(newValue, for: key)
        }
        .onChange(of: viewModel?.lastAcceptedSubmissionRequestID) { _, _ in
            reconcileAcceptedSubmission()
        }
        .onChange(of: viewModel?.lastInputRejection) { _, _ in
            submittedTextSnapshot = nil
            refreshAttachmentsFromLocalState()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive {
                persistCurrentText()
                try? workspaceStore.localStateStore.flush()
            }
        }
        .onDisappear {
            persistCurrentText()
        }
    }

    // MARK: - Input Field

    @ViewBuilder
    private var inputField: some View {
#if os(macOS)
        MacComposerTextView(
            text: $text,
            height: $composerHeight,
            placeholder: placeholder,
            isEnabled: true, // 任何时候都应该可以输入内容，但是在isEnabled=false不可以发送
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

    private var readyAssets: [UserAssetRef] {
        attachments.compactMap { attachment in
            guard attachment.state == .ready else { return nil }
            return attachment.readyAsset
        }
    }

    private var canSend: Bool {
        let hasContent = !trimmed.isEmpty || !readyAssets.isEmpty
        let attachmentsReady = attachments.allSatisfy { $0.state == .ready }
        return isEnabled && hasContent && attachmentsReady && !isSending
            && !isTurnRunning && !(selectedModel ?? "").isEmpty
    }

    private func send() {
        guard canSend else { return }
        let toSend = text
        submittedTextSnapshot = toSend
        persistCurrentDraft()
        isSending = true
        Task {
            _ = await onSend(toSend, selectedModel ?? "", readyAssets)
            isSending = false
        }
    }

    private var persistenceKey: ConversationLocalStateKey? {
        if isDraft, let id = workspaceStore.draft?.id {
            return .draft(id)
        }
        if let id = viewModel?.conversation?.id ?? workspaceStore.selectedConversation?.id {
            return .session(id)
        }
        return nil
    }

    private func restoreLocalState(persistOutgoingText: Bool = true) {
        pendingSaveTask?.cancel()
        if persistOutgoingText, let oldKey = loadedStateKey {
            persist(text: text, for: oldKey)
        }
        let key = persistenceKey
        loadedStateKey = key
        isRestoringLocalState = true
        defer { isRestoringLocalState = false }

        let state = key.flatMap { try? workspaceStore.localStateStore.state(for: $0) }
        text = state?.composerDraft.text ?? ""
        attachments = state?.composerDraft.attachments ?? []
        submittedTextSnapshot = state?.composerDraft.pendingSubmission?.text
        selectedModel = state?.selectedModelID
            ?? modelSettings.getModel(with: viewModel?.conversation?.id)
    }

    private func scheduleTextSave(_ value: String, for key: ConversationLocalStateKey) {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            persist(text: value, for: key)
        }
    }

    private func persistCurrentText() {
        pendingSaveTask?.cancel()
        guard let key = loadedStateKey else { return }
        persist(text: text, for: key)
    }

    private func persistCurrentDraft() {
        pendingSaveTask?.cancel()
        guard let key = loadedStateKey else { return }
        let textSnapshot = text
        let attachmentSnapshot = attachments
        try? workspaceStore.localStateStore.updateState(for: key) { state in
            state.composerDraft.text = textSnapshot
            state.composerDraft.attachments = attachmentSnapshot
            state.composerDraft.revision += 1
        }
    }

    /// Applies the accepted snapshot to the current editor value without writing
    /// the stale pre-accept text back over the durable state. Text entered while
    /// acknowledgement was pending remains in the composer.
    private func reconcileAcceptedSubmission() {
        pendingSaveTask?.cancel()
        if let submittedTextSnapshot, !submittedTextSnapshot.isEmpty {
            if text == submittedTextSnapshot {
                text = ""
            } else if text.hasPrefix(submittedTextSnapshot) {
                text.removeFirst(submittedTextSnapshot.count)
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            self.submittedTextSnapshot = nil
            refreshAttachmentsFromLocalState()
            persistCurrentText()
        } else {
            // Covers process-restart recovery where the UI did not originate the
            // submission but the persisted pending snapshot has now been accepted.
            restoreLocalState(persistOutgoingText: false)
        }
    }

    private func refreshAttachmentsFromLocalState() {
        guard let key = loadedStateKey,
              let state = try? workspaceStore.localStateStore.state(for: key) else { return }
        attachments = state.composerDraft.attachments
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    DraftAttachmentThumbnail(
                        attachment: attachment,
                        resolver: workspaceStore.userAssetDraftPreviewResolver,
                        onRemove: { removeAttachment(attachment.id) },
                        onRetry: { retryUpload(attachment.id) }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func persist(text: String, for key: ConversationLocalStateKey) {
        try? workspaceStore.localStateStore.updateState(for: key) { state in
            state.composerDraft.text = text
        }
    }

    private func persistModel(_ modelID: String) {
        guard let key = loadedStateKey, !modelID.isEmpty else { return }
        try? workspaceStore.localStateStore.updateState(for: key) { state in
            state.selectedModelID = modelID
            state.recentModelIDs.removeAll { $0 == modelID }
            state.recentModelIDs.insert(modelID, at: 0)
            if state.recentModelIDs.count > 8 {
                state.recentModelIDs.removeLast(state.recentModelIDs.count - 8)
            }
        }
    }

    private func pickAndUploadAttachments() {
        guard let key = persistenceKey else { return }
        Task {
            await workspaceStore.selectAndUploadUserAssets(
                for: key,
                remainingSlots: 4 - attachments.count
            ) {
                refreshAttachmentsFromLocalState()
            }
        }
    }

    private func removeAttachment(_ id: String) {
        attachments.removeAll { $0.id == id }
        persistCurrentDraft()
    }

    private func retryUpload(_ id: String) {
        guard let key = persistenceKey else { return }
        Task {
            await workspaceStore.retryUserAssetUpload(id: id, for: key) {
                refreshAttachmentsFromLocalState()
            }
        }
    }
}

private struct DraftAttachmentThumbnail: View {
    let attachment: DraftAttachmentReference
    let resolver: (any UserAssetDraftPreviewResolving)?
    let onRemove: () -> Void
    let onRetry: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            DraftAttachmentPreview(attachment: attachment, resolver: resolver)
                .frame(width: 96, height: 76)

            stateOverlay

            if attachment.state != .sending {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(.black.opacity(0.72), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(5)
                .accessibilityLabel("移除 \(attachment.displayName)")
            }
        }
        .frame(width: 96, height: 76)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(borderColor, lineWidth: attachment.state == .failed ? 1.5 : 0.5)
        }
        .help(attachment.displayName)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch attachment.state {
        case .local, .preparing:
            statusOverlay(title: "处理中", progress: nil)
        case .uploading:
            statusOverlay(
                title: "上传中 \(Int((attachment.progress ?? 0) * 100))%",
                progress: attachment.progress
            )
        case .failed:
            Button(action: onRetry) {
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.system(size: 18, weight: .semibold))
                    Text("上传失败 · 重试")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.58))
            }
            .buttonStyle(.plain)
            .accessibilityHint(attachment.failure?.message ?? "点击重新上传")
        case .ready, .sending:
            EmptyView()
        }
    }

    private func statusOverlay(title: String, progress: Double?) -> some View {
        VStack(spacing: 6) {
            if let progress {
                ProgressView(value: progress)
                    .tint(.white)
                    .frame(width: 54)
            } else {
                ProgressView()
                    .tint(.white)
                    .controlSize(.small)
            }
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.42))
    }

    private var borderColor: Color {
        attachment.state == .failed ? .red.opacity(0.8) : .white.opacity(0.12)
    }

    private var accessibilityLabel: String {
        switch attachment.state {
        case .local, .preparing: return "\(attachment.displayName)，处理中"
        case .uploading: return "\(attachment.displayName)，上传中"
        case .failed: return "\(attachment.displayName)，上传失败"
        case .ready: return "\(attachment.displayName)，上传完成"
        case .sending: return "\(attachment.displayName)，发送中"
        }
    }
}

private struct DraftAttachmentPreview: View {
    let attachment: DraftAttachmentReference
    let resolver: (any UserAssetDraftPreviewResolving)?
    @State private var previewImage: Image?

    var body: some View {
        Group {
            if let previewImage {
                previewImage
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.08)
                    Image(systemName: "photo")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipped()
        .task(id: "\(attachment.id)|\(attachment.resourceURI)") {
            await loadPreview()
        }
    }

    private func loadPreview() async {
        let url: URL
        do {
            if let resolver {
                url = try await resolver.previewURL(for: attachment)
            } else if attachment.resourceURI.hasPrefix("/") {
                url = URL(fileURLWithPath: attachment.resourceURI)
            } else if let directURL = URL(string: attachment.resourceURI),
                      directURL.isFileURL || directURL.scheme == "https" || directURL.scheme == "http" {
                url = directURL
            } else {
                return
            }

            let data = try await Task.detached(priority: .utility) {
                try Data(contentsOf: url, options: [.mappedIfSafe])
            }.value
#if os(macOS)
            guard let image = NSImage(data: data) else { return }
            previewImage = Image(nsImage: image)
#else
            guard let image = UIImage(data: data) else { return }
            previewImage = Image(uiImage: image)
#endif
        } catch {
            // Keep the neutral placeholder. Upload state remains independently visible.
        }
    }
}
// MARK: - Cross-platform surface colors

/// The approval panel uses window/fill surfaces that AppKit and UIKit name
/// differently; these bridge them so the file compiles on both platforms.
extension Color {
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


// MARK: - PlanApprovalBar

/// Plan Mode 审批卡片 — 展示完整 plan markdown。
/// 比工具审批更大，提供 Approve / Reject 按钮。
struct PlanApprovalBar: View {
    let plan: PlanApprovalRequest
    let onApprove: () -> Void
    let onReject: () -> Void
    
    private var displayPath: String? {
        plan.planPath ?? plan.filePath
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            VStack(alignment: .leading, spacing: 10) {
                // Header
                header
                
                if let path = displayPath, !path.isEmpty {
                    planPathRow(path)
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

                    Button(role: .destructive, action: onReject) {
                        Label("Reject", systemImage: "xmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    
                    Button(action: onApprove) {
                        Label("Approve Plan", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }
    
    private var header: some View {
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
    }
    
    private var actionButtons: some View {
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
    
    private func planPathRow(_ path: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            
            Spacer()
            
#if os(macOS)
            if canOpenPlanFile {
                Button {
                    openPlanFile()
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.plain)
                .help("Open plan file")
            }
#endif
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
    
#if os(macOS)
    private var canOpenPlanFile: Bool {
        guard let filePath = plan.filePath, !filePath.isEmpty else {
            return false
        }
        return FileManager.default.fileExists(atPath: filePath)
    }
    
    private func openPlanFile() {
        guard let filePath = plan.filePath else { return }
        
        NSWorkspace.shared.open(
            URL(fileURLWithPath: filePath)
        )
    }
#endif
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
struct ApprovalBar: View {
    let request: ApprovalRequest

    private var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "the agent"
    }
    
    private var approvalHeaderText: String {
        if request.isExternalPathAccess {
            return "\(appDisplayName) 请求访问工作区外的文件"
        }
        return "Allow \(appDisplayName) to run \(request.displayToolName)?"
    }

    
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
                    
                    Text(approvalHeaderText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    
                    Spacer()
                    
                    // 右侧 scope 选择标签（点击切换）— 外部路径访问无需 scope
                    if !request.isExternalPathAccess {
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
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                
                // 2. 中间工具与参数内容区 (类似代码块容器)
                VStack(alignment: .leading, spacing: 8) {
                    // 外部路径访问：显示路径卡片
                    if request.isExternalPathAccess {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(request.externalPathTarget)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                            Text(request.externalPathOperation)
                                .font(.system(.caption))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                        .frame(maxWidth: .infinity)
                    }
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
                        .frame(maxWidth: .infinity)
                    }
                    
                    if let args = request.toolArgs, case .object(let dict) = args, !dict.isEmpty, !request.isExternalPathAccess {
                        // 测量文本真实高度：≤10行自适应；>10行固定180pt可滚动
                        ScrollView(.vertical, showsIndicators: true) {
                            argsText(dict)
                                .background(GeometryReader { geo in
                                    Color.clear.preference(
                                        key: TextHeightKey.self,
                                        value: geo.size.height
                                    )
                                })
                                .frame(maxWidth: .infinity)
                        }
                        .onPreferenceChange(TextHeightKey.self) { contentHeight = $0 }
                        .frame(height: contentHeight > 0 ? min(contentHeight, 180) : nil)
                        .animation(.none, value: contentHeight)
                        
                    } else if !request.isMCP, !request.isExternalPathAccess {
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
                    if !request.isExternalPathAccess {
                        Button(action: { onAlwaysAllow(scope.rawValue) }) {
                            VStack(alignment: .center, spacing: 1) {
                                Text("Always allow ") + Text("2").foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .overlay(alignment: .top) {
                            if request.isMCP, let server = request.mcpServer {
                                Text("all from \"\(server)\"")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                    .offset(CGSizeMake(0, 20))
                            }
                        }
                    }
                    
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
        //            .textSelection(.enabled)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - AskUserBar

/// ask_user 卡片 — 显示在输入框上方，阻断 input pipeline。
/// 模型遇到歧义时展示选项供用户选择。优先级：AskUser > Plan > Approval。
struct AskUserBar: View {
    let request: AskUserRequest
    let onSubmit: ([String], String?) -> Void
    let onSkip: () -> Void

    @State private var selectedLabels: Set<String> = []
    @State private var customText: String = ""
    @State private var isExpanded: Bool = true

    /// 推荐项 label（含 `(Recommended)` 或 `（推荐）` 后缀），自动预选。
    private var recommendedLabel: String? {
        request.options.first { request.isRecommended($0) }?.label
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            VStack(alignment: .leading, spacing: 10) {
                // Header
                headerRow

                // Question text
                Text(request.question)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                // Options list
                if isExpanded {
                    optionsList
                }

                // Custom input (only when allowCustom)
                if request.allowCustom, isExpanded {
                    customInputRow
                }

                // Action buttons
                if isExpanded {
                    actionButtons
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(Color.approvalPanelBackground)
        .layerBorder()
        .padding(12)
        .onAppear {
            // Auto-select recommended option
            if let rec = recommendedLabel {
                selectedLabels = [rec]
            }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.bubble.fill")
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(request.header)
                    .font(.subheadline.weight(.semibold))

                Text(request.multiSelect ? "可多选" : "请选择一个选项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Deadline badge
            if let deadline = request.deadlineSeconds {
                Text("\(deadline)s")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }

            // Collapse/expand toggle
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "收起" : "展开")

            // Skip button
            Button(action: onSkip) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("跳过此问题")
        }
    }

    // MARK: - Options

    private var optionsList: some View {
        VStack(spacing: 6) {
            ForEach(request.options) { option in
                optionRow(option)
            }
        }
    }

    private func optionRow(_ option: AskUserOption) -> some View {
        let isSelected = selectedLabels.contains(option.label)
        let isRecommended = request.isRecommended(option)

        return Button {
            if request.multiSelect {
                if isSelected {
                    selectedLabels.remove(option.label)
                } else {
                    selectedLabels.insert(option.label)
                }
            } else {
                selectedLabels = [option.label]
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                // Selection indicator
                Group {
                    if request.multiSelect {
                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                            .foregroundStyle(isSelected ? .blue : .secondary)
                    } else {
                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isSelected ? .blue : .secondary)
                    }
                }
                .font(.system(size: 16))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(option.label)
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(.primary)

                        if isRecommended {
                            Text("推荐")
                                .font(.system(size: 9))
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.blue.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }

                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.blue.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.blue.opacity(0.3) : Color.gray.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Custom input

    private var customInputRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil.line")
                .foregroundStyle(.secondary)
                .font(.caption)

            TextField("自定义输入（可选）…", text: $customText)
                .textFieldStyle(.plain)
                .font(.subheadline)
        }
        .padding(10)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Actions

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button(action: onSkip) {
                Label("跳过", systemImage: "forward.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Button {
                let notes = customText.trimmingCharacters(in: .whitespacesAndNewlines)
                onSubmit(Array(selectedLabels), notes.isEmpty ? nil : notes)
            } label: {
                Label("确认选择", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(selectedLabels.isEmpty && customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
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
