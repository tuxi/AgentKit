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
        VStack {
            HStack(alignment: .top, spacing: 8) {
                if role == .assistant {
                    // Assistant avatar / indicator
                    VStack {
                        Image(systemName: "brain.head.profile")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.top, 4)
                }

                if role == .user { Spacer() }
                
                Group {
                    if role == .assistant {
                        // Rich Markdown rendering for assistant messages
                        VStack(alignment: .leading, spacing: 4) {
                            MarkdownRenderer(text: text)
                            if isStreaming {
                                BlinkingCursor()
                            }
                        }
                    } else {
                        // User messages stay plain text
                        Text(text)
                            .font(.body)
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background {
                    if role == .user {
                        Color.accentColor
                    } else {
                        Color.clear
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))


                if role == .assistant { Spacer() }

                if role == .user {
                    VStack {
                        Image(systemName: "person.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 4)
            
            Button {
                Clipboard.copy(text)
            } label: {
                if role == .assistant {
                    HStack {
                        Image(systemName: "document.on.document")
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.leading, 35)
                } else {
                    HStack {
                        Spacer()
                        Image(systemName: "document.on.document")
                            .font(.system(size: 13))
                    }
                    .padding(.trailing, 35)
                }
            }
            .buttonStyle(.plain)
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
