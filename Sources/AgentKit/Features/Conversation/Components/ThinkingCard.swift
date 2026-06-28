//
//  ThinkingCard.swift
//  AgentKit
//
//  Agent thinking — expanded while streaming so you can watch it live, then
//  collapsed once finished (one tap to re-open). Style ref: Claude Code GUI —
//  muted, indented, left-bordered. Collapsing on finish also hides the case
//  where an agent emits the same narration as both a thinking event and an
//  assistant message (it would otherwise show the text twice).
//

import SwiftUI

struct ThinkingCard: View {
    let text: String
    let isStreaming: Bool

    @State private var isExpanded: Bool

    init(text: String, isStreaming: Bool) {
        self.text = text
        self.isStreaming = isStreaming
        // Open while streaming, closed once it's a finished trace.
        self._isExpanded = State(initialValue: isStreaming)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left accent bar — subtle purple tint
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.purple.opacity(isStreaming ? 0.5 : 0.25))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 4) {
                // Header — tappable to expand/collapse
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "brain.head.profile")
                            .font(.caption2)
                            .foregroundStyle(.purple.opacity(0.7))

                        Text("Thinking")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.purple.opacity(0.7))
                            .textCase(.uppercase)

                        if isStreaming {
                            ProgressView()
                                .scaleEffect(0.4)
                                .frame(width: 10, height: 10)
                                .tint(.purple)
                        }

                        Spacer()

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.purple.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)

                // Body — italic narrative, only when expanded
                if isExpanded {
                    MarkdownRenderer(text: text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.purple.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onChange(of: isStreaming) { _, streaming in
            // Auto-collapse when the trace finishes; leave manual re-opens alone.
            if !streaming {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded = false }
            }
        }
    }
}
