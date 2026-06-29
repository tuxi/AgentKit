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
                bottomRow
            }
            .padding(.leading, 8)
        }
    }

    /// One action/footer row per turn: a single copy button (copies the whole
    /// reply, Claude-Code style) + the token/timing footer.
    @ViewBuilder
    private var bottomRow: some View {
        let copyText = assistantText
        // Show copy once there's text that isn't actively streaming — NOT gated
        // on session liveness (turn.isLive stays true for the whole live
        // session, which hid the button until you reloaded into history).
        let canCopy = !copyText.isEmpty && !isAnswerStreaming
        if canCopy || turn.footer != nil {
            HStack(spacing: 12) {
                if canCopy {
                    TurnCopyButton(text: copyText)
                }
                if let footer = turn.footer {
                    footerStats(footer)
                }
                Spacer()
            }
            .padding(.top, 2)
        }
    }

    /// The turn's assistant prose — every `.text` block joined.
    private var assistantText: String {
        turn.blocks
            .compactMap { if case .text(_, let p) = $0 { return p.text } else { return nil } }
            .joined(separator: "\n\n")
    }

    /// True while the latest text block is still streaming in.
    private var isAnswerStreaming: Bool {
        for block in turn.blocks.reversed() {
            if case .text(_, let p) = block { return p.isStreaming }
        }
        return false
    }

    @ViewBuilder
    private func blockView(_ block: TurnBlock) -> some View {
        switch block {
        case .text(_, let payload):
            MessageBubble(text: payload.text, role: payload.role, isStreaming: payload.isStreaming)

        case .toolGroup(let group):
            ToolGroupView(group: group, store: store)

        case .artifact(_, let node):
            ArtifactCard(artifact: node, store: store)

        case .system(_, let payload):
            SystemEventRow(payload: payload)
        }
    }

    private func footerStats(_ stats: TurnStats) -> some View {
        HStack(spacing: 8) {
            Label("\(stats.formattedTokens) tokens", systemImage: "text.word.spacing")
            Label(stats.formattedElapsed, systemImage: "clock")
            if stats.invocationCount > 1 {
                Label("\(stats.invocationCount)×", systemImage: "cpu")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}

// MARK: - TurnCopyButton

/// One copy button per turn — copies the whole assistant reply.
private struct TurnCopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            Clipboard.copy(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption2)
                .foregroundStyle(copied ? Color.green : Color.secondary)
        }
        .buttonStyle(.plain)
        .help("复制回复")
    }
}
