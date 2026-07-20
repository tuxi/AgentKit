//
//  AgentResponseView.swift
//  AgentKit
//
//  iOS: replaces NativeTranscriptView with a SwiftUI block-based layout.
//  Each turn block type gets its own view with appropriate layout behavior:
//  text blocks render as markdown, code/table blocks have min-width + horizontal
//  scroll, thinking cards collapse, tool groups expand on tap.
//

import SwiftUI

/// Renders an agent turn's blocks as a vertical stack of typed views,
/// replacing the TextKit NSAttributedString approach used on macOS.
struct AgentResponseView: View {
    let turn: ConversationTurn
    @Binding var documentState: TranscriptDocumentState
    let onAction: (TranscriptAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Agent heading
//            Text("Agent")
//                .font(.caption.weight(.semibold))
//                .foregroundStyle(.secondary)
//                .padding(.bottom, 2)

            // Ordered blocks
            ForEach(visibleBlocks) { block in
                blockView(for: block)
            }

            // Footer stats
            if let footer = turn.footer {
                TurnFooterView(stats: footer)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Visible blocks (filter suppressed system blocks)

    private var visibleBlocks: [TurnBlock] {
        var rendered: [TurnBlock] = []
        var previousFailed = false
        for block in turn.blocks {
            // Suppress system blocks that immediately follow a failed tool
            if previousFailed, case .system = block {
                previousFailed = false
                continue
            }
            previousFailed = false
            if case .toolGroup(let g) = block, g.tools.contains(where: { $0.status == .failed }) {
                previousFailed = true
            }
            rendered.append(block)
        }
        return rendered
    }

    // MARK: - Block dispatcher

    @ViewBuilder
    private func blockView(for block: TurnBlock) -> some View {
        switch block {
        case .text(_, let payload):
            MarkdownRenderer(text: payload.text)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .thinking(let id, let payload):
            ThinkingCardView(
                id: id,
                payload: payload,
                isExpanded: documentState.expandedThinkingIDs.contains(id)
                    || payload.isStreaming,
                onToggle: { onAction(.toggleThinking(id: id)) }
            )

        case .toolGroup(let group):
            ToolCallGroupView(
                group: group,
                documentState: $documentState,
                onAction: onAction
            )

        case .artifact(_, let node):
            ArtifactLinkRow(node: node, onAction: onAction)

        case .system(_, let payload):
            SystemMessageView(payload: payload)

        case .childStream(_, let payload):
            ChildStreamCardView(payload: payload, onAction: onAction)
        }
    }
}

// MARK: - Footer

private struct TurnFooterView: View {
    let stats: TurnStats

    var body: some View {
        HStack(spacing: 12) {
            Label(stats.formattedContextTokens, systemImage: "brain.head.profile")
            Label(stats.formattedTotalTokens, systemImage: "text.wordCount")
            Label(stats.formattedElapsed, systemImage: "clock")
            if stats.invocationCount > 1 {
                Label("×\(stats.invocationCount)", systemImage: "arrow.trianglehead.clockwise")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.top, 4)
    }
}

// MARK: - Artifact Link Row

private struct ArtifactLinkRow: View {
    let node: ArtifactNode
    let onAction: (TranscriptAction) -> Void

    var body: some View {
        Button {
            onAction(.openArtifact(callID: node.callID))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: node.iconName)
                    .font(.caption)
                Text(node.displayName)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "arrow.up.forward.app")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

private extension ArtifactNode {
    var iconName: String {
        switch content {
        case .file: return "doc"
        case .directory: return "folder"
        case .diff: return "arrow.left.arrow.right"
        case .terminal: return "terminal"
        }
    }

    var displayName: String {
        switch content {
        case .file(let p): return p.filePath
        case .directory(let p): return p.path
        case .diff(let p): return p.filePath ?? "Diff"
        case .terminal(let p): return p.command
        }
    }
}
