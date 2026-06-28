//
//  StreamingMarkdownRenderer.swift
//  AgentKit
//
//  Streaming-aware Markdown renderer with stable-prefix caching.
//  Mirrors Claude Code's approach: freeze already-stable flow chunks
//  so they don't re-render while the LLM continues streaming new tokens.
//  Consecutive flow blocks are grouped for continuous text selection.
//

import SwiftUI

// MARK: - Stable Block Identity

/// A block identity that persists across re-parses when content is unchanged.
struct StableBlockID: Hashable {
    let index: Int
    let contentHash: String

    init(index: Int, block: MarkdownBlock) {
        self.index = index
        self.contentHash = block.id
    }
}

// MARK: - Diff Result

/// One entry in the stable-prefix diff, keyed by chunk type.
struct DiffEntry: Identifiable {
    let id: StableBlockID
    let chunk: BlockChunk
}

// MARK: - Streaming Markdown Renderer

/// Renders markdown with stable view identity for streaming efficiency
/// and continuous text selection within flow chunks.
struct StreamingMarkdownRenderer: View {
    let text: String

    @State private var previousEntries: [DiffEntry] = []

    var body: some View {
        let blocks = MarkdownASTConverter.parse(text)
        let chunks = groupIntoChunks(blocks)
        let entries = diffAndAssignIDs(
            chunks: chunks,
            previousEntries: previousEntries
        )

        VStack(alignment: .leading, spacing: 6) {
            ForEach(entries) { entry in
                switch entry.chunk {
                case .flow(let flowBlocks):
                    FlowTextBlock(blocks: flowBlocks)
                        .id(entry.id)
                case .structural(let block):
                    MarkdownBlockView(block: block)
                        .id(entry.id)
                }
            }
        }
        .onChange(of: entries.map(\.id)) { _, _ in
            previousEntries = entries
        }
    }

    // MARK: - Stable-Prefix Diff Algorithm

    private func diffAndAssignIDs(
        chunks: [BlockChunk],
        previousEntries: [DiffEntry]
    ) -> [DiffEntry] {
        let commonCount = computeCommonPrefixLength(chunks, previousEntries)

        var entries: [DiffEntry] = []

        for i in 0..<commonCount {
            entries.append(DiffEntry(
                id: previousEntries[i].id,
                chunk: chunks[i]
            ))
        }

        for i in commonCount..<chunks.count {
            // Use chunk id for stable identity
            let blockForID = representativeBlock(for: chunks[i])
            entries.append(DiffEntry(
                id: StableBlockID(index: i, block: blockForID),
                chunk: chunks[i]
            ))
        }

        return entries
    }

    private func representativeBlock(for chunk: BlockChunk) -> MarkdownBlock {
        switch chunk {
        case .flow(let blocks):
            return blocks.first ?? .thematicBreak // placeholder — shouldn't happen
        case .structural(let block):
            return block
        }
    }

    private func computeCommonPrefixLength(
        _ chunks: [BlockChunk],
        _ previousEntries: [DiffEntry]
    ) -> Int {
        var count = 0
        let minLen = min(chunks.count, previousEntries.count)
        // Don't freeze the last chunk — it may be actively streaming
        let checkLen = max(0, minLen - 1)

        for i in 0..<checkLen {
            if chunks[i].id == previousEntries[i].chunk.id {
                count += 1
            } else {
                break
            }
        }

        return count
    }
}
