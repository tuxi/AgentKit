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
    case waitingForClientTool
    case paused
    case succeeded
    case failed
    case cancelled
    case idle
}

/// Discovery is separate from the capability snapshot itself. `.legacy` means
/// "no guarantees" and must not also be used to mean "the first HTTP request has
/// not run yet", otherwise capability-gated controls disappear during first render.
public enum RuntimeCapabilityDiscoveryState: Sendable, Equatable {
    case idle
    case loading
    case available
    case unavailable
}

public enum PendingConversationApprovalKind: Sendable, Equatable {
    case tool
    case plan
    case askUser
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
    public private(set) var runtimeCapabilityDiscoveryState: RuntimeCapabilityDiscoveryState = .idle
    public private(set) var runtimeCapabilityErrorMessage: String?
    public private(set) var runtimeActivities: [String: RuntimeSessionActivity] = [:]
    public private(set) var unreadTerminals: [String: ConversationTerminalAttention] = [:]

    private let client: RuntimeClient
    private let toolRegistry: ToolRegistry
    private let timelineExtensions: [any TimelineExtension]
    private let onAuthExpired: (@MainActor () async -> Void)?
    private let attentionReadStore: any ConversationAttentionReadStore
    private let localStateStore: any ConversationLocalStateStore
    private let onAttentionEvent: (@MainActor (ConversationAttentionEvent) -> Void)?
    private let turnCoordinator = ConversationTurnCoordinator()
    private let capabilityRegistry = RuntimeCapabilityRegistry()
    private var selectedSessionID: String?
    private var knownConversations: [String: ConversationRef] = [:]
    private var isRefreshingActivity = false
    private var activityCursor: Int64?
    private var controllerAccessSequence: UInt64 = 0
    private var controllerLastAccess: [String: UInt64] = [:]
    @ObservationIgnored private var activityRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var activityMonitoringTask: Task<Void, Never>?
    @ObservationIgnored private var resourceReconciliationTask: Task<Void, Never>?
    private var capabilityRefreshRevision: UInt64 = 0

    private static let defaultMaxRetainedControllers = 8

    public init(
        client: RuntimeClient,
        toolRegistry: ToolRegistry,
        timelineExtensions: [any TimelineExtension],
        onAuthExpired: (@MainActor () async -> Void)?,
        localStateStore: any ConversationLocalStateStore = SQLiteConversationLocalStateStore.shared,
        attentionReadStore: any ConversationAttentionReadStore = ConversationLocalStateAttentionReadStore.shared,
        onAttentionEvent: (@MainActor (ConversationAttentionEvent) -> Void)? = nil
    ) {
        self.client = client
        self.toolRegistry = toolRegistry
        self.timelineExtensions = timelineExtensions
        self.onAuthExpired = onAuthExpired
        self.localStateStore = localStateStore
        self.attentionReadStore = attentionReadStore
        self.onAttentionEvent = onAttentionEvent
    }

    @discardableResult
    public func controller(
        for conversation: ConversationRef,
        workspace: Workspace? = nil,
        model: String = ""
    ) -> ConversationViewModel {
        if let existing = controllers[conversation.id] {
            touchController(sessionID: conversation.id)
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
            localStateStore: localStateStore,
            onAuthExpired: onAuthExpired,
            onActivityInvalidated: { [weak self] in
                self?.scheduleActivityRefresh()
            }
        )
        controllers[conversation.id] = controller
        touchController(sessionID: conversation.id)
        scheduleControllerLimitEnforcement()
        return controller
    }

    public func controller(sessionID: String) -> ConversationViewModel? {
        controllers[sessionID]
    }

    /// Prefer the live per-session channel over the sampled scheduler projection.
    /// This keeps the sidebar reason current between `/v1/activity` polls.
    public func queueReason(for sessionID: String) -> String? {
        if let controller = controllers[sessionID],
           controller.lifecycleStatus == "queued",
           let reason = controller.queueReason {
            return reason
        }
        return runtimeActivities[sessionID]?.queueReason
    }

