#if os(macOS)
import Foundation

extension WorkspaceStore {
    func localSubmissions(for key: ConversationLocalStateKey) -> [LocalMessageSubmission] {
        _ = localSubmissionRevision
        if case .session(let id) = key, let vm = supervisor.controller(sessionID: id) {
            _ = vm.localSubmissions
        }
        return (try? localStateStore.state(for: key))?.localSubmissions ?? []
    }

    /// Commit the immutable UI snapshot before any await; resources live outside
    /// the editor and outside the resumable new-conversation draft namespace.
    func beginLocalSubmission(key: ConversationLocalStateKey, text: String, model: String?,
                              effort: ModelReasoningEffort?) throws -> LocalMessageSubmission {
        if case .draft = key { draftSubmissionKey = key }
        let state = try localStateStore.state(for: key) ?? ConversationLocalState()
        let draft = state.composerDraft
        let refs = ComposerMessageContent.referenceFiles(files: draft.fileReferences,
            attachments: draft.attachments, imagesAsPaths: draft.imagesAsPaths)
        let id = UUID().uuidString
        var record = LocalMessageSubmission(id: id, resourceID: id, text: text,
            displayText: draft.text.trimmingCharacters(in: .whitespacesAndNewlines),
            fileReferences: refs, model: model, reasoningEffort: effort)
        record.attachments = draft.attachments
        if draft.text.isEmpty && draft.attachments.isEmpty && draft.fileReferences.isEmpty && draft.tokens.isEmpty {
            record.displayText = text
        }
        let submitted = record
        var resources = ConversationLocalState()
        resources.composerDraft = draft
        resources.composerDraft.pendingSubmission = nil
        try localStateStore.save(resources, for: .submission(record.resourceID))
        try localStateStore.updateState(for: key) { state in
            state.localSubmissions.append(submitted)
            state.composerDraft.text = ""
            state.composerDraft.attachments = []
            state.composerDraft.fileReferences = []
            state.composerDraft.tokens = []
            state.composerDraft.revision += 1
        }
        localSubmissionRevision &+= 1
        return record
    }

    func prepareLocalSubmission(_ original: LocalMessageSubmission, key: ConversationLocalStateKey,
                                session: ConversationRef, sourceRoot: String) async throws -> LocalMessageSubmission {
        if original.prepared { return original }
        let resourceKey = ConversationLocalStateKey.submission(original.resourceID)
        try await prepareComposerReferences(for: resourceKey, sessionID: session.id,
            sourceRoot: sourceRoot, finalRoot: session.workspacePath)
        let payload = try await prepareUserAssets(for: resourceKey,
            workspaceRoot: URL(fileURLWithPath: session.workspacePath, isDirectory: true))
        var record = original
        record.assets = payload.assets
        record.localAssets = payload.localAssets
        record.prepared = true
        record.phase = .sending
        let ready = record
        try localStateStore.updateLocalSubmission(key: key, id: record.id) { $0 = ready }
        localSubmissionRevision &+= 1
        return record
    }

    func failLocalSubmission(key: ConversationLocalStateKey, id: String, error: Error) {
        let message = (error as? AgentInputRejection)?.message ?? error.localizedDescription
        try? localStateStore.updateLocalSubmission(key: key, id: id) {
            $0.phase = .failed; $0.failure = message
        }
        localSubmissionRevision &+= 1
    }

    func submitLocalMessage(_ original: LocalMessageSubmission, key: ConversationLocalStateKey,
                            through vm: ConversationViewModel) async -> Bool {
        guard let session = vm.conversation else { return false }
        guard !localSubmissionTasks.contains(original.id) else { return true }
        localSubmissionTasks.insert(original.id)
        defer { localSubmissionTasks.remove(original.id); vm.reloadLocalSubmissions() }
        do {
            try localStateStore.updateLocalSubmission(key: key, id: original.id) {
                $0.failure = nil; $0.phase = $0.prepared ? .sending : .preparing
            }
            vm.reloadLocalSubmissions()
            let ready = try await prepareLocalSubmission(original, key: key, session: session, sourceRoot: session.workspacePath)
            vm.reloadLocalSubmissions()
            guard await vm.send(input: ready.input) else { throw AgentInputRejection(code: "request_failed", message: "任务未能提交，请重试") }
            return true
        } catch {
            failLocalSubmission(key: key, id: original.id, error: error)
            // The content now belongs to the visible submission, not the editor.
            return true
        }
    }

    func retryLocalSubmission(key: ConversationLocalStateKey, id: String) async {
        guard var record = localSubmissions(for: key).first(where: { $0.id == id }), record.phase == .failed else { return }
        guard !localSubmissionTasks.contains(id) else { return }
        // A known terminal turn cannot be restarted by replaying its old key.
        // An uncertain/unaccepted request keeps its original idempotency key.
        if record.turnID != nil {
            record.id = UUID().uuidString
            record.turnID = nil
            let retry = record
            do { try localStateStore.updateLocalSubmission(key: key, id: id) { $0 = retry } }
            catch { return }
            localSubmissionRevision &+= 1
        }
        switch key {
        case .session(let sessionID):
            guard let vm = supervisor.controller(sessionID: sessionID), !vm.isTurnActive else { return }
            if !vm.isConnected, let ref = vm.conversation { await vm.connect(to: ref, restoringLocalSubmissions: false) }
            _ = await submitLocalMessage(record, key: key, through: vm)
        case .draft(let draftID):
            guard draft?.id == draftID else { return }
            await commitDraft(firstMessage: record.text,
                model: record.model.map { UnifiedModel(model: $0, reasoningEffort: record.reasoningEffort) },
                localSubmissionID: record.id)
        case .submission: break
        }
    }
}
#endif
