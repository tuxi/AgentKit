//
//  UserAssetDraftCoordinator.swift
//  AgentKit
//
//  Platform-neutral persisted attachment state machine. The host supplies upload IO.
//

import Foundation

public actor UserAssetDraftCoordinator {
    private let store: any ConversationLocalStateStore
    private let uploader: any UserAssetUploading

    public init(
        store: any ConversationLocalStateStore,
        uploader: any UserAssetUploading
    ) {
        self.store = store
        self.uploader = uploader
    }

    public func add(
        id: String = UUID().uuidString,
        displayName: String,
        resourceURI: String,
        to key: ConversationLocalStateKey
    ) throws {
        try store.updateState(for: key) { state in
            guard state.composerDraft.attachments.count < 4 else { return }
            state.composerDraft.attachments.append(DraftAttachmentReference(
                id: id,
                displayName: displayName,
                resourceURI: resourceURI
            ))
            state.composerDraft.revision += 1
        }
    }

    public func remove(id: String, from key: ConversationLocalStateKey) throws {
        try store.updateState(for: key) { state in
            state.composerDraft.attachments.removeAll { $0.id == id }
            state.composerDraft.revision += 1
        }
    }

    public func upload(
        id: String,
        in key: ConversationLocalStateKey,
        onStateChange: @escaping @MainActor @Sendable () -> Void = {}
    ) async throws {
        guard var attachment = try store.state(for: key)?.composerDraft.attachments
            .first(where: { $0.id == id }) else { return }

        attachment.state = .preparing
        attachment.progress = nil
        attachment.failure = nil
        try replace(attachment, in: key)
        await onStateChange()

        attachment.state = .uploading
        attachment.progress = 0
        try replace(attachment, in: key)
        await onStateChange()

        do {
            let uploaded = try await uploader.upload(attachment: attachment) { [weak self] progress in
                Task {
                    await self?.recordProgress(
                        progress,
                        id: id,
                        key: key,
                        onStateChange: onStateChange
                    )
                }
            }
            try uploaded.validate()
            attachment.state = .ready
            attachment.progress = nil
            attachment.readyAsset = uploaded
            attachment.failure = nil
            try replace(attachment, in: key)
            await onStateChange()
        } catch {
            attachment.state = .failed
            attachment.progress = nil
            attachment.failure = DraftAttachmentFailure(
                message: error.localizedDescription,
                retryable: true
            )
            try replace(attachment, in: key)
            await onStateChange()
            throw error
        }
    }

    /// Revalidates all ready references after restoration and returns them in draft order.
    public func readyAssets(for key: ConversationLocalStateKey) async throws -> [UserAssetRef] {
        let attachments = try store.state(for: key)?.composerDraft.attachments ?? []
        guard attachments.count <= 4,
              attachments.allSatisfy({ $0.state == .ready && $0.readyAsset != nil }) else {
            throw AgentInputRejection(
                code: "asset_not_ready",
                message: "所有图片上传完成后才能发送"
            )
        }

        var result: [UserAssetRef] = []
        for attachment in attachments {
            guard let ready = attachment.readyAsset else { continue }
            let validated = try await uploader.revalidate(ready)
            try validated.validate()
            result.append(validated)
            var updated = attachment
            updated.readyAsset = validated
            try replace(updated, in: key)
        }
        return result
    }

    private func recordProgress(
        _ progress: Double,
        id: String,
        key: ConversationLocalStateKey,
        onStateChange: @escaping @MainActor @Sendable () -> Void
    ) {
        try? store.updateState(for: key) { state in
            guard let index = state.composerDraft.attachments.firstIndex(where: { $0.id == id }),
                  state.composerDraft.attachments[index].state == .uploading else { return }
            state.composerDraft.attachments[index].progress = min(max(progress, 0), 1)
        }
        Task { @MainActor in onStateChange() }
    }

    private func replace(_ attachment: DraftAttachmentReference, in key: ConversationLocalStateKey) throws {
        try store.updateState(for: key) { state in
            guard let index = state.composerDraft.attachments.firstIndex(where: { $0.id == attachment.id }) else {
                return
            }
            state.composerDraft.attachments[index] = attachment
            state.composerDraft.revision += 1
        }
    }
}

extension ConversationLocalStateStore {
    func markSubmissionPending(
        key: ConversationLocalStateKey,
        input: AgentInput
    ) throws -> ComposerSubmissionSnapshot {
        let current = try state(for: key)?.composerDraft ?? ComposerDraft()
        let snapshot = ComposerSubmissionSnapshot(
            requestID: input.requestID ?? "",
            revision: current.revision,
            text: input.text ?? "",
            attachmentIDs: current.attachments.compactMap { attachment in
                guard let readyAsset = attachment.readyAsset,
                      input.assets.contains(where: { $0.assetID == readyAsset.assetID }) else {
                    return nil
                }
                return attachment.id
            },
            model: input.model,
            assets: input.assets
        )
        try updateState(for: key) { state in
            state.composerDraft.pendingSubmission = snapshot
            for index in state.composerDraft.attachments.indices
                where snapshot.attachmentIDs.contains(state.composerDraft.attachments[index].id) {
                if state.composerDraft.attachments[index].state == .ready {
                    state.composerDraft.attachments[index].state = .sending
                }
            }
        }
        return snapshot
    }

    func acceptSubmission(key: ConversationLocalStateKey, requestID: String) throws {
        try updateState(for: key) { state in
            guard let snapshot = state.composerDraft.pendingSubmission,
                  snapshot.requestID == requestID else { return }

            if state.composerDraft.text == snapshot.text {
                state.composerDraft.text = ""
            } else if !snapshot.text.isEmpty,
                      state.composerDraft.text.hasPrefix(snapshot.text) {
                state.composerDraft.text.removeFirst(snapshot.text.count)
                state.composerDraft.text = state.composerDraft.text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let acceptedIDs = Set(snapshot.attachmentIDs)
            state.composerDraft.attachments.removeAll { acceptedIDs.contains($0.id) }
            state.composerDraft.pendingSubmission = nil
            state.composerDraft.revision += 1
        }
    }

    func rejectSubmission(key: ConversationLocalStateKey, requestID: String?) throws {
        try updateState(for: key) { state in
            guard let snapshot = state.composerDraft.pendingSubmission,
                  requestID == nil || snapshot.requestID == requestID else { return }
            let rejectedIDs = Set(snapshot.attachmentIDs)
            for index in state.composerDraft.attachments.indices
                where rejectedIDs.contains(state.composerDraft.attachments[index].id) {
                if state.composerDraft.attachments[index].readyAsset != nil {
                    state.composerDraft.attachments[index].state = .ready
                    state.composerDraft.attachments[index].progress = nil
                    state.composerDraft.attachments[index].failure = nil
                }
            }
            state.composerDraft.pendingSubmission = nil
            state.composerDraft.revision += 1
        }
    }
}
