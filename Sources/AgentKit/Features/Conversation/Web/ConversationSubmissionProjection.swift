#if os(macOS)
import Foundation

/// Delivery UI only. A local message must never manufacture execution events.
enum ConversationSubmissionProjection {
    static func apply(to document: inout ConversationWebDocument,
                      snapshot: RuntimeSnapshot, submissions: [LocalMessageSubmission],
                      key: ConversationLocalStateKey,
                      registerAction: (ConversationWebAction) -> String) {
        let sourceIDs = Dictionary(snapshot.turns.map { ($0.runtimeTurnID, $0.id) }, uniquingKeysWith: { first, _ in first })
        let documentIndices = Dictionary(document.turns.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for record in submissions {
            let identity = "submission:\(record.resourceID)"
            if let turnID = record.turnID,
               let sourceID = sourceIDs[turnID], let index = documentIndices[sourceID] {
                document.turns[index].presentationID = identity
                continue
            }
            // Older runtime turns may be outside the current history page.
            // Their delivery records must never reappear at the timeline tail.
            guard !record.wasPresentedByRuntime, record.phase != .queued else { continue }
            var refs = record.fileReferences
            for attachment in record.attachments {
                let path = URL(string: attachment.resourceURI)?.path ?? attachment.displayName
                var ref = ComposerFileReference(path: path, workspacePath: nil, isDirectory: false)
                if let id = UUID(uuidString: attachment.id) { ref.id = id }
                if !refs.contains(where: { $0.id == ref.id }) { refs.append(ref) }
            }
            let status: String
            switch record.phase {
            case .preparing, .sending: status = "发送中"
            case .accepted: status = "已接收，等待开始"
            case .failed: status = record.failure ?? "发送失败，请重试"
            case .queued: continue
            }
            var turn = ConversationWebDocument.Turn(id: identity, userPrompt: record.displayText,
                userAssets: [], localAssets: [], fileReferences: refs,
                blocks: [], previews: nil, todos: [], extensionNodes: [], footer: nil,
                isLive: false, copyActionID: nil, shareActionID: nil,
                assetsActionID: nil, assetCount: 0, forkActionID: nil,
                elapsedText: nil, finishedAtClock: nil)
            turn.presentationID = identity
            turn.deliveryStatus = status
            if record.phase == .failed {
                turn.retrySubmissionActionID = registerAction(.retryLocalSubmission(key: key, id: record.id))
            }
            document.turns.append(turn)
        }
    }
}
#endif
