//
//  TurnView.swift
//  AgentKit
//
//  Renders one ConversationTurn as a single continuous message:
//  user prompt → ordered assistant blocks (text / thinking / tools) → footer.
//  Lifecycle noise (model invoked/finished) never appears — it's in the footer.
//

import SwiftUI

struct TurnView: View {
    let turn: ConversationTurn
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // User prompt
            if let user = turn.userPrompt {
                MessageBubble(text: user.text, role: .user)
            }

            // Assistant activity — one continuous stream of blocks.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(turn.blocks) { block in
                    blockView(block)
                }
                if let footer = turn.footer {
                    footerView(footer)
                }
            }
            .padding(.leading, 8)
        }
    }

    @ViewBuilder
    private func blockView(_ block: TurnBlock) -> some View {
        switch block {
        case .text(_, let payload):
            MessageBubble(text: payload.text, role: payload.role, isStreaming: payload.isStreaming)

        case .thinking(_, let payload):
            ThinkingCard(text: payload.text, isStreaming: payload.isStreaming)

        case .toolGroup(let group):
            // Phase C: render each tool with the existing card. Phase D folds
            // these into a single ×N line.
            ForEach(group.tools, id: \.callID) { tool in
                ToolCard(tool: tool, store: store, activeToolCallID: group.activeToolCallID)
            }

        case .artifact(_, let node):
            ArtifactCard(artifact: node, store: store)

        case .system(_, let payload):
            SystemEventRow(payload: payload)
        }
    }

    private func footerView(_ stats: TurnStats) -> some View {
        HStack(spacing: 8) {
            Label("\(stats.formattedTokens) tokens", systemImage: "text.word.spacing")
            Label(stats.formattedElapsed, systemImage: "clock")
            if stats.invocationCount > 1 {
                Label("\(stats.invocationCount)×", systemImage: "cpu")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.top, 2)
    }
}
