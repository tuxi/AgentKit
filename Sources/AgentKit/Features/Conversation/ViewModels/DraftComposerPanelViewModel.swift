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
    
    let workspaceStore: WorkspaceStore
    let modelSettings: ModelSettingsStore
    let conversationViewModel: ConversationViewModel?
    let isDraft: Bool
    let onSend: (_ text: String, _ model: UnifiedModel?, _ assets: [UserAssetRef]) async -> Bool
    let onModelChange: ((String) -> Void)?
    let onAddAttachment: (() -> Void)?
    let onStop: (() -> Void)?
    
    // MARK: - Published State (View binds to these)
    
    var text = ""
    var attachments: [DraftAttachmentReference] = []
    /// Input intent. `.followDefault` means the next request omits `model`.
    private(set) var selectionMode: ComposerModelSelectionMode = .followDefault
    /// Only meaningful when `selectionMode == .explicit`.
    private(set) var explicitModel: UnifiedModel?
    /// Effective display model: the explicit pick, or the Runtime default while
    /// following it. Never use this in the wire payload directly.
    var selectedModel: UnifiedModel? {
        switch selectionMode {
        case .followDefault:
            return modelSettings.runtimeDefaultModel
        case .explicit:
            return explicitModel
        }
    }
    var isSending = false
    var isTurnRunning = false
    var isEnabled: Bool
    
    // Context window
    var contextSnapshot: ConversationContextSnapshot?
    var isContextLoading = false
    var contextError: String?
    var isContextPresented = false

    /// True when the session had no local state at restore time. Used by
    /// `refreshContext()` to adopt the context snapshot's model as the initial
    /// explicit selection for externally-created sessions. Cleared after the
    /// first successful adoption or when the user manually selects a model.
    private var hadNoLocalState = false
    
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
    /// 草稿代次（WorkspaceStore.draftNavigationRevision）。草稿模式下 viewModel 为 nil，
    /// `.task(id:)` 靠它区分「新一次草稿」—— 否则取消草稿再新建时 id 恒为 nil，
    /// selectedModel 残留上一次的选择。活跃会话场景不需要传。
    private var draftRevision: Int = 0
    
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

    var modelSelection: ComposerModelSelection {
        switch selectionMode {
        case .followDefault:
            return .followDefault
        case .explicit:
            guard let explicitModel, !explicitModel.model.isEmpty else { return .followDefault }
            return .explicit(explicitModel)
        }
    }

    var modelButtonTitle: String {
        switch selectionMode {
        case .followDefault:
            return runtimeDefaultTitle
        case .explicit:
            return modelSettings.selectionDisplayName(for: explicitModel?.model ?? "")
        }
    }

    var runtimeDefaultTitle: String {
        let defaultID = modelSettings.runtimeDefaultModelID
        guard !defaultID.isEmpty else {
            return AgentKitLocalized.string("composer.model_follow_default")
        }
        return String(
            format: AgentKitLocalized.string("composer.model_follow_default_format"),
            modelSettings.selectionDisplayName(for: defaultID)
        )
    }

    var showsRuntimeDefaultEntry: Bool {
        !modelSettings.runtimeDefaultModelID.isEmpty
    }

    func isExplicitModelSelected(_ modelID: String) -> Bool {
        selectionMode == .explicit && explicitModel?.model == modelID
    }
    
    // MARK: - Init
    
    init(
        workspaceStore: WorkspaceStore,
        modelSettings: ModelSettingsStore,
        conversationViewModel: ConversationViewModel?,
        isDraft: Bool,
        isEnabled: Bool,
        isTurnRunning: Bool = false,
        draftRevision: Int = 0,
        onSend: @escaping (_ text: String, _ model: UnifiedModel?, _ assets: [UserAssetRef]) async -> Bool,
        onModelChange: ((String) -> Void)? = nil,
        onAddAttachment: (() -> Void)? = nil,
        onStop: (() -> Void)? = nil
    ) {
        self.workspaceStore = workspaceStore
        self.modelSettings = modelSettings
        self.conversationViewModel = conversationViewModel
        self.isDraft = isDraft
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
        // If events are already loaded (view re-appears after disconnect),
        // adopt the resolved model immediately without waiting for onChange.
        adoptResolvedModelIfNeeded(resolvedModel: conversationViewModel?.modelIdentity.resolvedModel)
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

    /// User explicitly chose a model. This is the only path that turns a value
    /// into an explicit next-send intent.
    func selectModel(_ modelID: String, reasoningEffort: ModelReasoningEffort?) {
        guard !modelID.isEmpty else { return }
        hadNoLocalState = false
        let model = UnifiedModel(model: modelID, reasoningEffort: reasoningEffort)
        applySelection(.explicit(model))

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

    /// User chose to let the Runtime resolve its configured default. Persist the
    /// intent and remove any explicit model/reasoning leftover.
    func selectRuntimeDefault() {
        applySelection(.followDefault)
        persistSelection(.followDefault)
        if let defaultModel = modelSettings.runtimeDefaultModel {
            conversationViewModel?.selectedModel = defaultModel
        }
    }

    private func applySelection(_ selection: ComposerModelSelection) {
        selectionMode = selection.mode
        explicitModel = selection.mode == .explicit ? selection.model : nil
        conversationViewModel?.applyComposerSelection(selection)
        if let model = selection.model {
            conversationViewModel?.selectedModel = model
        } else if let defaultModel = modelSettings.runtimeDefaultModel {
            conversationViewModel?.selectedModel = defaultModel
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
        
        guard canSend else { return }
        let selection = modelSelection

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
            let accepted = await onSend(toSend, selection.model, sendingAssets)
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
    
    /// Adopts the resolved model from the event stream when a session has no
    /// local state (e.g., externally created by an agent). Called when
    /// `modelIdentity.resolvedModel` changes. Only fires once per session open.
    func adoptResolvedModelIfNeeded(resolvedModel: String?) {
        guard hadNoLocalState,
              selectionMode == .followDefault,
              let modelID = resolvedModel, !modelID.isEmpty else { return }
        hadNoLocalState = false
        selectModel(modelID, reasoningEffort: nil)
    }

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
                    // Externally-created sessions have no local state. Adopt the
                    // model the Runtime actually used as the initial explicit
                    // selection so the composer reflects reality on first open.
                    if self.hadNoLocalState,
                       self.selectionMode == .followDefault,
                       !snapshot.model.name.isEmpty {
                        self.hadNoLocalState = false
                        self.selectModel(
                            snapshot.model.name,
                            reasoningEffort: snapshot.model.reasoningEffort
                        )
                    }
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
        hadNoLocalState = (state == nil)
        text = state?.composerDraft.text ?? ""
        attachments = state.map { visibleAttachments(from: $0) } ?? []
        submittedTextSnapshot = state?.composerDraft.pendingSubmission?.text

        let selection = modelSettings.composerSelection(
            selectedModelID: state?.selectedModelID,
            storedMode: state?.modelSelectionMode,
            storedVersion: state?.composerSelectionVersion,
            reasoningEffort: state?.reasoningEffort
        )
        applySelection(selection)

        // Legacy and unversioned state has no durable provenance. Migrate it
        // once so a stale automatic value cannot keep routing turns.
        if key != nil,
           state?.composerSelectionVersion != ConversationLocalState.currentComposerSelectionVersion {
            persistSelection(selection)
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
            state.modelSelectionMode = .explicit
            state.composerSelectionVersion = ConversationLocalState.currentComposerSelectionVersion
            state.selectedModelID = modelID
            state.reasoningEffort = reasoningEffort?.rawValue
            state.recentModelIDs.removeAll { $0 == modelID }
            state.recentModelIDs.insert(modelID, at: 0)
            if state.recentModelIDs.count > 8 {
                state.recentModelIDs.removeLast(state.recentModelIDs.count - 8)
            }
        }
    }

    private func persistSelection(_ selection: ComposerModelSelection) {
        guard let key = loadedStateKey else { return }
        try? workspaceStore.localStateStore.updateState(for: key) { state in
            state.modelSelectionMode = selection.mode
            state.composerSelectionVersion = ConversationLocalState.currentComposerSelectionVersion
            switch selection.mode {
            case .followDefault:
                state.selectedModelID = nil
                state.reasoningEffort = nil
            case .explicit:
                state.selectedModelID = selection.model?.model
                state.reasoningEffort = selection.model?.reasoningEffort?.rawValue
            }
        }
    }

    // MARK: - Model Settings Change Handling

    func handleModelSettingsChange(newIDs: [String]) {
        guard let key = loadedStateKey,
              let state = try? workspaceStore.localStateStore.state(for: key),
              state.composerSelectionVersion != ConversationLocalState.currentComposerSelectionVersion else { return }
        let selection = modelSettings.composerSelection(
            selectedModelID: state.selectedModelID,
            storedMode: state.modelSelectionMode,
            storedVersion: state.composerSelectionVersion,
            reasoningEffort: state.reasoningEffort
        )
        applySelection(selection)
        persistSelection(selection)
    }
    
    // MARK: - Turn Running
    
    func setTurnRunning(_ running: Bool) {
        isTurnRunning = running
        if !running {
            refreshContext()
        }
    }
    
    // MARK: - Constants
    
    var maxFilesCount: Int { 15 }
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

