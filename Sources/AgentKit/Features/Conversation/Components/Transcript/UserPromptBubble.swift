//
//  UserPromptBubble.swift
//  AgentKit
//
//  iOS: standalone right-aligned user prompt bubble, rendered as a distinct
//  view instead of being mixed into the TextKit attributed string.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Right-aligned bubble showing the user's prompt text.
/// Uses plain Text (not MarkdownRenderer) so the bubble naturally
/// shrink-wraps to the content width — short prompts stay snug,
/// long prompts wrap at 72% screen width.
///
/// User-attached images are handled by `UserAssetPreviewStrip` above this bubble.
struct UserPromptBubble: View {
    let prompt: MessageNodePayload

    private var bubbleMaxWidth: CGFloat {
        #if os(iOS)
        UIScreen.main.bounds.width * 0.72
        #else
        400
        #endif
    }

    var body: some View {
        Text(prompt.text)
            .font(.body)
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.userBubbleBackground)
            )
            .frame(maxWidth: bubbleMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .trailing)
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
