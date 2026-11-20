//
//  DraftComposerPanelViewModel.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/9/19.
//

import Foundation
import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

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
    var tokens: [ComposerToken] = []
    var fileReferences: [ComposerFileReference] = []
    var attachmentIssue: String?
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
    private(set) var hasPendingSubmission = false
    private var hasDetachedSubmission = false
    private var submissionGeneration: UInt64 = 0
    var isSending = false
#if os(macOS)
    var inTurnDeliveryNotice: String?
#endif

    var isTurnRunning = false
    var isEnabled: Bool
    
    // Context window
    var contextSnapshot: ConversationContextSnapshot?
    var isContextCompacting = false
    var contextCompactionMessage: String?
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
    weak var composerUndoManager: UndoManager?
    var composerHeight: CGFloat = 24
    private let composerMinHeight: CGFloat = 24
    private let composerMaxHeight: CGFloat = 336
#endif
    
    // Computed
    var sessionID: String? {
        conversationViewModel?.conversation?.id ?? workspaceStore.selectedConversation?.id
    }
    
    var persistenceKey: ConversationLocalStateKey? {
        if isDraft, let id = workspaceStore.draft?.id {
#if os(macOS)
            return workspaceStore.draftSubmissionKey ?? .draft(id)
#else
            return .draft(id)
#endif
        }
        if let id = conversationViewModel?.conversation?.id ?? workspaceStore.selectedConversation?.id {
            return .session(id)
        }
        return nil
    }
    
    var isSubmitting: Bool {
#if os(macOS)
        isSending || hasPendingSubmission
#else
        isSending
#endif
    }

    var canSend: Bool {
        let hasContent = !trimmed.isEmpty || !attachments.isEmpty || !fileReferences.isEmpty
        let attachmentsReady = imagesAsPaths || attachments.allSatisfy { attachment in
            if attachment.delivery == .localOnly {
                return attachment.state == .local
                || attachment.state == .ready
                || (isDraft && attachment.state == .failed && attachment.localAsset == nil)
            }
            return attachment.state == .ready
        }
        return isEnabled && hasContent && attachmentsReady && !isSubmitting
        && textWithinLimit && attachmentIssue == nil && imageInputIssue == nil && referenceLimitIssue == nil
        && !isTurnRunning && !isContextCompacting && !workspaceStore.sessionRail.isCompacting(sessionID) && modelSettings.isModelAvailable(selectedModel?.model)
    }
    
    private var textWithinLimit: Bool {
#if os(macOS)
        trimmed.count <= 100_000
#else
        true
#endif
    }

    var referenceLimitIssue: String? {
#if os(macOS)
        let count = attachments.count + fileReferences.count + tokens.filter { ["file", "directory", "conversation"].contains($0.item.kind) }.count
        if count > 16 { return "附件与引用合计最多 16 个，请移除多余项目。" }
#endif
        return nil
    }

    var imagesAsPaths: Bool {
#if os(macOS)
        guard let id = selectedModel?.model, let model = modelSettings.descriptor(for: id) else { return false }
        return !model.inputModalities.contains(.image)
#else
        return false
#endif
    }

    var submissionFileReferences: [ComposerFileReference] {
        ComposerMessageContent.referenceFiles(files: fileReferences, attachments: attachments, imagesAsPaths: imagesAsPaths)
    }

    var imageInputIssue: String? {
        if imagesAsPaths, submissionFileReferences.count != fileReferences.count + attachments.count {
            return "无法取得图片的本地路径，请重新添加该图片。"
        }
        return nil
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

    /// Freeze the displayed effective model for this request. Following the
    /// catalog default remains a preference, not an omitted transport value.
    var submissionModel: UnifiedModel? {
        guard let selected = selectedModel else { return nil }
        let alias = modelSettings.getWireModelID(for: selected.model)
            ?? modelSettings.runtimeAlias(for: selected.model) ?? selected.model
        return UnifiedModel(model: alias, reasoningEffort: modelSettings.validatedReasoningEffort(selected.reasoningEffort, for: selected.model))
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
#if os(macOS)
        composerUndoManager?.removeAllActions(withTarget: self)
#endif
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
        let effort = modelSettings.validatedReasoningEffort(reasoningEffort ?? modelSettings.rememberedReasoningEffort(for: modelID), for: modelID)
        let model = UnifiedModel(model: modelID, reasoningEffort: effort)
        applySelection(.explicit(model))

        modelSettings.didUseModel(
            modelID,
            reasoningEffort: effort,
            conversation: conversationViewModel?.conversation?.id ?? ""
        )
        persistModel(modelID, reasoningEffort: effort)
        if let wireModel = modelSettings.getWireModelID(for: modelID) {
            onModelChange?(wireModel)
        }
    }

    /// Follow the catalog default while keeping the preference unpinned. The
    /// effective model is frozen only when a request is submitted.
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
        if isCurrentModel(modelID), let override = selectedModel?.reasoningEffort,
           let valid = modelSettings.validatedReasoningEffort(override, for: modelID) { return valid }
        if isCurrentModel(modelID), let override = storedReasoningEffortOverride,
           let valid = modelSettings.validatedReasoningEffort(override, for: modelID) { return valid }
        return modelSettings.descriptor(for: modelID)?.reasoningEffort
    }

    func isCurrentModel(_ modelID: String) -> Bool {
        guard let selected = selectedModel?.model else { return false }
        return (modelSettings.descriptor(for: selected)?.id ?? selected)
            == (modelSettings.descriptor(for: modelID)?.id ?? modelID)
    }

    func resetReasoningEffort(for modelID: String) {
        modelSettings.clearRememberedReasoningEffort(for: modelID)
        selectModel(modelID, reasoningEffort: nil)
    }

    private func selectionForEditor(state: ConversationLocalState?) -> ComposerModelSelection {
        let stored = modelSettings.composerSelection(selectedModelID: state?.selectedModelID,
            storedMode: state?.modelSelectionMode, storedVersion: state?.composerSelectionVersion,
            reasoningEffort: state?.reasoningEffort)
        guard isDraft, state?.composerDraft.pendingSubmission == nil else { return stored }
        guard modelSettings.hasResolvedModelCatalog else { return stored }
        let hasContent = !(state?.composerDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || !(state?.composerDraft.attachments.isEmpty ?? true)
            || !(state?.composerDraft.fileReferences.isEmpty ?? true)
            || !(state?.composerDraft.tokens.isEmpty ?? true)
        if stored.mode == .explicit, let id = stored.model?.model, modelSettings.isModelAvailable(id),
           hasContent || modelSettings.lastSelectedModel == nil { return stored }
        if let recent = modelSettings.lastSelectedModel, modelSettings.isModelAvailable(recent.model),
           let model = modelSettings.modelForNewConversation { return .explicit(model) }
        return .followDefault
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
#if os(macOS)
        if hasUnconfirmedDelivery(matching: trimmed) {
            inTurnDeliveryNotice = "这段消息仍待确认，请先查询原请求。"
            return
        }
#endif
        let modelForSubmission = submissionModel

#if os(macOS)
        let submittedRawText = text
#else
        let submittedRawText = trimmed
#endif
        let submittedDraftText = trimmed
#if os(macOS)
        var toSend = submittedDraftText
#else
        let toSend = String(submittedDraftText.prefix(100000))
#endif
#if os(macOS)
        let contexts = tokens.compactMap(\.item.contextText)
        guard contexts.count <= 3 else { attachmentIssue = "最多引用 3 个对话，请移除多余引用。"; return }
        toSend = ComposerMessageContent.modelText(text: submittedDraftText, files: submissionFileReferences, tokens: tokens)
        guard toSend.count <= 100_000 else { attachmentIssue = "正文与引用内容合计超过 100,000 字符，请缩短后发送。"; return }
#endif
        submittedTextSnapshot = submittedRawText
        
        let sendingAssets = imagesAsPaths ? [] : readyAssets
#if os(iOS)
        text = ""
        attachments = []
        if let key = loadedStateKey { persist(text: "", for: key) }
#else
        persistCurrentText()
#endif
        isSending = true
        submissionGeneration &+= 1
        let generation = submissionGeneration
        Task {
            let accepted = await onSend(toSend, modelForSubmission, sendingAssets)
            guard generation == submissionGeneration else { return }
            if !accepted {
                restoreSubmittedText(submittedRawText)
                refreshAttachmentsFromLocalState()
            }
#if os(macOS)
            if accepted, let key = persistenceKey {
                hasPendingSubmission = (try? workspaceStore.localStateStore.state(for: key))?.composerDraft.pendingSubmission != nil || conversationViewModel?.isLocallyQueued == true
            }
#endif
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
    
#if os(macOS)
    func applyTakenBackQueueDraft(serverID: String?) {
        guard !isSubmitting, let key = loadedStateKey, key == persistenceKey,
              let record = pendingQueueTakeBack, record.confirmed, record.serverID == serverID else { return }
        let merged = text.isEmpty ? record.text : text + "\n\n" + record.text
        let tokenSnapshot = tokens
        let fileSnapshot = fileReferences
        do {
            try workspaceStore.localStateStore.updateState(for: key) { state in
                guard state.pendingUserQueueTakeBack == record else { return }
                state.composerDraft.text = merged
                state.composerDraft.tokens = tokenSnapshot
                state.composerDraft.fileReferences = fileSnapshot
                state.pendingUserQueueTakeBack = nil
            }
            pendingSaveTask?.cancel()
            text = merged
            inTurnDeliveryNotice = "已取回草稿"
            workspaceStore.queueTakeBackRevision &+= 1
        } catch {
            inTurnDeliveryNotice = "取回已确认，暂时无法保存草稿。"
        }
    }

    func rebindLocalSubmissionKey() {
        guard isDraft, let key = persistenceKey, key != loadedStateKey else { return }
        pendingSaveTask?.cancel()
        loadedStateKey = key
        // The store has already migrated the detached draft. SwiftUI may
        // deliver the key change before the submission revision change.
        if submittedTextSnapshot != nil {
            reconcileLocalSubmission()
        } else {
            persistCurrentText()
        }
    }

    func reconcileLocalSubmission() {
        guard let submittedTextSnapshot else { return }
        hasDetachedSubmission = true
        loadedStateKey = persistenceKey
        if text == submittedTextSnapshot { text = ""; tokens = [] }
        self.submittedTextSnapshot = nil
        refreshAttachmentsFromLocalState()
        if let key = loadedStateKey, let state = try? workspaceStore.localStateStore.state(for: key) {
            fileReferences = state.composerDraft.fileReferences
        } else { fileReferences = [] }
        persistCurrentText()
    }
#endif

    func reconcileAcceptedSubmission() {
        hasPendingSubmission = false
        pendingSaveTask?.cancel()
#if os(macOS)
        reconcileAcceptedDraft()
#else
        DispatchQueue.main.async { [weak self] in self?.reconcileAcceptedDraft() }
#endif
    }

    private func reconcileAcceptedDraft() {
        if hasDetachedSubmission {
            hasDetachedSubmission = false
            // Flush the editor's latest value before a delayed autosave can be
            // cancelled. Runtime acknowledgement owns no part of this draft.
            persistCurrentText()
            return
        }
        // Compare the exact editor snapshot before accepting the next draft;
        // wire normalization must not determine whether the editor is cleared.
        if let submittedTextSnapshot, !submittedTextSnapshot.isEmpty {
            if text == submittedTextSnapshot {
                text = ""
                tokens = []
            }
#if os(iOS)
            if !text.isEmpty && text.hasPrefix(submittedTextSnapshot) {
                text.removeFirst(submittedTextSnapshot.count)
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
#endif
            self.submittedTextSnapshot = nil
            if let key = loadedStateKey,
               let state = try? workspaceStore.localStateStore.state(for: key) {
                fileReferences = state.composerDraft.fileReferences
            }
            refreshAttachmentsFromLocalState()
            persistCurrentText()
        } else {
            restoreLocalState(persistOutgoingText: false)
        }
    }

    func handleSubmissionRejected() {
        hasPendingSubmission = false
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
#if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        handleDroppedImages(panel.urls)
#else
        guard let key = persistenceKey else { return }
        Task {
            await workspaceStore.selectUserAssets(
                for: key,
                remainingSlots: maxFilesCount - attachments.count
            ) { [weak self] in
                self?.refreshAttachmentsFromLocalState()
            }
        }
#endif
    }
    
    func handleDroppedImages(_ urls: [URL]) {
        var imageURLs = urls
#if os(macOS)
        attachmentIssue = nil
        guard !isSubmitting else { return }
        let workspacePath = isDraft ? workspaceStore.draft?.workspace?.url.path : conversationViewModel?.conversation?.workspacePath
        imageURLs = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
            let isImage = values?.contentType?.conforms(to: .image) == true
                || UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
            if values?.isDirectory != true && isImage { imageURLs.append(url); continue }
            guard attachments.count + fileReferences.count < 16 else { attachmentIssue = "最多添加 16 个附件或文件引用"; break }
            if !fileReferences.contains(where: { $0.path == url.path }) {
                fileReferences.append(ComposerFileReference(path: url.path, workspacePath: workspacePath, isDirectory: values?.isDirectory == true))
            }
        }
        persistCurrentText()
        let currentImages = attachments.count
        if currentImages + imageURLs.count > 4 {
            attachmentIssue = "最多添加 4 张图片，请移除多余项目后重试"
            imageURLs = Array(imageURLs.prefix(max(0, 4 - currentImages)))
        }
#endif
        guard !imageURLs.isEmpty else { return }
        guard let key = persistenceKey,
              workspaceStore.canStageLocalUserAssets else { return }
        let remainingSlots = maxFilesCount - attachments.count
        guard remainingSlots > 0 else { return }
        Task {
            await workspaceStore.addDroppedFiles(
                imageURLs,
                for: key,
                maxFilesCount: maxFilesCount
            ) { [weak self] in
                self?.refreshAttachmentsFromLocalState()
            }
        }
    }
    
#if os(macOS)
    func importPastedImage(_ data: Data) {
        guard !isSubmitting, attachments.count < 4, let key = persistenceKey else { return }
        Task {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("composer-" + UUID().uuidString + ".png")
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                try await Task.detached(priority: .userInitiated) { try data.write(to: url, options: .atomic) }.value
                await workspaceStore.addDroppedFiles([url], for: key, maxFilesCount: 4) { [weak self] in
                    self?.refreshAttachmentsFromLocalState()
                }
            } catch { attachmentIssue = "无法读取粘贴的图片，请重试。" }
        }
    }
#endif

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
#if os(macOS)
        return false
#else
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
#endif
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

    func compactContext() {
        guard let id = sessionID, !isContextCompacting, !isTurnRunning, !isSending,
              workspaceStore.sessionRail.beginCompaction(id) else { return }
        contextRefreshTask?.cancel()
        isContextLoading = false
        isContextCompacting = true
        contextCompactionMessage = nil
        let compactionOwner = workspaceStore.sessionRail
        Task { [weak self] in
            defer { compactionOwner.endCompaction(id) }
            guard let self else { return }
            defer { self.isContextCompacting = false }
            do {
                let result = try await self.workspaceStore.client.compactConversationContext(id: id)
                guard self.sessionID == id else { return }
                self.contextSnapshot = result.snapshot
                self.contextError = nil
                self.contextCompactionMessage = AgentKitLocalized.string(
                    result.status == "no_change" ? "context_window.no_change" : "context_window.pending_measurement"
                )
            } catch {
                guard self.sessionID == id else { return }
                self.contextCompactionMessage = error.localizedDescription
            }
        }
    }

    func refreshContext() {
        guard !isContextCompacting else { return }
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
        if loadedStateKey != key {
            submissionGeneration &+= 1
            isSending = false
            submittedTextSnapshot = nil
            hasDetachedSubmission = false
        }
        loadedStateKey = key
        isRestoringLocalState = true
        defer { isRestoringLocalState = false }
        
#if os(macOS)
        if let key, let existing = try? workspaceStore.localStateStore.state(for: key),
           existing.composerDraft.pendingSubmission == nil,
           existing.composerDraft.attachments.contains(where: { $0.delivery == .gateway }) {
            try? workspaceStore.localStateStore.updateState(for: key) { state in
                for index in state.composerDraft.attachments.indices where state.composerDraft.attachments[index].delivery == .gateway {
                    state.composerDraft.attachments[index].delivery = .localOnly
                    state.composerDraft.attachments[index].readyAsset = nil
                    state.composerDraft.attachments[index].localAsset = nil
                    state.composerDraft.attachments[index].state = .local
                    state.composerDraft.attachments[index].progress = nil
                }
            }
        }
#endif
        let state = key.flatMap { try? workspaceStore.localStateStore.state(for: $0) }
        hasPendingSubmission = state?.composerDraft.pendingSubmission != nil
        hadNoLocalState = (state == nil)
        text = state?.composerDraft.text ?? ""
        tokens = state?.composerDraft.tokens ?? []
        fileReferences = state?.composerDraft.fileReferences ?? []
        attachments = state.map { visibleAttachments(from: $0) } ?? []
        submittedTextSnapshot = state?.composerDraft.pendingSubmission?.draftText ?? state?.composerDraft.pendingSubmission?.text

        let selection = selectionForEditor(state: state)
        applySelection(selection)

        // Legacy and unversioned state has no durable provenance. Migrate it
        // once so a stale automatic value cannot keep routing turns.
        if key != nil,
           isDraft || state?.composerSelectionVersion != ConversationLocalState.currentComposerSelectionVersion {
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
#if os(macOS)
        let key = isDraft && key.draftID != nil ? (workspaceStore.draftSubmissionKey ?? key) : key
#endif
        let tokenSnapshot = tokens
        let fileSnapshot = fileReferences
        let pathDelivery = imagesAsPaths
        try? workspaceStore.localStateStore.updateState(for: key) { state in
            state.composerDraft.imagesAsPaths = pathDelivery
            state.composerDraft.text = text
            state.composerDraft.tokens = tokenSnapshot
            state.composerDraft.fileReferences = fileSnapshot
        }
    }
    
    func persistCurrentDraft() {
        pendingSaveTask?.cancel()
        guard let key = loadedStateKey else { return }
        let textSnapshot = text
        let attachmentSnapshot = attachments
        let tokenSnapshot = tokens
        let fileSnapshot = fileReferences
        let pathDelivery = imagesAsPaths
        try? workspaceStore.localStateStore.updateState(for: key) { state in
            state.composerDraft.imagesAsPaths = pathDelivery
            state.composerDraft.tokens = tokenSnapshot
            state.composerDraft.fileReferences = fileSnapshot
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
              state.composerDraft.pendingSubmission == nil else { return }
        guard isDraft || state.composerSelectionVersion != ConversationLocalState.currentComposerSelectionVersion else { return }
        let selection = selectionForEditor(state: state)
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
    
    var maxFilesCount: Int {
#if os(macOS)
        16
#else
        15
#endif
    }
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

