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
