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
#endif
