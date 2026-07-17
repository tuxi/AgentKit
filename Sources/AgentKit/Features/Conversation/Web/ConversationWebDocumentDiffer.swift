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
    let recoveryViewport: RecoveryViewport?

    struct RecoveryViewport: Codable, Equatable, Sendable {
        let pinned: Bool
        let anchorID: String?
        let anchorTop: Double?
    }

    struct Patch: Codable, Equatable, Sendable {
        let baseRevision: UInt64
        let forcePinToBottom: Bool
        let operations: [Operation]
    }

    struct Operation: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case setTodos
            case replaceTurn
            case updateTurn
            case appendTurn
            case removeTurns
            case replaceBlock
            case appendBlock
            case removeBlocks
            case setLive
        }

        let kind: Kind
        let index: Int?
        let blockIndex: Int?
        let turn: ConversationWebDocument.Turn?
        let block: ConversationWebDocument.Block?
        let todos: [ConversationWebDocument.Todo]?
        let live: ConversationWebDocument.LiveState?

        static func setTodos(_ todos: [ConversationWebDocument.Todo]) -> Self {
            .init(
                kind: .setTodos, index: nil, blockIndex: nil,
                turn: nil, block: nil, todos: todos, live: nil
            )
        }

        static func replaceTurn(_ turn: ConversationWebDocument.Turn, at index: Int) -> Self {
            .init(
                kind: .replaceTurn, index: index, blockIndex: nil,
                turn: turn, block: nil, todos: nil, live: nil
            )
        }

        static func updateTurn(_ turn: ConversationWebDocument.Turn, at index: Int) -> Self {
            .init(
                kind: .updateTurn, index: index, blockIndex: nil,
                turn: turn, block: nil, todos: nil, live: nil
            )
        }

        static func appendTurn(_ turn: ConversationWebDocument.Turn) -> Self {
            .init(
                kind: .appendTurn, index: nil, blockIndex: nil,
                turn: turn, block: nil, todos: nil, live: nil
            )
        }

        static func removeTurns(from index: Int) -> Self {
            .init(
                kind: .removeTurns, index: index, blockIndex: nil,
                turn: nil, block: nil, todos: nil, live: nil
            )
        }

        static func replaceBlock(
            _ block: ConversationWebDocument.Block,
            inTurn turnIndex: Int,
            at blockIndex: Int
        ) -> Self {
            .init(
                kind: .replaceBlock, index: turnIndex, blockIndex: blockIndex,
                turn: nil, block: block, todos: nil, live: nil
            )
        }

        static func appendBlock(
            _ block: ConversationWebDocument.Block,
            toTurn turnIndex: Int
        ) -> Self {
            .init(
                kind: .appendBlock, index: turnIndex, blockIndex: nil,
                turn: nil, block: block, todos: nil, live: nil
            )
        }

        static func removeBlocks(inTurn turnIndex: Int, from blockIndex: Int) -> Self {
            .init(
                kind: .removeBlocks, index: turnIndex, blockIndex: blockIndex,
                turn: nil, block: nil, todos: nil, live: nil
            )
        }

        static func setLive(_ live: ConversationWebDocument.LiveState?) -> Self {
            .init(
                kind: .setLive, index: nil, blockIndex: nil,
                turn: nil, block: nil, todos: nil, live: live
            )
        }
    }
}

enum ConversationWebDocumentDiffer {
    static func reset(
        _ document: ConversationWebDocument,
        recoveryViewport: ConversationWebUpdate.RecoveryViewport? = nil
    ) -> ConversationWebUpdate {
        ConversationWebUpdate(
            protocolVersion: ConversationWebDocument.currentProtocolVersion,
            kind: .reset,
            conversationID: document.conversationID,
            revision: document.revision,
            document: document,
            patch: nil,
            recoveryViewport: recoveryViewport
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
            appendTurnOperations(
                from: old.turns[index],
                to: new.turns[index],
                at: index,
                into: &operations
            )
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
                // Content growth only follows when the viewport was already at
                // the bottom. Explicit user actions (initial reveal / Latest /
                // composer send) own any unconditional re-pin signal.
                forcePinToBottom: false,
                operations: operations
            ),
            recoveryViewport: nil
        )
    }

    private static func appendTurnOperations(
        from old: ConversationWebDocument.Turn,
        to new: ConversationWebDocument.Turn,
        at turnIndex: Int,
        into operations: inout [ConversationWebUpdate.Operation]
    ) {
        guard canPatchBlockShape(from: old.blocks, to: new.blocks) else {
            operations.append(.replaceTurn(new, at: turnIndex))
            return
        }

        if !hasEqualMetadata(old, new) {
            operations.append(.updateTurn(new, at: turnIndex))
        }

        let commonBlockCount = min(old.blocks.count, new.blocks.count)
        for blockIndex in 0..<commonBlockCount
        where old.blocks[blockIndex] != new.blocks[blockIndex] {
            operations.append(.replaceBlock(
                new.blocks[blockIndex],
                inTurn: turnIndex,
                at: blockIndex
            ))
        }
        if new.blocks.count > old.blocks.count {
            for block in new.blocks.dropFirst(old.blocks.count) {
                operations.append(.appendBlock(block, toTurn: turnIndex))
            }
        } else if new.blocks.count < old.blocks.count {
            operations.append(.removeBlocks(
                inTurn: turnIndex,
                from: new.blocks.count
            ))
        }
    }

    private static func hasEqualMetadata(
        _ lhs: ConversationWebDocument.Turn,
        _ rhs: ConversationWebDocument.Turn
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.userPrompt == rhs.userPrompt
            && lhs.todos == rhs.todos
            && lhs.extensionNodes == rhs.extensionNodes
            && lhs.footer == rhs.footer
            && lhs.isLive == rhs.isLive
            && lhs.copyActionID == rhs.copyActionID
            && lhs.shareActionID == rhs.shareActionID
            && lhs.assetsActionID == rhs.assetsActionID
            && lhs.assetCount == rhs.assetCount
    }

    private static func canPatchBlockShape(
        from old: [ConversationWebDocument.Block],
        to new: [ConversationWebDocument.Block]
    ) -> Bool {
        let commonCount = min(old.count, new.count)
        return old.prefix(commonCount).map(\.id)
            == new.prefix(commonCount).map(\.id)
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
