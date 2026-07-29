//
//  RuntimeProviderConfigurationApplyQueue.swift
//  AgentKit
//
//  Coalesces structural Provider changes until every Runtime turn is idle.
//

import Foundation

public struct StagedRuntimeProviderConfiguration: Sendable {
    public let revision: UInt64
    public let configuration: GeneratedRuntimeProviderConfiguration

    public init(revision: UInt64, configuration: GeneratedRuntimeProviderConfiguration) {
        self.revision = revision
        self.configuration = configuration
    }
}

public actor RuntimeProviderConfigurationApplyQueue {
    private var nextRevision: UInt64 = 1
    private var pending: StagedRuntimeProviderConfiguration?

    public init() {}

    /// Stages the newest structural configuration. Multiple edits made while a
    /// turn is active coalesce into one eventual Runtime restart.
    @discardableResult
    public func stage(_ configuration: GeneratedRuntimeProviderConfiguration) -> UInt64 {
        let revision = nextRevision
        nextRevision &+= 1
        pending = StagedRuntimeProviderConfiguration(
            revision: revision,
            configuration: configuration
        )
        return revision
    }

    public func pendingRevision() -> UInt64? {
        pending?.revision
    }

    /// Returns the latest staged configuration only when no turn, queued turn,
    /// approval, or client tool is active. The item remains pending until the
    /// host confirms that stop/configure/start succeeded.
    public func configurationIfRuntimeIdle(
        _ snapshot: RuntimeActivitySnapshot
    ) -> StagedRuntimeProviderConfiguration? {
        snapshot.hasActiveRuntimeWork ? nil : pending
    }

    public func markApplied(revision: UInt64) {
        guard pending?.revision == revision else { return }
        pending = nil
    }
}

public extension RuntimeActivitySnapshot {
    var hasActiveRuntimeWork: Bool {
        sessions.contains { activity in
            activity.effectiveActiveTurnID != nil
                || activity.queuePosition != nil
                || (activity.pendingApprovalCount ?? 0) > 0
                || (activity.pendingClientToolCount ?? 0) > 0
        }
    }
}