    public func activity(for sessionID: String) -> ConversationActivityState {
        activity(for: knownConversations[sessionID] ?? controllers[sessionID]?.conversation)
    }

    /// One presentation state merged from live controller, Runtime attention, and
    /// finally the persisted ConversationRef lifecycle used during cold start.
    public func activity(for conversation: ConversationRef?) -> ConversationActivityState {
        guard let conversation else { return .idle }
        let sessionID = conversation.id

        if let controller = controllers[sessionID] {
            if controller.isLocallyQueued { return .queued }
            if controller.isAwaitingTurnAcceptance { return .connecting }
            if controller.snapshot.pendingApproval != nil
                || controller.snapshot.pendingPlanApproval != nil
                || controller.snapshot.pendingAskUser != nil {
                return .waitingForApproval
            }
            if controller.isConnecting {
                if let terminal = unreadTerminals[sessionID],
                   !isActiveState(runtimeActivities[sessionID]?.state) {
                    return activity(for: terminal.outcome)
                }
                return .connecting
            }
            switch controller.lifecycleStatus {
            case "accepted", "queued": return .queued
            case "running", "resuming": return .running
            case "paused": return .paused
            case "done", "failed", "cancelled":
                guard selectedSessionID != sessionID else { return .idle }
                if let terminal = unreadTerminals[sessionID] {
                    return activity(for: terminal.outcome)
                }
                if runtimeCapabilities.flags.contains(.sessionAttentionSnapshot),
                   runtimeActivities[sessionID]?.latestTerminal != nil {
                    return .idle
                }
                switch controller.lifecycleStatus {
                case "done": return .succeeded
                case "failed": return .failed
                default: return .cancelled
                }
            default: break
            }
        }

        if let remote = runtimeActivities[sessionID] {
            switch remote.state {
            case "waiting_approval": return .waitingForApproval
            case "waiting_client_tool": return .waitingForClientTool
            case "queued", "accepted": return .queued
            case "running", "resuming": return .running
            case "paused": return .paused
            default: break
            }
        }

        if let terminal = unreadTerminals[sessionID] {
            return activity(for: terminal.outcome)
        }

        // A retained controller is newer than the list reference. Returning idle
        // here prevents a stale ConversationRef.failed from reappearing after the
        // user has viewed a newer terminal result.
        if controllers[sessionID] != nil { return .idle }

        // With the durable attention contract, a terminal that is not present in
        // unreadTerminals has already been viewed or was migration baseline data.
        if runtimeCapabilities.flags.contains(.sessionAttentionSnapshot),
           runtimeActivities[sessionID] != nil {
            return .idle
        }

        switch conversation.turnStatus {
        case "running", "resuming": return .running
        case "paused": return .paused
        case "failed": return .failed
        default: return .idle
        }
    }

    public func setSelectedSessionID(_ sessionID: String?) {
        selectedSessionID = sessionID
        guard let sessionID else { return }
        touchController(sessionID: sessionID)
        scheduleControllerLimitEnforcement()
        markTerminalSeen(sessionID: sessionID)
    }

    public func markTerminalSeen(sessionID: String) {
        guard let terminal = runtimeActivities[sessionID]?.latestTerminal else {
            unreadTerminals.removeValue(forKey: sessionID)
            return
        }
        attentionReadStore.setLastSeenTerminalSequence(terminal.sequence, for: sessionID)
        unreadTerminals.removeValue(forKey: sessionID)
    }

