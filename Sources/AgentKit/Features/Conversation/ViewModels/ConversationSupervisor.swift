//
//  ConversationSupervisor.swift
//  AgentKit
//
//  Owns all retained conversation controllers. UI selection is presentation only.
//

import SwiftUI

public enum ConversationActivityState: String, Sendable, Equatable {
    case connecting
    case queued
    case running
    case waitingForApproval
    case paused
    case failed
    case idle
}

public enum PendingConversationApprovalKind: Sendable, Equatable {
    case tool
    case plan
}

public struct PendingConversationApproval: Identifiable, Sendable, Equatable {
    public let sessionID: String
    public let requestID: String
    public let conversationName: String
    public let kind: PendingConversationApprovalKind

    public var id: String { "\(sessionID):\(requestID)" }
}

/// Workspace-level owner of independently retained conversation view models.
@MainActor
@Observable
public final class ConversationSupervisor {
    public private(set) var controllers: [String: ConversationViewModel] = [:]
    public private(set) var runtimeCapabilities: RuntimeCapabilitySnapshot = .legacy
    public private(set) var runtimeActivities: [String: RuntimeSessionActivity] = [:]

    private let client: RuntimeClient
    private let toolRegistry: ToolRegistry
    private let timelineExtensions: [any TimelineExtension]
    private let onAuthExpired: (@MainActor () async -> Void)?
    private let turnCoordinator = ConversationTurnCoordinator()
    private let capabilityRegistry = RuntimeCapabilityRegistry()

    public init(
        client: RuntimeClient,
        toolRegistry: ToolRegistry,
        timelineExtensions: [any TimelineExtension],
        onAuthExpired: (@MainActor () async -> Void)?
    ) {
        self.client = client
        self.toolRegistry = toolRegistry
        self.timelineExtensions = timelineExtensions
        self.onAuthExpired = onAuthExpired
    }

    @discardableResult
    public func controller(
        for conversation: ConversationRef,
        workspace: Workspace? = nil,
        model: String = ""
    ) -> ConversationViewModel {
        if let existing = controllers[conversation.id] {
            return existing
        }

        let controller = ConversationViewModel(
            client: client,
            toolRegistry: toolRegistry,
            workspace: workspace,
            model: model,
            timelineExtensions: timelineExtensions,
            turnCoordinator: turnCoordinator,
            capabilityRegistry: capabilityRegistry,
            onAuthExpired: onAuthExpired
        )
        controllers[conversation.id] = controller
        return controller
    }

    public func controller(sessionID: String) -> ConversationViewModel? {
        controllers[sessionID]
    }

    public func activity(for sessionID: String) -> ConversationActivityState {
        if let controller = controllers[sessionID] {
            if controller.isLocallyQueued { return .queued }
            if controller.isAwaitingTurnAcceptance { return .connecting }
            if controller.snapshot.pendingApproval != nil || controller.snapshot.pendingPlanApproval != nil {
                return .waitingForApproval
            }
            if controller.isConnecting { return .connecting }
            switch controller.lifecycleStatus {
            case "accepted", "queued": return .queued
            case "running", "resuming": return .running
            case "paused": return .paused
            case "failed": return .failed
            default: break
            }
        }
        guard let remote = runtimeActivities[sessionID] else { return .idle }
        switch remote.state {
        case "queued": return .queued
        case "running", "resuming": return .running
        case "waiting_approval", "waiting_client_tool": return .waitingForApproval
        case "paused": return .paused
        case "failed": return .failed
        default: return .idle
        }
    }

    /// Refresh runtime-wide truth. Unsupported/404 is an intentional legacy downgrade.
    public func refreshRuntimeState(conversations: [ConversationRef]) async {
        let capabilitySnapshot: RuntimeCapabilitySnapshot
        do {
            capabilitySnapshot = try await client.runtimeCapabilities()
        } catch {
            runtimeCapabilities = .legacy
            runtimeActivities = [:]
            await capabilityRegistry.update(.legacy)
            return
        }
        runtimeCapabilities = capabilitySnapshot
        await capabilityRegistry.update(capabilitySnapshot)

        // Code-Agent introduced the snapshot endpoint before enabling the richer
        // activity_snapshot_v1 guarantee. Probe it whenever capability discovery
        // itself succeeds; a missing endpoint remains an empty legacy downgrade.
        if let activity = try? await client.activitySnapshot() {
            runtimeActivities = Dictionary(uniqueKeysWithValues: activity.sessions.map { ($0.sessionID, $0) })
        } else {
            runtimeActivities = [:]
        }

        // Reattach every live session, not only the selected one, so background status,
        // approvals and terminal events continue to flow after app restoration.
        for conversation in conversations where shouldRetainLiveChannel(sessionID: conversation.id) {
            let controller = controller(for: conversation)
            await controller.connect(to: conversation)
        }
    }

    private func shouldRetainLiveChannel(sessionID: String) -> Bool {
        guard let state = runtimeActivities[sessionID]?.state else { return false }
        return ["queued", "running", "resuming", "waiting_approval", "waiting_client_tool", "paused"].contains(state)
    }

    public var pendingApprovals: [PendingConversationApproval] {
        controllers.values.compactMap { controller -> PendingConversationApproval? in
            guard let conversation = controller.conversation else { return nil }
            let name = conversation.name ?? conversation.id
            if let request = controller.snapshot.pendingApproval {
                return PendingConversationApproval(
                    sessionID: conversation.id,
                    requestID: request.id,
                    conversationName: name,
                    kind: .tool
                )
            }
            if let request = controller.snapshot.pendingPlanApproval {
                return PendingConversationApproval(
                    sessionID: conversation.id,
                    requestID: request.id,
                    conversationName: name,
                    kind: .plan
                )
            }
            return nil
        }
        .sorted { $0.conversationName < $1.conversationName }
    }

    /// Disconnect only idle controllers. Running, queued, paused and approval-blocked
    /// sessions are intentionally retained regardless of current UI selection.
    public func evictIdleControllers(excluding sessionID: String? = nil) async {
        let candidates = controllers.compactMap { id, controller -> (String, ConversationViewModel)? in
            guard id != sessionID, activity(for: id) == .idle else { return nil }
            return (id, controller)
        }
        for (id, controller) in candidates {
            await controller.disconnect()
            controllers.removeValue(forKey: id)
        }
    }
}
