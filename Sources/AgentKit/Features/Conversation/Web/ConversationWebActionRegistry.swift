//
//  ConversationWebActionRegistry.swift
//  AgentKit
//
//  Opaque, revision-scoped mapping from DOM action IDs to native actions.
//

import Foundation

enum ConversationWebAction: Hashable {
    case transcript(turnID: String, action: TranscriptAction)
    case showTurnAssets(turnID: String)
    case timelineExtension(extensionID: String, turnID: String, actionID: String)
    case timelineDocument(TimelineWebDocument)
}

@MainActor
final class ConversationWebActionRegistry {
    private var tokenByAction: [ConversationWebAction: String] = [:]
    private var actionByToken: [String: ConversationWebAction] = [:]
    private var activeTokens: Set<String> = []

    func beginRevision() {
        activeTokens.removeAll(keepingCapacity: true)
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
        activeTokens.insert(token)
        return token
    }

    func finishRevision() {
        let expired = Set(actionByToken.keys).subtracting(activeTokens)
        for token in expired {
            guard let action = actionByToken.removeValue(forKey: token) else { continue }
            tokenByAction.removeValue(forKey: action)
        }
    }

    func resolve(_ token: String) -> ConversationWebAction? {
        guard activeTokens.contains(token) else { return nil }
        return actionByToken[token]
    }

    func removeAll() {
        tokenByAction.removeAll(keepingCapacity: false)
        actionByToken.removeAll(keepingCapacity: false)
        activeTokens.removeAll(keepingCapacity: false)
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
