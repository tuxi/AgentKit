//
//  SwiftUIView.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/7/10.
//

import SwiftUI


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
    let onSend: (_ text: String, _ model: String) async -> Bool

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
                    .foregroundStyle(.secondary)

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

    private var canSend: Bool {
        isEnabled && !trimmed.isEmpty && !isSending && !isTurnRunning && !(selectedModel ?? "").isEmpty
    }

    private func send() {
        guard canSend else { return }
        let toSend = text
        isSending = true
        Task {
            let ok = await onSend(toSend, selectedModel ?? "")
            isSending = false
            if ok {
                text = ""
                persistCurrentText()
            }
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

    private func restoreLocalState() {
        pendingSaveTask?.cancel()
        if let oldKey = loadedStateKey {
            persist(text: text, for: oldKey)
        }
        let key = persistenceKey
        loadedStateKey = key
        isRestoringLocalState = true
        defer { isRestoringLocalState = false }

        let state = key.flatMap { try? workspaceStore.localStateStore.state(for: $0) }
        text = state?.composerDraft.text ?? ""
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
                        .frame(maxWidth: .infinity)
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
                                .frame(maxWidth: .infinity)
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
