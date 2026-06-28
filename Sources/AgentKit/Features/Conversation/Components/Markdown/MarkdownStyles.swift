//
//  MarkdownStyles.swift
//  AgentKit
//
//  Shared styling constants for Markdown rendering.
//  All colors and fonts are iOS/macOS cross-platform.
//

import SwiftUI

// MARK: - Cross-Platform Color Helpers

extension Color {
    /// Platform-appropriate background color for code blocks.
    static var codeBlockBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    /// Inline code foreground (pink tone).
    static var inlineCodeForeground: Color { .pink }

    /// Inline code background (subtle).
    static var inlineCodeBackground: Color { .secondary.opacity(0.15) }

    /// Blockquote accent bar fill.
    static var blockquoteAccent: Color { .secondary.opacity(0.4) }

    /// Blockquote text color.
    static var blockquoteText: Color { .secondary }

    /// Link foreground color.
    static var linkForeground: Color { .blue }

    /// Bullet / list marker color.
    static var listMarker: Color { .secondary }

    /// Code block header background.
    static var codeBlockHeaderBackground: Color { .secondary.opacity(0.1) }

    /// Code block border.
    static var codeBlockBorder: Color { .secondary.opacity(0.2) }
}

// MARK: - Inline Code Styling

enum MarkdownFont {
    /// Inline code monospaced font.
    static var inlineCode: Font {
        .system(size: 13, weight: .regular, design: .monospaced)
    }

    /// Code block monospaced font.
    static var codeBlock: Font {
        .system(size: 12, weight: .regular, design: .monospaced)
    }

    /// Base body font for markdown text.
    static var body: Font { .body }
}

