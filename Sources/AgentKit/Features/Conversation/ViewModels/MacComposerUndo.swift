#if os(macOS)
import Foundation

extension DraftComposerPanelViewModel {
    private func canApplyComposerUndo(for key: ConversationLocalStateKey) -> Bool {
        guard !isSubmitting, loadedStateKey == key else { return false }
        switch key {
        case .draft(let id): return workspaceStore.draft?.id == id
        case .session(let id): return workspaceStore.selectedConversation?.id == id
        case .submission: return false
        }
    }

    func removeAttachmentWithUndo(_ id: String, manager: UndoManager?) {
        guard !isSubmitting, let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        let attachment = attachments[index]
        let key = loadedStateKey
        removeAttachment(id)
        guard let key, let manager else { return }
        composerUndoManager = manager
        manager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                guard target.canApplyComposerUndo(for: key), !target.attachments.contains(where: { $0.id == id }) else { return }
                target.attachments.insert(attachment, at: min(index, target.attachments.count))
                target.persistCurrentDraft()
                manager.registerUndo(withTarget: target) { target in
                    MainActor.assumeIsolated { target.removeAttachmentWithUndo(id, manager: manager) }
                }
            }
        }
        manager.setActionName("移除附件")
    }

    func removeFileReferenceWithUndo(_ id: UUID, manager: UndoManager?) {
        guard !isSubmitting, let index = fileReferences.firstIndex(where: { $0.id == id }) else { return }
        let reference = fileReferences.remove(at: index)
        let key = loadedStateKey
        attachmentIssue = nil
        persistCurrentDraft()
        guard let key, let manager else { return }
        composerUndoManager = manager
        manager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                guard target.canApplyComposerUndo(for: key), !target.fileReferences.contains(where: { $0.id == id }) else { return }
                target.fileReferences.insert(reference, at: min(index, target.fileReferences.count))
                target.persistCurrentDraft()
                manager.registerUndo(withTarget: target) { target in
                    MainActor.assumeIsolated { target.removeFileReferenceWithUndo(id, manager: manager) }
                }
            }
        }
        manager.setActionName("移除文件引用")
    }
}
#endif
