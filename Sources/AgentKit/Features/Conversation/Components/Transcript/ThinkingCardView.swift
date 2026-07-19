//
//  ThinkingCardView.swift
//  AgentKit
//
//  iOS: collapsible reasoning/thinking card with purple accent.
//  Auto-expands during streaming; tap to toggle when complete.
//

import SwiftUI

/// A collapsible card displaying the model's reasoning/thinking text.
struct ThinkingCardView: View {
    let id: String
    let payload: ThinkingNodePayload
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — tap to expand/collapse
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.caption)
                    Text("思考过程")
                        .font(.caption.weight(.medium))
                    if payload.isStreaming {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(thinkingAccentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
//                .background(
//                    RoundedRectangle(cornerRadius: 8)
//                        .fill(thinkingBackgroundColor)
//                )
//                .overlay(
//                    RoundedRectangle(cornerRadius: 8)
//                        .stroke(thinkingAccentColor.opacity(0.3), lineWidth: 1)
//                )
            }
            .buttonStyle(.plain)

            // Content — shown when expanded
            if isExpanded {
                Divider()
                    .padding(.horizontal, 10)
                MarkdownRenderer(text: payload.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
    }

    // Warm slate — calm, professional, not "AI purple".
    private var thinkingAccentColor: Color {
        #if os(macOS)
        Color(nsColor: NSColor(red: 0.33, green: 0.37, blue: 0.44, alpha: 1))
        #else
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.60, green: 0.64, blue: 0.70, alpha: 1)
                : UIColor(red: 0.33, green: 0.37, blue: 0.44, alpha: 1)
        })
        #endif
    }
}
