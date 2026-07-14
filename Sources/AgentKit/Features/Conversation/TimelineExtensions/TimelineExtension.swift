//
//  TimelineExtension.swift
//  AgentKit
//
//  Host-owned extension point for product-specific Timeline content.
//

import SwiftUI

@MainActor
public protocol TimelineExtension: AnyObject {
    /// Stable identity used when rendering multiple host extensions.
    var id: String { get }

    /// Receives runtime events after AgentKit has ingested them.
    func handle(_ event: AgentEvent) async

    /// Optional host-owned content inserted after a conversation turn.
    func makeContent(for turnID: String) -> AnyView?
}

/// A Timeline extension that can render inside the single-document Web workbench.
///
/// Hosts provide data only. AgentKit owns HTML generation, action tokens, navigation,
/// selection, accessibility, and security policy. Arbitrary extension HTML or script
/// is never inserted into the conversation document.
@MainActor
public protocol WebTimelineExtension: TimelineExtension {
    func makeWebNodes(for turnID: String) -> [TimelineWebNode]
    func handleWebAction(_ action: TimelineWebAction) async
}

public extension WebTimelineExtension {
    func handleWebAction(_ action: TimelineWebAction) async {}
}

/// The semantic action returned to a host extension after AgentKit resolves an opaque
/// token from the current Web document revision.
public struct TimelineWebAction: Sendable, Hashable {
    public let extensionID: String
    public let turnID: String
    public let actionID: String

    public init(extensionID: String, turnID: String, actionID: String) {
        self.extensionID = extensionID
        self.turnID = turnID
        self.actionID = actionID
    }
}

/// Safe, Codable content supported by host-owned Timeline extensions in Web mode.
public struct TimelineWebNode: Codable, Sendable, Hashable, Identifiable {
    public enum Tone: String, Codable, Sendable {
        case neutral
        case info
        case success
        case warning
        case danger
    }

    public let id: String
    public let title: String
    public let summary: String?
    public let status: String?
    public let tone: Tone
    public let badges: [Badge]
    public let sections: [Section]
    public let actions: [ActionReference]
    public let footer: String?

    public init(
        id: String,
        title: String,
        summary: String? = nil,
        status: String? = nil,
        tone: Tone = .neutral,
        badges: [Badge] = [],
        sections: [Section] = [],
        actions: [ActionReference] = [],
        footer: String? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.status = status
        self.tone = tone
        self.badges = badges
        self.sections = sections
        self.actions = actions
        self.footer = footer
    }

    public struct Badge: Codable, Sendable, Hashable, Identifiable {
        public let id: String
        public let text: String
        public let tone: Tone

        public init(id: String, text: String, tone: Tone = .neutral) {
            self.id = id
            self.text = text
            self.tone = tone
        }
    }

    public struct Section: Codable, Sendable, Hashable, Identifiable {
        public let id: String
        public let title: String
        public let summary: String?
        public let status: String?
        public let rows: [Row]
        public let initiallyExpanded: Bool

        public init(
            id: String,
            title: String,
            summary: String? = nil,
            status: String? = nil,
            rows: [Row] = [],
            initiallyExpanded: Bool = false
        ) {
            self.id = id
            self.title = title
            self.summary = summary
            self.status = status
            self.rows = rows
            self.initiallyExpanded = initiallyExpanded
        }
    }

    public struct Row: Codable, Sendable, Hashable, Identifiable {
        public let id: String
        public let label: String
        public let value: String

        public init(id: String, label: String, value: String) {
            self.id = id
            self.label = label
            self.value = value
        }
    }

    public struct ActionReference: Codable, Sendable, Hashable, Identifiable {
        public enum Kind: String, Codable, Sendable {
            case extensionAction
            case document
        }

        public let id: String
        public let title: String
        public let tooltip: String?
        public let kind: Kind
        public let document: TimelineWebDocument?

        public init(
            id: String,
            title: String,
            tooltip: String? = nil,
            kind: Kind = .extensionAction,
            document: TimelineWebDocument? = nil
        ) {
            self.id = id
            self.title = title
            self.tooltip = tooltip
            self.kind = kind
            self.document = document
        }

        public static func document(
            id: String,
            title: String,
            tooltip: String? = nil,
            document: TimelineWebDocument
        ) -> Self {
            .init(
                id: id,
                title: title,
                tooltip: tooltip,
                kind: .document,
                document: document
            )
        }
    }
}

/// A host document opened in AgentKit's native Inspector. HTML is never injected into
/// the conversation DOM and is displayed in a script-disabled, network-blocked WebView.
public struct TimelineWebDocument: Codable, Sendable, Hashable, Identifiable {
    public enum Format: String, Codable, Sendable {
        case plainText
        case markdown
        case html
    }

    public let id: String
    public let title: String
    public let format: Format
    public let body: String

    public init(id: String, title: String, format: Format, body: String) {
        self.id = id
        self.title = title
        self.format = format
        self.body = body
    }
}

/// Internal projection preserves which extension owns each semantic node without
/// exposing host action IDs to JavaScript.
struct TimelineWebContribution: Sendable, Hashable {
    let extensionID: String
    let node: TimelineWebNode
}
