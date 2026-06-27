//
//  ThinkingCard.swift
//  AgentKit
//
//  Agent thinking — always visible, acts as the narrative thread.
//  Style ref: Claude Code GUI — muted, indented, left-bordered.
//  Never collapsed. Tools are action inserts within this narrative.
//

import SwiftUI

struct ThinkingCard: View {
    let text: String
    let isStreaming: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left accent bar — subtle purple tint
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.purple.opacity(isStreaming ? 0.5 : 0.25))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 4) {
                // Header
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
                }

                // Body — always visible, italic for narrative feel
                MarkdownRenderer(text: text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.purple.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
