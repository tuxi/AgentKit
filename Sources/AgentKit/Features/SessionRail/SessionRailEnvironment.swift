import SwiftUI

private struct SessionRailVisibilityKey: EnvironmentKey { static let defaultValue = false }
private struct ConversationSessionRailKey: EnvironmentKey { static let defaultValue = false }
public extension EnvironmentValues {
    var sessionRailIsVisible: Bool {
        get { self[SessionRailVisibilityKey.self] }
        set { self[SessionRailVisibilityKey.self] = newValue }
    }
    var conversationUsesSessionRail: Bool {
        get { self[ConversationSessionRailKey.self] }
        set { self[ConversationSessionRailKey.self] = newValue }
    }
}
