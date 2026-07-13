//
//  RuntimeActivity.swift
//  AgentKit
//
//  Versioned runtime-wide capability and activity snapshots.
//

import Foundation

public struct RuntimeLimits: Codable, Sendable, Equatable {
    public let maxConcurrentTurns: Int?
    public let maxConnectedSessions: Int?

    enum CodingKeys: String, CodingKey {
        case maxConcurrentTurns = "max_concurrent_turns"
        case maxConnectedSessions = "max_connected_sessions"
    }

    public init(maxConcurrentTurns: Int? = nil, maxConnectedSessions: Int? = nil) {
        self.maxConcurrentTurns = maxConcurrentTurns
        self.maxConnectedSessions = maxConnectedSessions
    }
}

public struct RuntimeCapabilitySnapshot: Codable, Sendable, Equatable {
    public let schema: String
    public let protocolVersion: Int
    public let capabilities: [String: Bool]
    public let limits: RuntimeLimits?

    enum CodingKeys: String, CodingKey {
        case schema, capabilities, limits
        case protocolVersion = "protocol_version"
    }

    public init(
        schema: String = "runtime-capabilities/v1",
        protocolVersion: Int = 1,
        capabilities: [String: Bool] = [:],
        limits: RuntimeLimits? = nil
    ) {
        self.schema = schema
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.limits = limits
    }

    public var flags: AgentCapabilityFlags {
        guard schema == "runtime-capabilities/v1", protocolVersion == 1 else { return .default }
        var flags = AgentCapabilityFlags.default
        if capabilities["multi_session_execution_v1"] == true { flags.insert(.multiSessionExecution) }
        if capabilities["session_scoped_client_tools_v1"] == true { flags.insert(.sessionScopedClientTools) }
        if capabilities["activity_snapshot_v1"] == true { flags.insert(.activitySnapshot) }
        if capabilities["workspace_execution_policy_v1"] == true { flags.insert(.workspaceExecutionPolicy) }
        return flags
    }

    public var allowsMultiSessionExecution: Bool {
        let value = flags
        return value.contains(.multiSessionExecution)
            && value.contains(.sessionScopedClientTools)
            && value.contains(.workspaceExecutionPolicy)
    }

    public static let legacy = RuntimeCapabilitySnapshot(schema: "legacy", protocolVersion: 0)
}

public struct RuntimeSessionActivity: Codable, Sendable, Equatable, Identifiable {
    public let sessionID: String
    public let turnID: String?
    public let state: String
    public let lastSequence: Int?
    public let pendingApprovalCount: Int
    public let pendingClientToolCount: Int
    public let queuePosition: Int?
    public let updatedAt: String?

    public var id: String { sessionID }

    enum CodingKeys: String, CodingKey {
        case state
        case sessionID = "session_id"
        case turnID = "turn_id"
        case lastSequence = "last_sequence"
        case pendingApprovalCount = "pending_approval_count"
        case pendingClientToolCount = "pending_client_tool_count"
        case queuePosition = "queue_position"
        case updatedAt = "updated_at"
    }

    public init(
        sessionID: String,
        turnID: String? = nil,
        state: String,
        lastSequence: Int? = nil,
        pendingApprovalCount: Int = 0,
        pendingClientToolCount: Int = 0,
        queuePosition: Int? = nil,
        updatedAt: String? = nil
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.state = state
        self.lastSequence = lastSequence
        self.pendingApprovalCount = pendingApprovalCount
        self.pendingClientToolCount = pendingClientToolCount
        self.queuePosition = queuePosition
        self.updatedAt = updatedAt
    }
}

public struct RuntimeActivitySnapshot: Codable, Sendable, Equatable {
    public let sessions: [RuntimeSessionActivity]

    public init(sessions: [RuntimeSessionActivity]) {
        self.sessions = sessions
    }
}

/// Shared by all controllers so runtime-wide concurrency permission cannot differ by
/// whichever session happened to finish its WebSocket hello first.
public actor RuntimeCapabilityRegistry {
    private var snapshot: RuntimeCapabilitySnapshot = .legacy

    public init() {}
    public func update(_ snapshot: RuntimeCapabilitySnapshot) { self.snapshot = snapshot }
    public func current() -> RuntimeCapabilitySnapshot { snapshot }
}

