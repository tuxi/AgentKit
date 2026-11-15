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

public enum SessionRailSettingsDestination: Sendable { case environment, skills }
private struct SessionRailSettingsKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable (SessionRailSettingsDestination) -> Void)? = nil
}
public extension EnvironmentValues {
    var sessionRailOpenSettings: (@MainActor @Sendable (SessionRailSettingsDestination) -> Void)? {
        get { self[SessionRailSettingsKey.self] }
        set { self[SessionRailSettingsKey.self] = newValue }
    }
}
