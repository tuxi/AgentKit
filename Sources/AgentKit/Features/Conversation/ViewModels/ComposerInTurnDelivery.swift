#if os(macOS)
import Foundation

extension DraftComposerPanelViewModel {
    var canDeliverPlainText: Bool {
        isEnabled && !isSubmitting && !trimmed.isEmpty && trimmed.unicodeScalars.count <= 100_000
            && attachments.isEmpty && fileReferences.isEmpty && tokens.isEmpty
    }

    func hasUnconfirmedDelivery(matching content: String) -> Bool {
        guard !isDraft, !content.isEmpty, let key = persistenceKey,
              let state = try? workspaceStore.localStateStore.state(for: key) else { return false }
        return state.pendingUserQueueRequests.contains { $0.request.text == content }
            || state.textSupplementDeliveries.contains {
                ($0.state == "unconfirmed" || $0.request.requestID == state.composerSupplementRequestID)
                    && $0.request.text == content
            }
    }

    var pendingComposerSupplementID: String? {
        guard let key = persistenceKey else { return nil }
        return (try? workspaceStore.localStateStore.state(for: key))?.composerSupplementRequestID
    }

    func sendInTurn(supplementTarget: String?, queueServerID: String?) async {
        guard let conversation = conversationViewModel, canDeliverPlainText,
              (supplementTarget != nil || queueServerID != nil) else { return }
        guard !hasUnconfirmedDelivery(matching: trimmed) else {
            inTurnDeliveryNotice = "这段消息仍待确认，请先查询原请求。"
            return
        }
        let original = text
        let content = trimmed
        guard let key = persistenceKey else { return }
        let model = submissionModel
        if supplementTarget == nil && (model?.model.isEmpty ?? true) { return }
        persistCurrentText()
        isSending = true
        defer { isSending = false }
        var supplementID: String?
        do {
            if let supplementTarget {
                let id = UUID().uuidString
                try workspaceStore.localStateStore.updateState(for: key) { $0.composerSupplementRequestID = id }
                supplementID = id
                try await conversation.submitTextSupplement(content, expectedTurnID: supplementTarget, requestID: id)
                inTurnDeliveryNotice = nil
            } else if let queueServerID, let model {
                _ = try await conversation.enqueueText(
                    .init(text: content, model: model.model, reasoningEffort: model.reasoningEffort?.rawValue),
                    serverID: queueServerID
                )
                inTurnDeliveryNotice = "已排队"
            }
            clearDeliveredDraft(original, key: key)
            if let supplementID { clearSupplementLink(supplementID, key: key) }
        } catch {
            if let supplementID {
                let record = conversation.composerSupplementDeliveries().first { $0.request.requestID == supplementID }
                if record == nil || record?.state == "rejected" { clearSupplementLink(supplementID, key: key) }
            }
            inTurnDeliveryNotice = hasUnconfirmedDelivery(matching: content)
                ? "提交状态待确认，请查询原请求。"
                : "未能提交，草稿已保留。"
        }
    }

    func recoverInTurnDelivery(queueServerID: String?) async {
        guard let conversation = conversationViewModel, !isSubmitting else { return }
        let original = text
        let content = trimmed
        let key = persistenceKey
        isSending = true
        defer { isSending = false }
        var confirmed = false
        if let queueServerID {
            for record in conversation.queuePending(serverID: queueServerID) {
                if (try? await conversation.recoverQueueRequest(record)) != nil {
                    confirmed = confirmed || record.request.text == content
                }
            }
        }
        let linkedID = pendingComposerSupplementID
        let oldSupplements = conversation.composerSupplementDeliveries().filter {
            $0.state == "unconfirmed" || $0.request.requestID == linkedID
        }
        if !oldSupplements.isEmpty {
            try? await conversation.recoverComposerSupplements()
            let current = conversation.composerSupplementDeliveries()
            confirmed = confirmed || oldSupplements.contains { old in
                old.request.text == content && current.contains {
                    $0.request.requestID == old.request.requestID && ["pending_apply", "applied"].contains($0.state)
                }
            }
        }
        if confirmed {
            clearDeliveredDraft(original, key: key)
        }
        if let linkedID, let key {
            let record = conversation.composerSupplementDeliveries().first { $0.request.requestID == linkedID }
            if record == nil || record.map({ ["pending_apply", "applied", "rejected"].contains($0.state) }) == true {
                clearSupplementLink(linkedID, key: key)
            }
        }
        inTurnDeliveryNotice = hasUnconfirmedDelivery(matching: content) ? "仍待确认，草稿已保留。" : "查询完成"
    }

    private func clearSupplementLink(_ id: String, key: ConversationLocalStateKey) {
        try? workspaceStore.localStateStore.updateState(for: key) {
            if $0.composerSupplementRequestID == id { $0.composerSupplementRequestID = nil }
        }
    }

    private func clearDeliveredDraft(_ original: String, key: ConversationLocalStateKey?) {
        guard key == persistenceKey, text == original,
              attachments.isEmpty, fileReferences.isEmpty, tokens.isEmpty else { return }
        text = ""
        persistCurrentText()
    }
}
#endif
