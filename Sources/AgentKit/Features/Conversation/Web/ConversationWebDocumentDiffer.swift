//
//  ConversationWebDocumentDiffer.swift
//  AgentKit
//
//  Revisioned operations that preserve unchanged Turn DOM nodes.
//

import Foundation

struct ConversationWebUpdate: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case reset
        case patch
    }

    let protocolVersion: Int
    let kind: Kind
    let conversationID: String
    let revision: UInt64
    let document: ConversationWebDocument?
    let patch: Patch?

    struct Patch: Codable, Equatable, Sendable {
        let baseRevision: UInt64
        let forcePinToBottom: Bool
        let operations: [Operation]
    }

    struct Operation: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case setTodos
            case replaceTurn
            case appendTurn
            case removeTurns
            case setLive
        }

        let kind: Kind
        let index: Int?
        let turn: ConversationWebDocument.Turn?
        let todos: [ConversationWebDocument.Todo]?
        let live: ConversationWebDocument.LiveState?

        static func setTodos(_ todos: [ConversationWebDocument.Todo]) -> Self {
            .init(kind: .setTodos, index: nil, turn: nil, todos: todos, live: nil)
        }

        static func replaceTurn(_ turn: ConversationWebDocument.Turn, at index: Int) -> Self {
            .init(kind: .replaceTurn, index: index, turn: turn, todos: nil, live: nil)
        }

        static func appendTurn(_ turn: ConversationWebDocument.Turn) -> Self {
            .init(kind: .appendTurn, index: nil, turn: turn, todos: nil, live: nil)
        }

        static func removeTurns(from index: Int) -> Self {
            .init(kind: .removeTurns, index: index, turn: nil, todos: nil, live: nil)
        }

        static func setLive(_ live: ConversationWebDocument.LiveState?) -> Self {
            .init(kind: .setLive, index: nil, turn: nil, todos: nil, live: live)
        }
    }
}

enum ConversationWebDocumentDiffer {
    static func reset(_ document: ConversationWebDocument) -> ConversationWebUpdate {
        ConversationWebUpdate(
            protocolVersion: ConversationWebDocument.currentProtocolVersion,
            kind: .reset,
            conversationID: document.conversationID,
            revision: document.revision,
            document: document,
            patch: nil
        )
    }

    static func update(
        from old: ConversationWebDocument?,
        to new: ConversationWebDocument
    ) -> ConversationWebUpdate? {
        guard old != new else { return nil }
        guard let old,
              old.conversationID == new.conversationID,
              new.revision == old.revision + 1,
              canPatchTurnShape(from: old.turns, to: new.turns) else {
            return reset(new)
        }

        var operations: [ConversationWebUpdate.Operation] = []
        if old.todos != new.todos {
            operations.append(.setTodos(new.todos))
        }

        let commonCount = min(old.turns.count, new.turns.count)
        for index in 0..<commonCount where old.turns[index] != new.turns[index] {
            operations.append(.replaceTurn(new.turns[index], at: index))
        }
        if new.turns.count > old.turns.count {
            for turn in new.turns.dropFirst(old.turns.count) {
                operations.append(.appendTurn(turn))
            }
        } else if new.turns.count < old.turns.count {
            operations.append(.removeTurns(from: new.turns.count))
        }

        if old.live != new.live {
            operations.append(.setLive(new.live))
        }

        return ConversationWebUpdate(
            protocolVersion: ConversationWebDocument.currentProtocolVersion,
            kind: .patch,
            conversationID: new.conversationID,
            revision: new.revision,
            document: nil,
            patch: ConversationWebUpdate.Patch(
                baseRevision: old.revision,
                forcePinToBottom: old.turns.last?.id != nil
                    && old.turns.last?.id != new.turns.last?.id,
                operations: operations
            )
        )
    }

    private static func canPatchTurnShape(
        from old: [ConversationWebDocument.Turn],
        to new: [ConversationWebDocument.Turn]
    ) -> Bool {
        let commonCount = min(old.count, new.count)
        return old.prefix(commonCount).map(\.id)
            == new.prefix(commonCount).map(\.id)
    }
}
