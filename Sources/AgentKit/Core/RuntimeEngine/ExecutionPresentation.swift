//
//  ExecutionPresentation.swift
//  AgentKit
//
//  UI-facing model. ExecutionNode + display context.
//  Never stored in Runtime. Computed by the Presenter before handing to SwiftUI.
//  Allows different platforms (Mac/iOS/CLI) to present nodes differently
//  without changing the runtime model.
//

import Foundation

// MARK: - ExecutionPresentation

/// A UI-ready presentation of an ExecutionNode.
public struct ExecutionPresentation: Identifiable, Sendable {
    public let id: NodeID
    public let node: ExecutionNode
    public var displayMode: DisplayMode

    public init(id: NodeID, node: ExecutionNode, displayMode: DisplayMode = .full) {
        self.id = id
        self.node = node
        self.displayMode = displayMode
    }
}

// MARK: - DisplayMode

public enum DisplayMode: Sendable {
    /// Full rendering — all content visible, expandable sections expanded by default when streaming.
    case full
    /// Compact — collapsed by default, suitable for system events (contextCompact, modelActivity).
    case compact
    /// Minimal — single-line indicator, suitable for skill loads or auto-approved tools.
    case minimal
}

// MARK: - PresentationResolver

/// Computes the appropriate DisplayMode for each ExecutionNode.
/// Platform-agnostic logic; platforms can subclass or wrap with their own resolver.
public struct PresentationResolver: Sendable {

    public init() {}

    /// Determine display mode for a node.
    public func resolve(_ node: ExecutionNode) -> DisplayMode {
        switch node.kind {
        case .message:
            return .full
        case .thinking(let payload):
            // Auto-expand when streaming (live thinking)
            return payload.isStreaming ? .full : .compact
        case .tool(let payload):
            // Running tools get full display; completed tools are compact
            switch payload.status {
            case .running:
                return .full
            case .autoApproved:
                return .minimal
            default:
                return .compact
            }
        case .artifact:
            return .full
        case .system(let payload):
            switch payload.kind {
            case .observation:
                return .full
            case .reflection:
                return .full
            case .modelActivity:
                return .compact
            case .contextCompact:
                return .minimal
            case .skillLoaded:
                return .minimal
            case .error:
                return .full
            }
        }
    }
}

// MARK: - ExecutionPresenter

/// Produces [ExecutionPresentation] from [ExecutionNode].
/// This is the bridge between Projection output and SwiftUI.
public struct ExecutionPresenter: Sendable {
    public let resolver: PresentationResolver

    public init(resolver: PresentationResolver = PresentationResolver()) {
        self.resolver = resolver
    }

    /// Convert timeline nodes into UI-ready presentations.
    public func present(_ timeline: [ExecutionNode]) -> [ExecutionPresentation] {
        timeline.map { node in
            ExecutionPresentation(
                id: node.id,
                node: node,
                displayMode: resolver.resolve(node)
            )
        }
    }
}
