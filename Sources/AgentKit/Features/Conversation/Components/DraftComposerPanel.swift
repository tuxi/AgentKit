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
import ClientToolProtocol
#endif


// MARK: - DraftComposerPanel

/// 统一输入面板 —— 合并了原 `ChatComposer` 和 `DraftComposerPanel`。
/// 用于草稿页（新建对话）和活跃会话两种场景。
/// 对标 Claude Code / Codex：模型选择器在输入栏中，每个对话独立管理自己的模型。
struct DraftComposerPanel: View {
    @Environment(\.scenePhase) private var scenePhase
    
    let viewModel: ConversationViewModel?
    
    @State private var vm: DraftComposerPanelViewModel
    
    init(workspaceStore: WorkspaceStore, modelSettings: ModelSettingsStore, viewModel: ConversationViewModel?, draftRevision: Int = 0, placeholder: String, isEnabled: Bool, isDraft: Bool, isTurnRunning: Bool = false, onStop: (() -> Void)? = nil, onSend: @escaping (_: String, _: UnifiedModel, _: [UserAssetRef]) async -> Bool, onAddAttachment: (() -> Void)? = nil, onModelChange: ((String) -> Void)? = nil) {
        self.viewModel = viewModel
        self.vm = DraftComposerPanelViewModel(
            workspaceStore: workspaceStore,
            modelSettings: modelSettings,
            conversationViewModel: viewModel,
            isDraft: isDraft,
            placeholder: placeholder,
            isEnabled: isEnabled,
            isTurnRunning: isTurnRunning,
            draftRevision: draftRevision,
            onSend: onSend,
            onModelChange: onModelChange,
            onAddAttachment: onAddAttachment,
            onStop: onStop
        )
    }
    
