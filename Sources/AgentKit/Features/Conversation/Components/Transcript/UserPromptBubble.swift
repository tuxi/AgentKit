//
//  UserPromptBubble.swift
//  AgentKit
//
//  iOS: standalone right-aligned user prompt bubble, rendered as a distinct
//  view instead of being mixed into the TextKit attributed string.
//

import SwiftUI

/// Right-aligned bubble showing the user's prompt text, rendered as markdown.
/// User-attached images are handled by `UserAssetPreviewStrip` above this bubble.
struct UserPromptBubble: View {
    let prompt: MessageNodePayload

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            MarkdownRenderer(text: prompt.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.userBubbleBackground)
                )
        }
        .padding(.horizontal, 4)
    }
}

private extension Color {
    /// Warm translucent background matching TranscriptTheme.userBubble.
    static var userBubbleBackground: Color {
        #if os(macOS)
        Color(nsColor: NSColor(red: 0.36, green: 0.33, blue: 0.24, alpha: 0.09))
        #else
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.92, green: 0.90, blue: 0.84, alpha: 0.10)
                : UIColor(red: 0.36, green: 0.33, blue: 0.24, alpha: 0.09)
        })
        #endif
    }
}