    /// Refresh runtime-wide truth. Unsupported/404 is an intentional legacy downgrade.
    public func refreshRuntimeState(conversations: [ConversationRef]) async {
        knownConversations = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        capabilityRefreshRevision &+= 1
        let refreshRevision = capabilityRefreshRevision
        runtimeCapabilityDiscoveryState = .loading
        runtimeCapabilityErrorMessage = nil
        let capabilitySnapshot: RuntimeCapabilitySnapshot
        do {
            capabilitySnapshot = try await client.runtimeCapabilities()
        } catch {
            guard refreshRevision == capabilityRefreshRevision else { return }
            runtimeCapabilities = .legacy
            runtimeActivities = [:]
            activityCursor = nil
            runtimeCapabilityDiscoveryState = .unavailable
            runtimeCapabilityErrorMessage = error.localizedDescription
            await capabilityRegistry.update(.legacy)
            return
        }
        guard refreshRevision == capabilityRefreshRevision else { return }
        let supportedDeltaBefore = runtimeCapabilities.flags.contains(.sessionAttentionSnapshot)
            && runtimeCapabilities.flags.contains(.sessionAttentionDelta)
        runtimeCapabilities = capabilitySnapshot
        runtimeCapabilityDiscoveryState = .available
        let supportsDeltaNow = capabilitySnapshot.flags.contains(.sessionAttentionSnapshot)
            && capabilitySnapshot.flags.contains(.sessionAttentionDelta)
        if !supportsDeltaNow || !supportedDeltaBefore {
            activityCursor = nil
        }
        await capabilityRegistry.update(capabilitySnapshot)
        await refreshActivitySnapshot()
        startActivityMonitoring()
    }

    private func shouldRetainLiveChannel(sessionID: String) -> Bool {
        guard let state = runtimeActivities[sessionID]?.state else { return false }
        return ["queued", "running", "resuming", "waiting_approval", "waiting_client_tool", "paused"].contains(state)
    }

    private func refreshActivitySnapshot() async {
        guard !isRefreshingActivity else { return }
        isRefreshingActivity = true
        defer { isRefreshingActivity = false }

        let supportsDelta = runtimeCapabilities.flags.contains(.sessionAttentionSnapshot)
            && runtimeCapabilities.flags.contains(.sessionAttentionDelta)
        let requestedCursor = supportsDelta ? activityCursor : nil
        guard var activity = try? await client.activitySnapshot(sinceSequence: requestedCursor) else { return }

        // A replaced/reset event store can move the cursor backwards. Retry once
        // with a full baseline rather than merging unrelated sequence spaces.
        if let requestedCursor,
           let returnedCursor = activity.cursor,
           returnedCursor < requestedCursor {
            activityCursor = nil
            guard let full = try? await client.activitySnapshot(sinceSequence: nil) else { return }
            activity = full
        }

        if activity.isDelta {
            for session in activity.sessions {
                runtimeActivities[session.sessionID] = session
            }
        } else {
            runtimeActivities = Dictionary(uniqueKeysWithValues: activity.sessions.map { ($0.sessionID, $0) })
        }
        activityCursor = supportsDelta ? activity.cursor : nil
        reconcileAttention(with: activity)

        // Record a reconnect baseline for every controller. Connected sockets remain
        // authoritative, preventing an older polling response from undoing a live
        // terminal event that arrived while this request was in flight.
        for (sessionID, controller) in controllers {
            if let remote = runtimeActivities[sessionID] {
                controller.applyRuntimeActivity(remote)
            }
        }

        // Reattach every live session, not only the selected one, so background
        // approvals and terminal events continue to flow after app restoration.
        for conversation in knownConversations.values where shouldRetainLiveChannel(sessionID: conversation.id) {
            let controller = controller(for: conversation)
            if let remote = runtimeActivities[conversation.id] {
                controller.applyRuntimeActivity(remote)
            }
            await controller.connect(to: conversation)
        }
        await enforceControllerLimit()
    }

