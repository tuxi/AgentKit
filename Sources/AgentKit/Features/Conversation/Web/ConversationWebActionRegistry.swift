//
//  ConversationWebActionRegistry.swift
//  AgentKit
//
//  Opaque, revision-scoped mapping from DOM action IDs to native actions.
//

import Foundation

enum ConversationWebAction: Hashable {
    case transcript(turnID: String, action: TranscriptAction)
    case shareTurn(turnID: String)
    case showTurnAssets(turnID: String)
    case timelineExtension(extensionID: String, turnID: String, actionID: String)
    case timelineDocument(TimelineWebDocument)
}

@MainActor
final class ConversationWebActionRegistry {
    private var tokenByAction: [ConversationWebAction: String] = [:]
    private var actionByToken: [String: ConversationWebAction] = [:]
    private var tokensByRevision: [UInt64: Set<String>] = [:]
    private var buildingRevision: UInt64?
    private var buildingTokens: Set<String> = []

    func beginRevision(_ revision: UInt64 = 0) {
        buildingRevision = revision
        buildingTokens.removeAll(keepingCapacity: true)
    }

    func register(_ action: ConversationWebAction) -> String {
        let token: String
        if let existing = tokenByAction[action] {
            token = existing
        } else {
            token = UUID().uuidString.lowercased()
            tokenByAction[action] = token
            actionByToken[token] = action
        }
        buildingTokens.insert(token)
        return token
    }

    func finishRevision(retaining reusedTokens: Set<String> = []) {
        guard let buildingRevision else { return }
        buildingTokens.formUnion(reusedTokens.filter { actionByToken[$0] != nil })
        tokensByRevision[buildingRevision] = buildingTokens
        self.buildingRevision = nil
        buildingTokens.removeAll(keepingCapacity: true)
        removeUnreferencedTokens()
    }

    func resolve(_ token: String, revision: UInt64? = nil) -> ConversationWebAction? {
        if let revision {
            guard tokensByRevision[revision]?.contains(token) == true else { return nil }
        } else {
            guard tokensByRevision.values.contains(where: { $0.contains(token) }) else {
                return nil
            }
        }
        return actionByToken[token]
    }

    /// Keeps actions for the document currently visible in WebKit and an
    /// optional in-flight successor. Older DOM revisions can no longer send
    /// actions once they are not retained here.
    func retainRevisions(_ revisions: Set<UInt64>) {
        tokensByRevision = tokensByRevision.filter { revisions.contains($0.key) }
        removeUnreferencedTokens()
    }

    func removeAll() {
        tokenByAction.removeAll(keepingCapacity: false)
        actionByToken.removeAll(keepingCapacity: false)
        tokensByRevision.removeAll(keepingCapacity: false)
        buildingRevision = nil
        buildingTokens.removeAll(keepingCapacity: false)
    }

    private func removeUnreferencedTokens() {
        let referenced = tokensByRevision.values.reduce(into: Set<String>()) {
            $0.formUnion($1)
        }.union(buildingTokens)
        let expired = Set(actionByToken.keys).subtracting(referenced)
        for token in expired {
            guard let action = actionByToken.removeValue(forKey: token) else { continue }
            tokenByAction.removeValue(forKey: action)
        }
    }
}

#if os(macOS)
import SwiftUI

@MainActor
enum ConversationWebActionDispatcher {
    static func dispatch(
        _ action: ConversationWebAction,
        turns: [ConversationTurn],
        timelineExtensions: [any TimelineExtension],
        store: WorkspaceStore,
        openURL: OpenURLAction
    ) {
        switch action {
        case .transcript(let turnID, let transcriptAction):
            guard let turn = turns.first(where: { $0.id == turnID }) else { return }
            TurnActionDispatcher(turn: turn, store: store, openURL: openURL)
                .handle(transcriptAction)

        case .showTurnAssets(let turnID):
            guard let turn = turns.first(where: { $0.id == turnID }) else { return }
            TurnActionDispatcher(turn: turn, store: store, openURL: openURL)
                .showTurnAssets()

        case .shareTurn(let turnID):
            guard let turn = turns.first(where: { $0.id == turnID }) else { return }
            TurnActionDispatcher(turn: turn, store: store, openURL: openURL)
                .shareTurn(as: .image)

        case .timelineExtension(let extensionID, let turnID, let actionID):
            guard let timelineExtension = timelineExtensions.first(where: { $0.id == extensionID })
                    as? any WebTimelineExtension else { return }
            Task {
                await timelineExtension.handleWebAction(.init(
                    extensionID: extensionID,
                    turnID: turnID,
                    actionID: actionID
                ))
            }

        case .timelineDocument(let document):
            store.showInspector(.timelineDocument(document))
        }
    }
}
#endif
