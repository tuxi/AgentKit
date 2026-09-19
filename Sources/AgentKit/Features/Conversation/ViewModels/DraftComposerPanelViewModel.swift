//
//  DraftComposerPanelViewModel.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/9/19.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class DraftComposerPanelViewModel {
    // MARK: - Dependencies
    
    private let workspaceStore: WorkspaceStore
    private let modelSettings: ModelSettingsStore
    private let conversationViewModel: ConversationViewModel?
    private let isDraft: Bool
    private let placeholder: String
    private let isEnabled: Bool
    private let onSend: (_ text: String, _ model: UnifiedModel, _ assets: [UserAssetRef]) async -> Bool
    private let onModelChange: ((String) -> Void)?
    private let onAddAttachment: (() -> Void)?
    private let onStop: (() -> Void)?
    
    // MARK: - Published State (View binds to these)
    
    var text = ""
    var attachments: [DraftAttachmentReference] = []
    var selectedModel: UnifiedModel?
    var isSending = false
    var isTurnRunning = false
    
    // Context window
    var contextSnapshot: ConversationContextSnapshot?
    var isContextLoading = false
    var contextError: String?
    var isContextPresented = false
    
    // Voice
    let voiceService = VoiceInputService()
    var showPermissionAlert = false
    
    // Gateway upload confirmation
    var pendingGatewayUploadID: String?
    var isGatewayUploadConfirmationPresented = false
    
    // Model picker (iOS)
    var isIOSModelPickerPresented = false
    
    // Internal state
    private var submittedTextSnapshot: String?
    var loadedStateKey: ConversationLocalStateKey?
    private var pendingSaveTask: Task<Void, Never>?
    private var isRestoringLocalState = false
    private var contextRefreshTask: Task<Void, Never>?
    var contentWidth: CGFloat = 0
    private var draftRevision: Int
    
    // macOS-specific
#if os(macOS)
    var composerHeight: CGFloat = 56
    private let composerMinHeight: CGFloat = 56
    private let composerMaxHeight: CGFloat = 150
