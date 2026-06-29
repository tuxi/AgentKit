//
//  MessageBubble.swift
//  AgentKit
//
//  User / Assistant message bubble. User = right-aligned accent, Assistant = left-aligned quaternary.
//  Shows streaming cursor when isStreaming == true.
//

import SwiftUI

struct MessageBubble: View {
    let text: String
    let role: MessageRole
    var isStreaming: Bool = false

    var body: some View {
        if role == .user {
            // User prompt — right-aligned accent bubble.
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .font(.body)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        } else {
            // Assistant reply — flush-left prose, no avatar, no per-message
            // chrome. One copy button lives at the turn level (see TurnView).
            VStack(alignment: .leading, spacing: 4) {
                MarkdownRenderer(text: text)
                if isStreaming {
                    BlinkingCursor()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - BlinkingCursor

/// Smooth blinking cursor for streaming text.
struct BlinkingCursor: View {
    @State private var opacity: Double = 1

    var body: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 2, height: 16)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    opacity = 0.2
                }
            }
    }
}

#Preview {
    VStack(spacing: 16) {
        MessageBubble(text: "Hello, how are you?", role: .user)
        MessageBubble(text: "I'm doing well, thanks for asking!", role: .assistant)
        MessageBubble(text: "I'm still writing", role: .assistant, isStreaming: true)
    }
    .padding()
}
