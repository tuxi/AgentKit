import Foundation

/// Device-local delivery intent. Never inserted into RuntimeEngine as execution events.
public struct LocalMessageSubmission: Codable, Sendable, Equatable, Identifiable {
    public enum Phase: String, Codable, Sendable { case preparing, sending, accepted, queued, failed }
    public var id: String
    public var resourceID: String
    public var text: String
    public var displayText: String
    public var fileReferences: [ComposerFileReference]
    public var model: String?
    public var reasoningEffort: ModelReasoningEffort?
    public var attachments: [DraftAttachmentReference] = []
    public var assets: [UserAssetRef] = []
    public var localAssets: [LocalUserAssetRef] = []
    public var prepared = false
    public var wasPresentedByRuntime = false
    public var phase: Phase = .preparing
    public var turnID: String?
    public var failure: String?
    public var createdAtMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)

    var input: AgentInput {
        .text(text, model: model, reasoningEffort: reasoningEffort,
              assets: assets, localAssets: localAssets, requestID: id)
    }
}

extension ConversationLocalStateStore {
    func updateLocalSubmission(key: ConversationLocalStateKey, id: String,
                               _ update: @Sendable (inout LocalMessageSubmission) -> Void) throws {
        try updateState(for: key) { state in
            guard let index = state.localSubmissions.firstIndex(where: { $0.id == id }) else { return }
            update(&state.localSubmissions[index])
        }
    }
}