    var body: some View {
        contentView(vm)
            .id(vm.persistenceKey)
    }
    
   
    private func contentView(_ vm: DraftComposerPanelViewModel) -> some View {
        VStack(spacing: 0) {
#if os(iOS)
            if vm.isDraft {
                WorkspaceChipBar()
                    .padding(.horizontal, 4)
                    .padding(.top, 3)
                Divider()
                    .opacity(0.45)
                    .padding(.horizontal, 12)
            }
#endif
            
            composerContent(vm)
            
#if os(macOS)
            if vm.isDraft {
                WorkspaceChipBar()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.draftPanelFooterBackground)
            }
#endif
        }
        .onAppear {
            vm.onAppear()
        }
        .onDisappear {
            vm.onDisappear()
        }
        .onGeometryChange(for: CGFloat.self, of: { proxy in
            return proxy.size.width
        }, action: { _, newValue in
            vm.onGeometryChange(width: newValue)
        })
        .onChange(of: scenePhase) { _, phase in
            vm.handleScenePhaseChange(phase)
        }
        .onChange(of: vm.isTurnRunning) { _, newValue in
            vm.setTurnRunning(newValue)
        }
        .onChange(of: vm.modelSettings.availableModelIDs) { _, newIDs in
            vm.handleModelSettingsChange(newIDs: newIDs)
        }
        .onChange(of: viewModel?.lastAcceptedSubmissionRequestID) { _, _ in
            vm.reconcileAcceptedSubmission()
        }
        .onChange(of: viewModel?.lastInputRejection) { _, newValue in
            if newValue != nil {
                vm.handleSubmissionRejected()
            }
        }
        .onChange(of: viewModel?.selectedModel) { _, newModel in
            guard let newModel, newModel != vm.selectedModel else { return }
            vm.handleViewModelModelChange(oldModel: vm.selectedModel ?? UnifiedModel(model: "", reasoningEffort: nil), newModel: newModel)
        }
        .modifier(DraftComposerSurfaceModifier())
        .confirmationDialog(
            "这会将文件上传到云端进行视觉识别。",
            isPresented: Binding(
                get: { vm.isGatewayUploadConfirmationPresented },
                set: { vm.isGatewayUploadConfirmationPresented = $0 }
            ),
            titleVisibility: .visible
        ) {
            Button("上传并使用云端视觉") {
                vm.confirmGatewayUpload()
            }
            Button("取消", role: .cancel) {
                vm.pendingGatewayUploadID = nil
            }
        }
        .alert(AgentKitLocalized.string("composer.voice_input.no_permission_title"),
               isPresented: Binding(
                get: { vm.showPermissionAlert },
                set: { vm.showPermissionAlert = $0 }
               )) {
            Button(AgentKitLocalized.string("composer.voice_input.open_settings")) {
                VoiceInputService.openSystemSettings()
            }
            Button(AgentKitLocalized.string("composer.voice_input.cancel"), role: .cancel) {
                vm.voiceService.reset()
            }
        } message: {
            Text(AgentKitLocalized.string("composer.voice_input.no_permission"))
        }
#if os(iOS)
        .sheet(isPresented: Binding(
            get: { vm.isIOSModelPickerPresented },
            set: { vm.isIOSModelPickerPresented = $0 }
        )) {
            IOSModelPickerSheet(
                groups: vm.modelGroups,
                ungroupedModelIDs: vm.modelGroups.isEmpty ? vm.modelSettings.availableModelIDs : [],
                selectedModel: vm.selectedModel,
                displayName: { vm.modelSettings.displayName(for: $0) },
                onSelect: { modelID in
                    let resolved = vm.modelSettings.getModel(with: viewModel?.conversation?.id)
                    if let resolved, !resolved.model.isEmpty {
                        vm.selectModel(modelID, reasoningEffort: resolved.reasoningEffort)
                    }
                }
            )
            .presentationDetents([.medium, .height(260)])
            .presentationDragIndicator(.visible)
        }
#endif
    }
    
    @ViewBuilder
    private func composerContent(_ vm: DraftComposerPanelViewModel) -> some View {
        VStack(spacing: 8) {
            if vm.voiceService.state == .recording || vm.voiceService.state == .transcribing {
                VoiceRecordingOverlay(
                    service: vm.voiceService,
                    onStop: { vm.voiceService.stopRecordingAndTranscribe() },
                    onSend: { vm.send() }
                )
                .padding(.horizontal, 2)
                .padding(.top, vm.attachments.isEmpty ? 8 : 2)
            } else {
                if !vm.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        attachmentStrip(vm)
                        Text("🔒 本地处理 · 文件不会自动上传")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
                inputField(vm)
                    .padding(.horizontal, 16)
                    .padding(.top, vm.attachments.isEmpty ? 14 : 2)
            }
            
            if vm.voiceService.state != .recording && vm.voiceService.state != .transcribing && vm.voiceService.state != .preparing {
                HStack(spacing: vm.composerControlSpacing) {
                    Button {
                        if let onAddAttachment = vm.onAddAttachment {
                            onAddAttachment()
                        } else {
                            vm.pickAttachments()
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(AgentKitLocalized.string("composer.add_attachment"))
                    .disabled(
                        vm.attachments.count >= 4
                        || (vm.onAddAttachment == nil && !vm.workspaceStore.canSelectUserAssets)
                    )
                    
#if os(macOS)
                    if let conversationVM = viewModel,
                       conversationVM.workspacePermissionPath != nil {
                        Menu {
                            ForEach(conversationVM.workspacePermissionModes, id: \.self) { mode in
                                Button {
                                    Task { await conversationVM.setWorkspacePermissionMode(mode) }
                                } label: {
                                    if mode == conversationVM.workspacePermissionMode {
                                        Label(vm.approvalModeTitle(mode), systemImage: "checkmark")
                                    } else {
                                        Text(vm.approvalModeTitle(mode))
                                    }
                                }
                            }
                            Divider()
                            Text("将应用于此工作区的所有对话")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let error = conversationVM.workspacePermissionError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        } label: {
                            if vm.contentWidth <= 400 {
                                Image(systemName: vm.approvalModeIcon(conversationVM.workspacePermissionMode))
                                    .font(.system(size: 13, weight: .medium))
                                    .labelStyle(.titleAndIcon)
                            } else {
                                Label(
                                    vm.approvalModeShortTitle(conversationVM.workspacePermissionMode),
                                    systemImage: vm.approvalModeIcon(conversationVM.workspacePermissionMode)
                                )
                            }
                        }
                        .help("对话所属工作区的权限档位")
                        .task(id: conversationVM.workspacePermissionPath) {
                            await conversationVM.loadWorkspacePermissions()
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .foregroundStyle(.secondary)
                    }
#endif
                    
                    Spacer(minLength: 12)
                    
                    // ── Model Selector ──
#if os(iOS)
                    Button {
                        vm.isIOSModelPickerPresented = true
                    } label: {
                        HStack(spacing: 5) {
                            Text(vm.modelSettings.selectionDisplayName(for: vm.selectedModel?.model ?? ""))
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            Image(systemName: "chevron.up")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 9)
                        .frame(height: 32)
                        .background(
                            Color.accentColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: 132)
                    .disabled(vm.modelSettings.availableModelIDs.isEmpty)
                    .accessibilityLabel(AgentKitLocalized.string("composer.select_model"))
#else
                    Menu {
                        if vm.modelGroups.isEmpty {
                            ForEach(vm.modelSettings.availableModelIDs, id: \.self) { modelID in
                                modelMenuEntry(modelID, vm: vm)
                            }
                        } else {
                            ForEach(vm.modelGroups) { group in
                                Section {
                                    ForEach(group.modelIDs, id: \.self) { modelID in
                                        modelMenuEntry(modelID, vm: vm)
                                    }
                                } header: {
                                    Text(group.name)
                                }
                            }
                        }
                        
                    } label: {
                        if vm.contentWidth <= 500 {
                            Image(systemName: "brain.head.profile")
                                .font(.system(size: 9, weight: .semibold))
                        } else {
                            Text(vm.modelSettings.selectionDisplayName(for: vm.selectedModel?.model ?? ""))
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                                .frame(maxWidth: 35)
                        }
                    }
                    .menuStyle(.borderlessButton)
                        .fixedSize()
#endif
                    VoiceInputButton(service: vm.voiceService)
                    
                    // ── Send / Stop button ──
                    if vm.isTurnRunning {
                        Button {
                            vm.stop()
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 12, weight: .bold))
                                .frame(width: vm.sendButtonSize, height: vm.sendButtonSize)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .background(Color.red, in: Circle())
                        .accessibilityLabel(AgentKitLocalized.string("composer.stop"))
                    } else {
                        Button {
                            vm.send()
                        } label: {
                            if vm.isSending {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: vm.sendButtonSize, height: vm.sendButtonSize)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 16, weight: .bold))
                                    .frame(width: vm.sendButtonSize, height: vm.sendButtonSize)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(vm.canSend ? Color.draftSendForeground : Color.draftDisabledSendForeground)
                        .background(vm.canSend ? Color.draftSendBackground : Color.draftDisabledSendBackground, in: Circle())
                        .disabled(!vm.canSend)
                        .accessibilityLabel(AgentKitLocalized.string("composer.send"))
                    }
                    
                    if vm.sessionID != nil {
                        Button {
                            vm.isContextPresented = true
                            vm.refreshContext()
                        } label: {
                            contextUsageRing(vm)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(vm.contextButtonAccessibilityLabel)
#if os(macOS)
                        .help(AgentKitLocalized.string("composer.context_window"))
                        .popover(isPresented: Binding(
                            get: { vm.isContextPresented },
                            set: { vm.isContextPresented = $0 }
                        ), arrowEdge: .bottom) {
                            ContextWindowDetailView(
                                snapshot: vm.contextSnapshot,
                                isLoading: vm.isContextLoading,
                                errorMessage: vm.contextError,
                                onRefresh: { vm.refreshContext() }
                            )
                        }
#else
                        .sheet(isPresented: Binding(
                            get: { vm.isContextPresented },
                            set: { vm.isContextPresented = $0 }
                        )) {
                            NavigationStack {
                                ContextWindowDetailView(
                                    snapshot: vm.contextSnapshot,
                                    isLoading: vm.isContextLoading,
                                    errorMessage: vm.contextError,
                                    onRefresh: { vm.refreshContext() }
                                )
                                .toolbar {
                                    ToolbarItem(placement: .topBarTrailing) {
                                        Button(AgentKitLocalized.string("composer.done")) {
                                            vm.isContextPresented = false
                                        }
                                    }
                                }
                            }
                            .presentationDetents([.medium, .large])
                        }
#endif
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
        .onChange(of: vm.voiceService.state) { _, newState in
            vm.handleVoiceStateChange(newState)
        }
        .onChange(of: vm.text) { _, newValue in
            guard let key = vm.loadedStateKey else { return }
            vm.scheduleTextSave(newValue, for: key)
        }
    }
    
    // MARK: - Input Field
    
    @ViewBuilder
    private func inputField(_ vm: DraftComposerPanelViewModel) -> some View {
#if os(macOS)
        MacComposerTextView(
            text: Binding(
                get: { vm.text },
                set: { vm.text = $0 }
            ),
            height: Binding(
                get: { vm.composerHeight },
                set: { vm.composerHeight = $0 }
            ),
            placeholder: vm.placeholder,
            isEnabled: true,
            minHeight: 56,
            maxHeight: 150,
            onSend: {
                vm.send()
            },
            onFileDrop: { urls in
                vm.handleDroppedImages(urls)
                return true
            }
        )
        .frame(height: vm.composerHeight)
#else
        TextField(vm.placeholder, text: Binding(
            get: { vm.text },
            set: { vm.text = $0 }
        ), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(1...5)
            .frame(minHeight: 44, alignment: .topLeading)
            .disabled(!vm.isEnabled)
#endif
    }
    
    // MARK: - Attachment Strip
    
    private func attachmentStrip(_ vm: DraftComposerPanelViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(vm.attachments) { attachment in
                    DraftAttachmentThumbnail(
                        attachment: attachment,
                        resolver: vm.workspaceStore.userAssetDraftPreviewResolver,
                        onRemove: { vm.removeAttachment(attachment.id) },
                        onRetry: { vm.retryAttachment(attachment.id) },
                        onUploadToGateway: vm.canOfferGatewayUpload(for: attachment)
                        ? { vm.requestGatewayUpload(attachment.id) }
                        : nil
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    // MARK: - Context Ring
    
    private func contextUsageRing(_ vm: DraftComposerPanelViewModel) -> some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: 3)
            Circle()
                .trim(from: 0, to: vm.contextRingProgress)
                .stroke(vm.contextRingColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 11, height: 11)
        .contentShape(Circle())
    }
    
    // MARK: - Model Menu Entry (macOS)
    
#if os(macOS)
    @ViewBuilder
    private func modelMenuEntry(_ modelID: String, vm: DraftComposerPanelViewModel) -> some View {
        if let model = vm.modelSettings.descriptor(for: modelID) {
            let supported = model.supportedReasoningEfforts ?? []
            let items = model.canDisableReasoning == true ? [ModelReasoningEffort.off] + supported : supported
            if items.isEmpty {
                modelMenuButton(modelID, vm: vm)
            } else {
                Button {
                    let selected = vm.effectiveReasoningEffort(for: modelID, supported: items)
                    vm.applyReasoningEffort(selected ?? .off, for: modelID)
                } label: {
                    reasoningEffortMenu(modelID: modelID, supported: items, vm: vm)
                }
            }
        } else {
            modelMenuButton(modelID, vm: vm)
        }
    }
    
    private func modelMenuButton(_ modelID: String, vm: DraftComposerPanelViewModel) -> some View {
        Button {
            vm.selectModel(modelID, reasoningEffort: nil)
        } label: {
            HStack {
                Text(vm.modelSettings.displayName(for: modelID))
                if modelID == vm.selectedModel?.model {
                    Image(systemName: "checkmark")
                }
            }
        }
    }
    
    private func reasoningEffortMenu(modelID: String, supported: [ModelReasoningEffort], vm: DraftComposerPanelViewModel) -> some View {
        let selected = vm.effectiveReasoningEffort(for: modelID, supported: supported)
        
        return Menu {
            Divider()
            
            Section("Reasoning Effort") {
                ForEach(supported) { effort in
                    Button {
                        vm.applyReasoningEffort(effort, for: modelID)
                    } label: {
                        HStack {
                            Text(effort.name)
                            if effort == selected {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack {
                Text(vm.modelSettings.displayName(for: modelID))
                if modelID == vm.selectedModel?.model {
                    Image(systemName: "checkmark")
                }
            }
        }
        .menuStyle(.borderlessButton)
    }
#endif
}

// MARK: - Attachment Thumbnail & Preview

private struct DraftAttachmentThumbnail: View {
    let attachment: DraftAttachmentReference
    let resolver: (any UserAssetDraftPreviewResolving)?
    let onRemove: () -> Void
    let onRetry: () -> Void
    let onUploadToGateway: (() -> Void)?
    
    var body: some View {
        ZStack {
            DraftAttachmentPreview(attachment: attachment, resolver: resolver)
                .frame(width: 96, height: 76)
            
            stateOverlay
            
            VStack {
                HStack {
                    Spacer()
                    if attachment.state != .sending {
                        Button(action: onRemove) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(.black.opacity(0.72), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(format: AgentKitLocalized.string("composer.remove_attachment"), attachment.displayName))
                    }
                }
                Spacer()
                if let onUploadToGateway {
                    HStack {
                        Spacer()
                        Button(action: onUploadToGateway) {
                            Image(systemName: "cloud")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 22)
                                .background(.blue.opacity(0.82), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("上传并使用云端视觉")
                    }
                }
            }
            .padding(5)
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
        case .local:
            EmptyView()
        case .preparing:
            statusOverlay(title: AgentKitLocalized.string("composer.processing"), progress: nil)
        case .uploading:
            statusOverlay(
                title: String(format: AgentKitLocalized.string("composer.uploading_pct"), String(Int((attachment.progress ?? 0) * 100))),
                progress: attachment.progress
            )
        case .failed:
            Button(action: onRetry) {
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.system(size: 18, weight: .semibold))
                    Text(verbatim: AgentKitLocalized.string("composer.upload_failed_retry"))
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.58))
            }
            .buttonStyle(.plain)
            .accessibilityHint(attachment.failure?.message ?? AgentKitLocalized.string("composer.tap_to_retry"))
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
        case .local, .preparing: return String(format: AgentKitLocalized.string("composer.attachment_processing"), attachment.displayName)
        case .uploading: return String(format: AgentKitLocalized.string("composer.attachment_uploading"), attachment.displayName)
        case .failed: return String(format: AgentKitLocalized.string("composer.attachment_failed"), attachment.displayName)
        case .ready: return String(format: AgentKitLocalized.string("composer.attachment_ready"), attachment.displayName)
        case .sending: return String(format: AgentKitLocalized.string("composer.attachment_sending"), attachment.displayName)
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
    
    
    static var draftPanelFooterBackground: Color {
#if os(macOS)
        Color(NSColor.separatorColor).opacity(0.12)
#else
        Color(UIColor.tertiarySystemBackground)
#endif
    }
    
    // iOS 端这个颜色现在可以被移除，因为我们不使用描边
    // 但为了代码兼容性，可以把它设为透明
    static var draftPanelStroke: Color {
#if os(macOS)
        Color(NSColor.separatorColor).opacity(0.35)
#else
        Color.clear // 极致 iOS 风格不使用描边
#endif
    }
    static var draftSendBackground: Color {
#if os(macOS)
        Color(NSColor.labelColor)
#else
        Color.accentColor
#endif
    }
    
    static var draftSendForeground: Color {
#if os(macOS)
        Color(NSColor.windowBackgroundColor)
#else
        Color.white
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
}

struct DraftComposerSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
#if os(macOS)
        content
            .background(colorScheme == .dark ?         Color(NSColor(
                calibratedRed: 44.0 / 255.0,
                green: 44.0 / 255.0,
                blue: 46.0 / 255.0,
                alpha: 1
            )) : Color(NSColor.windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding()
            .shadow(color: .black.opacity(0.10), radius: 20, y: 10)
#else
        content
        // 1. 强依赖 Material，使用 .thinMaterial 可以让背景颜色适度渗透
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        // 2. 移除任何纯色 background 叠加，只靠 Material
        // 3. **极致关键：干掉描边 (overlay stroke)**
            .padding(.horizontal, 16) // 调整 padding
            .padding(.vertical, 8)  // 调整 padding
        // 4. 极致阴影：极淡、极弥散
            .shadow(color: Color.black.opacity(0.02), radius: 6, x: 0, y: 2)   // 几乎不可见的近景阴影
            .shadow(color: Color.black.opacity(0.04), radius: 20, x: 0, y: 6)  // 柔和弥散阴影
#endif
    }
}
