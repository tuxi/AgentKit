//
//  UserAssetDraftCoordinator.swift
//  AgentKit
//
//  Platform-neutral persisted attachment state machine. The host supplies upload IO.
//

import Foundation

public actor UserAssetDraftCoordinator {
    private let store: any ConversationLocalStateStore
    private let stager: (any LocalUserAssetStaging)?
    private let uploader: (any UserAssetUploading)?

    public init(
        store: any ConversationLocalStateStore,
        stager: (any LocalUserAssetStaging)? = nil,
        uploader: (any UserAssetUploading)? = nil
    ) {
        self.store = store
        self.stager = stager
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
        guard let uploader else {
            throw AgentInputRejection(
                code: "gateway_upload_unavailable",
                message: "当前 Host 未提供云端视觉上传能力"
            )
        }
        guard var attachment = try store.state(for: key)?.composerDraft.attachments
            .first(where: { $0.id == id }) else { return }
        guard attachment.supportsGatewayUpload else {
            throw AgentInputRejection(
                code: "unsupported_gateway_asset",
                message: "仅 JPEG 和 PNG 图片可上传用于云端视觉识别"
            )
        }

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
            attachment.delivery = .gateway
            attachment.readyAsset = uploaded
            attachment.failure = nil
            try replace(attachment, in: key)
            await onStateChange()
        } catch {
            // Cloud upload is an optional delivery upgrade. Preserve the local
            // attachment and keep local send available after any upload failure.
            attachment.state = attachment.localAsset == nil ? .local : .ready
            attachment.progress = nil
            attachment.delivery = .localOnly
            attachment.failure = DraftAttachmentFailure(
                message: error.localizedDescription,
                retryable: true
            )
            try replace(attachment, in: key)
            await onStateChange()
            throw error
        }
    }

    /// Stages every local-only attachment into the final conversation workspace.
    /// Gateway-delivered attachments are intentionally skipped so a successful
    /// explicit upload is never duplicated in `local_assets`.
    public func stageLocalAssets(
        for key: ConversationLocalStateKey,
        workspaceRoot: URL,
        onStateChange: @escaping @MainActor @Sendable () -> Void = {}
    ) async throws -> [LocalUserAssetRef] {
        let attachments = try store.state(for: key)?.composerDraft.attachments ?? []
        guard attachments.count <= maxFilesCount else {
            throw UserAssetValidationError.tooManyAssets(attachments.count)
        }
        for attachment in attachments where attachment.delivery == .localOnly {
            if let localAsset = attachment.localAsset {
                try localAsset.validate()
                continue
            }
            try await stage(
                id: attachment.id,
                in: key,
                workspaceRoot: workspaceRoot,
                onStateChange: onStateChange
            )
        }
        return try localAssets(for: key)
    }

    public func stage(
        id: String,
        in key: ConversationLocalStateKey,
        workspaceRoot: URL,
        onStateChange: @escaping @MainActor @Sendable () -> Void = {}
    ) async throws {
        guard let stager else {
            throw AgentInputRejection(
                code: "local_asset_staging_unavailable",
                message: "当前 Host 未提供本地附件工作区导入能力"
            )
        }
        guard var attachment = try store.state(for: key)?.composerDraft.attachments
            .first(where: { $0.id == id }),
              attachment.delivery == .localOnly else { return }

        attachment.state = .preparing
        attachment.progress = nil
        attachment.failure = nil
        try replace(attachment, in: key)
        await onStateChange()

        do {
            let localAsset = try await stager.stage(
                attachment: attachment,
                workspaceRoot: workspaceRoot
            )
            try localAsset.validate()
            attachment.state = .ready
            attachment.progress = nil
            attachment.delivery = .localOnly
            attachment.localAsset = localAsset
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
        let attachments = (try store.state(for: key)?.composerDraft.attachments ?? [])
            .filter { $0.delivery == .gateway }
        guard attachments.allSatisfy({ $0.state == .ready && $0.readyAsset != nil }) else {
            throw AgentInputRejection(
                code: "asset_not_ready",
                message: "云端图片尚未准备完成"
            )
        }

        var result: [UserAssetRef] = []
        for attachment in attachments {
            guard let ready = attachment.readyAsset else { continue }
            guard let uploader else {
                throw AgentInputRejection(
                    code: "gateway_upload_unavailable",
                    message: "当前 Host 未提供云端视觉上传能力"
                )
            }
            let validated = try await uploader.revalidate(ready)
            try validated.validate()
            result.append(validated)
            var updated = attachment
            updated.readyAsset = validated
            try replace(updated, in: key)
        }
        return result
    }

    public func localAssets(for key: ConversationLocalStateKey) throws -> [LocalUserAssetRef] {
        let attachments = (try store.state(for: key)?.composerDraft.attachments ?? [])
            .filter { $0.delivery == .localOnly }
        guard attachments.allSatisfy({ $0.state == .ready && $0.localAsset != nil }) else {
            throw AgentInputRejection(
                code: "local_asset_not_ready",
                message: "本地附件尚未导入工作区"
            )
        }
        return try attachments.compactMap(\.localAsset).map { asset in
            try asset.validate()
            return asset
        }
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

private extension DraftAttachmentReference {
    var supportsGatewayUpload: Bool {
        let lowercasedName = displayName.lowercased()
        return lowercasedName.hasSuffix(".jpg")
            || lowercasedName.hasSuffix(".jpeg")
            || lowercasedName.hasSuffix(".png")
            || localAsset?.mimeType == "image/jpeg"
            || localAsset?.mimeType == "image/png"
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
                switch attachment.delivery {
                case .gateway:
                    guard let readyAsset = attachment.readyAsset,
                          input.assets.contains(where: { $0.assetID == readyAsset.assetID }) else {
                        return nil
                    }
                case .localOnly:
                    guard let localAsset = attachment.localAsset,
                          input.localAssets.contains(where: { $0.id == localAsset.id }) else {
                        return nil
                    }
                }
                return attachment.id
            },
            model: input.model,
            assets: input.assets,
            localAssets: input.localAssets
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
                if state.composerDraft.attachments[index].readyAsset != nil
                    || state.composerDraft.attachments[index].localAsset != nil {
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