#endif
    
    // Computed
    var sessionID: String? {
        conversationViewModel?.conversation?.id ?? workspaceStore.selectedConversation?.id
    }
    
    var persistenceKey: ConversationLocalStateKey? {
        if isDraft, let id = workspaceStore.draft?.id {
            return .draft(id)
        }
        if let id = conversationViewModel?.conversation?.id ?? workspaceStore.selectedConversation?.id {
            return .session(id)
        }
        return nil
    }
    
    var canSend: Bool {
        let hasContent = !trimmed.isEmpty || !attachments.isEmpty
        let attachmentsReady = attachments.allSatisfy { attachment in
            if attachment.delivery == .localOnly {
                return attachment.state == .local
                || attachment.state == .ready
                || (isDraft && attachment.state == .failed && attachment.localAsset == nil)
            }
            return attachment.state == .ready
        }
        return isEnabled && hasContent && attachmentsReady && !isSending
        && !isTurnRunning && modelSettings.isModelAvailable(selectedModel?.model)
    }
    
    var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    var readyAssets: [UserAssetRef] {
        attachments.compactMap { attachment in
            guard attachment.state == .ready,
                  attachment.delivery == .gateway else { return nil }
            return attachment.readyAsset
        }
    }
    
    var modelGroups: [ComposerModelGroup] {
        modelSettings.unifiedModelGroups.map { group in
            ComposerModelGroup(
                id: group.connectionID,
                name: group.name,
                modelIDs: group.models.map({ $0.model })
            )
        }
    }
    
    // MARK: - Init
    
    init(
        workspaceStore: WorkspaceStore,
        modelSettings: ModelSettingsStore,
        conversationViewModel: ConversationViewModel?,
        isDraft: Bool,
        placeholder: String,
        isEnabled: Bool,
        isTurnRunning: Bool = false,
        draftRevision: Int = 0,
        onSend: @escaping (_ text: String, _ model: UnifiedModel, _ assets: [UserAssetRef]) async -> Bool,
        onModelChange: ((String) -> Void)? = nil,
        onAddAttachment: (() -> Void)? = nil,
        onStop: (() -> Void)? = nil
    ) {
        self.workspaceStore = workspaceStore
        self.modelSettings = modelSettings
        self.conversationViewModel = conversationViewModel
        self.isDraft = isDraft
        self.placeholder = placeholder
        self.isEnabled = isEnabled
        self.isTurnRunning = isTurnRunning
        self.draftRevision = draftRevision
        self.onSend = onSend
        self.onModelChange = onModelChange
        self.onAddAttachment = onAddAttachment
        self.onStop = onStop
        
        setupVoiceCallbacks()
    }
    
    // MARK: - Lifecycle
    
    func onAppear() {
        refreshContext()
        restoreLocalState()
    }
    
    func onDisappear() {
        if voiceService.state == .recording {
            voiceService.cancelRecording()
        }
        contextRefreshTask?.cancel()
        persistCurrentText()
    }
    
    func onGeometryChange(width: CGFloat) {
        contentWidth = width
    }
    
    func handleScenePhaseChange(_ phase: ScenePhase) {
        if phase == .background || phase == .inactive {
            if voiceService.state == .recording {
                voiceService.cancelRecording()
            }
            persistCurrentText()
            try? workspaceStore.localStateStore.flush()
        }
    }
    
    // MARK: - Voice
    
    private func setupVoiceCallbacks() {
        voiceService.onTranscriptionComplete = { [weak self] transcription in
            guard let self, !transcription.isEmpty else { return }
            if self.text.isEmpty {
                self.text = transcription
            } else {
                self.text += "\n" + transcription
            }
        }
    }
    
    func handleVoiceStateChange(_ newState: VoiceInputService.State) {
        if case .error = newState {
            showPermissionAlert = true
        }
    }
    
    // MARK: - Model Selection
    
    func selectModel(_ modelID: String, reasoningEffort: ModelReasoningEffort?) {
        guard !modelID.isEmpty else { return }
        let model = UnifiedModel(model: modelID, reasoningEffort: reasoningEffort)
        selectedModel = model
        conversationViewModel?.selectedModel = model
        
        modelSettings.didUseModel(
            modelID,
            reasoningEffort: reasoningEffort,
            conversation: conversationViewModel?.conversation?.id ?? ""
        )
        persistModel(modelID, reasoningEffort: reasoningEffort)
        if let wireModel = modelSettings.getWireModelID(for: modelID) {
            onModelChange?(wireModel)
        }
    }
    
    func applyReasoningEffort(_ effort: ModelReasoningEffort, for modelID: String) {
        selectModel(modelID, reasoningEffort: effort)
    }
    
    func effectiveReasoningEffort(for modelID: String, supported: [ModelReasoningEffort]) -> ModelReasoningEffort? {
        if modelID == selectedModel?.model,
           let override = storedReasoningEffortOverride,
           supported.contains(override) {
            return override
        }
        return modelSettings.descriptor(for: modelID)?.reasoningEffort
    }
    
    private var storedReasoningEffortOverride: ModelReasoningEffort? {
        guard let key = loadedStateKey,
              let raw = try? workspaceStore.localStateStore.state(for: key)?.reasoningEffort,
              !raw.isEmpty else { return nil }
        return ModelReasoningEffort(rawValue: raw)
    }
    
    // MARK: - Send Flow
    
    func send() {
        // Stop recording if active
        if voiceService.state == .recording {
            voiceService.stopRecordingAndTranscribe()
        }
        
        guard canSend, let selectedModel else { return }
        
        let toSend = trimmed
        submittedTextSnapshot = toSend
        
        // Optimistic clear
        text = ""
        let sendingAssets = readyAssets
        attachments = []
        if let key = loadedStateKey {
            persist(text: "", for: key)
        }
        isSending = true
        
        Task {
            let accepted = await onSend(toSend, selectedModel, sendingAssets)
            if !accepted {
                restoreSubmittedText(toSend)
                refreshAttachmentsFromLocalState()
            }
            isSending = false
        }
    }
    
    func stop() {
        onStop?()
    }
    
    private func restoreSubmittedText(_ snapshot: String) {
        submittedTextSnapshot = nil
        guard !snapshot.isEmpty else { return }
        if text.isEmpty {
            text = snapshot
        } else if !text.hasPrefix(snapshot) {
            text = snapshot + "\n" + text
        }
        persistCurrentText()
    }
    
    func reconcileAcceptedSubmission() {
        pendingSaveTask?.cancel()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let submittedTextSnapshot, !submittedTextSnapshot.isEmpty {
                if self.text == submittedTextSnapshot {
                    self.text = ""
                } else if self.text.hasPrefix(submittedTextSnapshot) {
                    self.text.removeFirst(submittedTextSnapshot.count)
                    self.text = self.text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                self.submittedTextSnapshot = nil
                self.refreshAttachmentsFromLocalState()
                self.persistCurrentText()
            } else {
                self.restoreLocalState(persistOutgoingText: false)
            }
        }
    }
    
    func handleSubmissionRejected() {
        if let snapshot = submittedTextSnapshot, !snapshot.isEmpty,
           let key = loadedStateKey,
           (try? workspaceStore.localStateStore.state(for: key))?
               .composerDraft.pendingSubmission == nil {
            restoreSubmittedText(snapshot)
        } else {
            submittedTextSnapshot = nil
        }
        refreshAttachmentsFromLocalState()
    }
    
    // MARK: - Attachments
    
    func pickAttachments() {
        guard let key = persistenceKey else { return }
        Task {
            await workspaceStore.selectUserAssets(
                for: key,
                remainingSlots: maxFilesCount - attachments.count
            ) { [weak self] in
                self?.refreshAttachmentsFromLocalState()
            }
        }
    }
    
    func handleDroppedImages(_ urls: [URL]) {
        guard let key = persistenceKey,
              workspaceStore.canStageLocalUserAssets else { return }
        let remainingSlots = maxFilesCount - attachments.count
        guard remainingSlots > 0 else { return }
        Task {
            await workspaceStore.addDroppedFiles(
                urls,
                for: key,
                maxFilesCount: maxFilesCount
            ) { [weak self] in
                self?.refreshAttachmentsFromLocalState()
            }
        }
    }
    
    func removeAttachment(_ id: String) {
        attachments.removeAll { $0.id == id }
        persistCurrentDraft()
    }
    
    func retryAttachment(_ id: String) {
        guard let key = persistenceKey else { return }
        Task {
            await workspaceStore.retryLocalUserAssetStaging(id: id, for: key) { [weak self] in
                self?.refreshAttachmentsFromLocalState()
            }
        }
    }
    
    func canOfferGatewayUpload(for attachment: DraftAttachmentReference) -> Bool {
        guard workspaceStore.canUploadUserAssetsToGateway,
              attachment.delivery == .localOnly,
              attachment.state != .uploading,
              attachment.state != .sending else { return false }
        let name = attachment.displayName.lowercased()
        return name.hasSuffix(".jpg")
        || name.hasSuffix(".jpeg")
        || name.hasSuffix(".png")
        || attachment.localAsset?.mimeType == "image/jpeg"
        || attachment.localAsset?.mimeType == "image/png"
    }
    
    func requestGatewayUpload(_ id: String) {
        pendingGatewayUploadID = id
        isGatewayUploadConfirmationPresented = true
    }
    
    func confirmGatewayUpload() {
        guard let id = pendingGatewayUploadID,
              let key = persistenceKey else { return }
        pendingGatewayUploadID = nil
        Task {
            await workspaceStore.uploadUserAssetToGateway(id: id, for: key) { [weak self] in
                self?.refreshAttachmentsFromLocalState()
            }
        }
    }
    
    private func refreshAttachmentsFromLocalState() {
        guard let key = loadedStateKey,
              let state = try? workspaceStore.localStateStore.state(for: key) else { return }
        attachments = visibleAttachments(from: state)
    }
    
    private func visibleAttachments(from state: ConversationLocalState) -> [DraftAttachmentReference] {
        guard let pending = state.composerDraft.pendingSubmission else {
            return state.composerDraft.attachments
        }
        let pendingIDs = Set(pending.attachmentIDs)
        return state.composerDraft.attachments.filter { !pendingIDs.contains($0.id) }
    }
    
    // MARK: - Context Window
    
    func refreshContext() {
        guard let id = sessionID else { return }
        contextRefreshTask?.cancel()
        isContextLoading = true
        contextRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await workspaceStore.client.getConversationContext(id: id)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.contextSnapshot = snapshot
                    self.contextError = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.contextSnapshot = nil
                    self.contextError = Self.mapContextError(error)
                }
            }
            await MainActor.run {
                self.isContextLoading = false
            }
        }
    }
    
    private static func mapContextError(_ error: Error) -> String {
        if let httpError = error as? RuntimeHTTPError {
            switch httpError {
            case .unsupported, .notFound:
                return AgentKitLocalized.string("context_window.unsupported")
            default:
                return AgentKitLocalized.string("context_window.load_failed")
            }
        }
        return AgentKitLocalized.string("context_window.load_failed")
    }
    
    // MARK: - Local State Persistence
    
    func restoreLocalState(persistOutgoingText: Bool = true) {
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
        attachments = state.map { visibleAttachments(from: $0) } ?? []
        submittedTextSnapshot = state?.composerDraft.pendingSubmission?.text
        
        if let selectedModelID = state?.selectedModelID {
            selectedModel = UnifiedModel(model: selectedModelID, reasoningEffort: ModelReasoningEffort(rawValue: state?.reasoningEffort ?? ""))
        } else {
            let mo = modelSettings.getModel(with: conversationViewModel?.conversation?.id)
            selectedModel = mo
        }
    }
    
    func scheduleTextSave(_ value: String, for key: ConversationLocalStateKey) {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            persist(text: value, for: key)
        }
    }
    
    func persistCurrentText() {
        pendingSaveTask?.cancel()
        guard let key = loadedStateKey else { return }
        persist(text: text, for: key)
    }
    
    private func persist(text: String, for key: ConversationLocalStateKey) {
        try? workspaceStore.localStateStore.updateState(for: key) { state in
            state.composerDraft.text = text
        }
    }
    
    func persistCurrentDraft() {
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
    
    private func persistModel(_ modelID: String, reasoningEffort: ModelReasoningEffort?) {
        guard let key = loadedStateKey, !modelID.isEmpty else { return }
        try? workspaceStore.localStateStore.updateState(for: key) { state in
            state.selectedModelID = modelID
            state.reasoningEffort = reasoningEffort?.rawValue
            state.recentModelIDs.removeAll { $0 == modelID }
            state.recentModelIDs.insert(modelID, at: 0)
            if state.recentModelIDs.count > 8 {
                state.recentModelIDs.removeLast(state.recentModelIDs.count - 8)
            }
        }
    }
    
    // MARK: - Model Settings Change Handling
    
    func handleModelSettingsChange(newIDs: [String]) {
        guard !newIDs.isEmpty, let current = selectedModel, current.model.isEmpty else { return }
        let resolved = modelSettings.getModel(with: conversationViewModel?.conversation?.id)
        if let resolved, !resolved.model.isEmpty {
            selectedModel = resolved
        }
    }
    
    func handleViewModelModelChange(oldModel: UnifiedModel, newModel: UnifiedModel) {
        guard oldModel != newModel, newModel != selectedModel else { return }
        selectModel(newModel.model, reasoningEffort: newModel.reasoningEffort)
    }
    
    // MARK: - Turn Running
    
    func setTurnRunning(_ running: Bool) {
        isTurnRunning = running
        if !running {
            refreshContext()
        }
    }
    
    // MARK: - Constants
    
    var maxFilesCount: Int { 4 }
    var composerControlSpacing: CGFloat {
#if os(macOS)
        12
#else
        8
#endif
    }
    
    var sendButtonSize: CGFloat {
#if os(macOS)
        30
#else
        34
#endif
    }
    
    // MARK: - Context Ring
    
    var contextRingProgress: CGFloat {
        guard let current = contextSnapshot?.current else { return 0 }
        return CGFloat(ContextFormat.clamped(current.usagePct / 100))
    }
    
    var contextRingColor: Color {
        guard let current = contextSnapshot?.current else { return .secondary }
        if current.usagePct >= current.thresholdPct { return .red }
        if current.usagePct >= current.thresholdPct * 0.8 { return .orange }
        return .green
    }
    
    var contextButtonAccessibilityLabel: String {
        if let current = contextSnapshot?.current {
            return String(
                format: AgentKitLocalized.string("composer.context_window_usage"),
                current.usagePct
            )
        }
        return AgentKitLocalized.string("composer.context_window")
    }
    
    // MARK: - Approval Mode Helpers
    
    func approvalModeTitle(_ mode: String) -> String {
        switch mode {
        case "auto": return "帮我批准 (Auto)"
        case "full": return "完全访问 (Full)"
        default: return "请求批准 (Ask)"
        }
    }
    
    func approvalModeShortTitle(_ mode: String?) -> String {
        guard let mode, !mode.isEmpty else { return "权限" }
        switch mode {
        case "auto": return "帮我批准"
        case "full": return "完全访问"
        default: return "请求批准"
        }
    }
    
    func approvalModeIcon(_ mode: String?) -> String {
        switch mode {
        case "auto": return "shield.lefthalf.filled"
        case "full": return "shield.fill"
        default: return "shield"
        }
    }
}

// MARK: - Model Group Helper

struct ComposerModelGroup: Identifiable {
    let id: String
    let name: String
    let modelIDs: [String]
}

