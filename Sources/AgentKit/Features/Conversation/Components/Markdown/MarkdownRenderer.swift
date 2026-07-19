//
//  MarkdownRenderer.swift
//  AgentKit
//
//  Public Markdown rendering view. Uses StreamingMarkdownRenderer internally
//  for stable-prefix caching during LLM streaming. Consecutive flow blocks
//  are concatenated into a single Text for continuous multi-line selection.
//

import SwiftUI

/// Parses and renders Markdown text into a vertical stack.
/// Delegates to StreamingMarkdownRenderer for stable-prefix caching:
/// already-parsed blocks retain their SwiftUI identity across re-renders,
/// so only the actively-streaming suffix re-renders on each token.
///
/// - Parameter baseFont: The font used for body/paragraph text. Headings,
///   code blocks, and tables use their own fonts scaled relative to this.
///   Defaults to `.body` (17pt on iOS).
/// - Parameter fillWidth: When true (default), text fills the container width.
///   Set to false for content that should size to its natural width
///   (e.g. user prompt bubbles).
struct MarkdownRenderer: View {
    let text: String
    var baseFont: Font = .body
    var fillWidth: Bool = true

    var body: some View {
        StreamingMarkdownRenderer(text: text, baseFont: baseFont, fillWidth: fillWidth)
    }
}
