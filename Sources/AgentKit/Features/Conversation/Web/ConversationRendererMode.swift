//
//  ConversationRendererMode.swift
//  AgentKit
//
//  Rollout switch for the macOS conversation renderer.
//

import Foundation

/// Selects the renderer used by the conversation detail.
///
/// ``auto`` is the production default on macOS. It selects the Web workbench only
/// when every active Timeline extension supplies semantic Web nodes; otherwise it
/// preserves all content by falling back to the native renderer.
public enum ConversationRendererMode: String, Sendable, Codable, CaseIterable {
    case native
    case web
    case auto

    #if os(macOS)
    func resolved(hasLegacyTimelineExtensions: Bool) -> ConversationRendererMode {
        switch self {
        case .native:
            return .native
        case .web:
            return hasLegacyTimelineExtensions ? .native : .web
        case .auto:
            return hasLegacyTimelineExtensions ? .native : .web
        }
    }
    #endif
}