    private func scheduleActivityRefresh() {
        activityRefreshTask?.cancel()
        activityRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            await self.refreshActivitySnapshot()
        }
    }

    private func startActivityMonitoring() {
        guard activityMonitoringTask == nil else { return }
        activityMonitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let hasLiveWork = self?.runtimeActivities.values.contains(where: {
                    ["accepted", "queued", "running", "resuming", "waiting_approval", "waiting_client_tool", "paused"].contains($0.state)
                }) else { return }
                try? await Task.sleep(for: hasLiveWork ? .seconds(3) : .seconds(20))
                guard !Task.isCancelled, let self else { return }
                await self.refreshActivitySnapshot()
            }
        }
    }

    public func stopActivityMonitoring() {
        activityRefreshTask?.cancel()
        activityRefreshTask = nil
        activityMonitoringTask?.cancel()
        activityMonitoringTask = nil
        resourceReconciliationTask?.cancel()
        resourceReconciliationTask = nil
    }

    private func reconcileAttention(with snapshot: RuntimeActivitySnapshot) {
        guard runtimeCapabilities.flags.contains(.sessionAttentionSnapshot) else {
            unreadTerminals = [:]
            return
        }

        if !attentionReadStore.hasEstablishedBaseline {
            // Upgrade safety: existing historical terminals become the initial
            // read baseline instead of turning every old conversation red.
            for conversation in knownConversations.values {
                let terminalSequence = runtimeActivities[conversation.id]?.latestTerminal?.sequence ?? 0
                attentionReadStore.setLastSeenTerminalSequence(terminalSequence, for: conversation.id)
                attentionReadStore.setLastNotifiedTerminalSequence(terminalSequence, for: conversation.id)
            }
            attentionReadStore.establishBaseline()
            unreadTerminals = [:]
        }

        let knownIDs = Set(knownConversations.keys)
        unreadTerminals = unreadTerminals.filter { knownIDs.contains($0.key) }

        for activity in snapshot.sessions {
            guard knownIDs.contains(activity.sessionID) else { continue }
            let sessionID = activity.sessionID

            if selectedSessionID == sessionID, let sequence = activity.lastSequence, sequence > 0 {
                attentionReadStore.setLastReadSequence(sequence, for: sessionID)
            }

            // A session first observed after the migration baseline is new work.
            if attentionReadStore.lastSeenTerminalSequence(for: sessionID) == nil {
                attentionReadStore.setLastSeenTerminalSequence(0, for: sessionID)
                attentionReadStore.setLastNotifiedTerminalSequence(0, for: sessionID)
            }

            if activity.pendingApprovalCount ?? 0 > 0, activity.lastSequence ?? 0 > 0 {
                let sequence = activity.lastSequence ?? 0
                let notified = attentionReadStore.lastNotifiedApprovalSequence(for: sessionID) ?? 0
                if sequence > notified {
                    attentionReadStore.setLastNotifiedApprovalSequence(sequence, for: sessionID)
                    if selectedSessionID != sessionID {
                        onAttentionEvent?(.approvalRequired(
                            sessionID: sessionID,
                            turnID: activity.effectiveActiveTurnID,
                            pendingCount: activity.pendingApprovalCount ?? 0,
                            sequence: sequence
                        ))
                    }
                }
            }

            guard let terminal = activity.latestTerminal,
                  terminal.sequence > 0,
                  let outcome = terminalOutcome(for: terminal.kind)
            else { continue }

            let attention = ConversationTerminalAttention(
                sessionID: sessionID,
                turnID: terminal.turnID,
                outcome: outcome,
                sequence: terminal.sequence,
                occurredAt: terminal.at
            )

            if selectedSessionID == sessionID {
                attentionReadStore.setLastSeenTerminalSequence(terminal.sequence, for: sessionID)
                unreadTerminals.removeValue(forKey: sessionID)
            } else if terminal.sequence > (attentionReadStore.lastSeenTerminalSequence(for: sessionID) ?? 0) {
                unreadTerminals[sessionID] = attention
            } else {
                unreadTerminals.removeValue(forKey: sessionID)
            }

            let notified = attentionReadStore.lastNotifiedTerminalSequence(for: sessionID) ?? 0
            if terminal.sequence > notified {
                attentionReadStore.setLastNotifiedTerminalSequence(terminal.sequence, for: sessionID)
                if selectedSessionID != sessionID {
                    onAttentionEvent?(.turnCompleted(attention))
                }
            }
        }
    }

    private func terminalOutcome(for kind: String) -> ConversationTerminalOutcome? {
        switch kind {
        case "turn_finished": return .succeeded
        case "turn_failed": return .failed
        case "turn_cancelled": return .cancelled
        default: return nil
        }
    }

    private func activity(for outcome: ConversationTerminalOutcome) -> ConversationActivityState {
        switch outcome {
        case .succeeded: return .succeeded
        case .failed: return .failed
        case .cancelled: return .cancelled
        }
    }

    private func isActiveState(_ state: String?) -> Bool {
        guard let state else { return false }
        return ["accepted", "queued", "running", "resuming", "waiting_approval", "waiting_client_tool", "paused"].contains(state)
    }

    public var pendingApprovals: [PendingConversationApproval] {
        controllers.values.compactMap { controller -> PendingConversationApproval? in
            guard let conversation = controller.conversation else { return nil }
            let name = conversation.name ?? conversation.id
            if let request = controller.snapshot.pendingAskUser {
                return PendingConversationApproval(
                    sessionID: conversation.id,
                    requestID: request.id,
                    conversationName: name,
                    kind: .askUser
                )
            }
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
            controllerLastAccess.removeValue(forKey: id)
        }
    }

    /// Remove all client-side state for a conversation after Runtime confirms
    /// permanent deletion. This is intentionally never called for archive.
    public func removeDeletedConversation(sessionID: String) async {
        if let controller = controllers.removeValue(forKey: sessionID) {
            await controller.disconnect()
        }
        controllerLastAccess.removeValue(forKey: sessionID)
        runtimeActivities.removeValue(forKey: sessionID)
        unreadTerminals.removeValue(forKey: sessionID)
        knownConversations.removeValue(forKey: sessionID)
        if selectedSessionID == sessionID {
            selectedSessionID = nil
        }
    }

    /// Archived conversations remain durable on the Runtime but must not retain a
    /// live control channel. Their history is reopened read-only on demand.
    public func detachArchivedConversation(sessionID: String) async {
        if let controller = controllers.removeValue(forKey: sessionID) {
            await controller.disconnect()
        }
        controllerLastAccess.removeValue(forKey: sessionID)
        runtimeActivities.removeValue(forKey: sessionID)
        unreadTerminals.removeValue(forKey: sessionID)
        knownConversations.removeValue(forKey: sessionID)
        if selectedSessionID == sessionID {
            selectedSessionID = nil
        }
    }

    /// Enforce the Runtime connection limit as an LRU soft cap. Selected and
    /// non-idle controllers are never evicted; if live work itself exceeds the
    /// cap, correctness wins and the temporary excess is retained.
    public func enforceControllerLimit() async {
        let advertised = runtimeCapabilities.limits?.maxConnectedSessions ?? 0
        let limit = advertised > 0 ? advertised : Self.defaultMaxRetainedControllers
        guard controllers.count > limit else { return }

        let excess = controllers.count - limit
        let candidates = controllers.compactMap { id, controller -> (String, ConversationViewModel, UInt64)? in
            guard id != selectedSessionID, activity(for: id) == .idle else { return nil }
            return (id, controller, controllerLastAccess[id] ?? 0)
        }
        .sorted { $0.2 < $1.2 }

        for (id, controller, _) in candidates.prefix(excess) {
            await controller.disconnect()
            controllers.removeValue(forKey: id)
            controllerLastAccess.removeValue(forKey: id)
        }
    }

    public func disconnectAll() async {
        stopActivityMonitoring()
        let retained = controllers.values
        for controller in retained {
            await controller.disconnect()
        }
        controllers.removeAll()
        controllerLastAccess.removeAll()
        runtimeActivities.removeAll()
        activityCursor = nil
    }

    private func touchController(sessionID: String) {
        controllerAccessSequence &+= 1
        controllerLastAccess[sessionID] = controllerAccessSequence
    }

    private func scheduleControllerLimitEnforcement() {
        resourceReconciliationTask?.cancel()
        resourceReconciliationTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            await self.enforceControllerLimit()
        }
    }
}
