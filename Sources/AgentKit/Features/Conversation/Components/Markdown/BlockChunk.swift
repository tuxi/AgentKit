//
//  BlockChunk.swift
//  AgentKit
//
//  Block chunking: groups consecutive flow blocks for continuous text selection.
//

import Foundation

// MARK: - BlockChunk

/// A chunk of blocks: either a sequence of flow blocks (rendered as one concatenated Text)
/// or a single structural block (rendered with its own background/layout).
enum BlockChunk: Identifiable {
    case flow([MarkdownBlock])
    case structural(MarkdownBlock)

    var id: String {
        switch self {
        case .flow(let blocks): return "flow:\(blocks.map(\.id).joined(separator: ","))"
        case .structural(let block): return "struct:\(block.id)"
        }
    }
}

// MARK: - Chunking

/// Groups blocks into alternating flow/structural chunks.
func groupIntoChunks(_ blocks: [MarkdownBlock]) -> [BlockChunk] {
    var chunks: [BlockChunk] = []
    var pendingFlow: [MarkdownBlock] = []

    for block in blocks {
        if block.isFlowBlock {
            pendingFlow.append(block)
        } else {
            if !pendingFlow.isEmpty {
                chunks.append(.flow(pendingFlow))
                pendingFlow = []
            }
            chunks.append(.structural(block))
        }
    }
    if !pendingFlow.isEmpty {
        chunks.append(.flow(pendingFlow))
    }

    return chunks
}
