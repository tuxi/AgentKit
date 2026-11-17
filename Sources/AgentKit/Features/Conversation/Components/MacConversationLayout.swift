#if os(macOS)
import SwiftUI

/// Native geometry matching ConversationWorkbench/src/workbench.css:
/// `.conversation-shell` is a 760 pt border-box with 16 pt content insets.
/// The enclosing detail view adds the outer inset once, outside that shell.
enum MacConversationLayout {
    static let shellMaximumWidth: CGFloat = 760
    static let contentInset: CGFloat = 16
    static let outerInset: CGFloat = 20
}

/// Shared opaque canvas for the native shell and WKWebView. Explicit sRGB
/// values avoid dynamic NSColor resolving against the previous appearance.
enum MacConversationAppearance {
    static func canvasHex(isDark: Bool) -> String {
        isDark ? "#1F2023" : "#FFFFFF"
    }

    static func canvasColor(isDark: Bool) -> Color {
        isDark
            ? Color(.sRGB, red: 31.0 / 255, green: 32.0 / 255, blue: 35.0 / 255, opacity: 1)
            : Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 1)
    }
}
#endif
