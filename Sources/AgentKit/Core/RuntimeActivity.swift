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

    private struct CapabilityKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
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

    /// Accept both the versioned design shape and Code-Agent's initial compact
    /// shape, where schema metadata is omitted and limits live beside flags.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(String.self, forKey: .schema)
            ?? "runtime-capabilities/v1"
        protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1

        let values = try container.nestedContainer(
            keyedBy: CapabilityKey.self,
            forKey: .capabilities
        )
        var decodedCapabilities: [String: Bool] = [:]
        for key in values.allKeys {
            if let value = try? values.decode(Bool.self, forKey: key) {
                decodedCapabilities[key.stringValue] = value
            }
        }
        capabilities = decodedCapabilities

        if let explicitLimits = try container.decodeIfPresent(RuntimeLimits.self, forKey: .limits) {
            limits = explicitLimits
        } else {
            let concurrentKey = CapabilityKey(stringValue: "max_concurrent_turns")!
            let connectedKey = CapabilityKey(stringValue: "max_connected_sessions")!
            let maxConcurrentTurns = try values.decodeIfPresent(Int.self, forKey: concurrentKey)
            let maxConnectedSessions = try values.decodeIfPresent(Int.self, forKey: connectedKey)
            if maxConcurrentTurns != nil || maxConnectedSessions != nil {
                limits = RuntimeLimits(
                    maxConcurrentTurns: maxConcurrentTurns,
                    maxConnectedSessions: maxConnectedSessions
                )
            } else {
                limits = nil
            }
        }
    }

    public var flags: AgentCapabilityFlags {
        guard schema == "runtime-capabilities/v1", protocolVersion == 1 else { return .default }
        var flags = AgentCapabilityFlags.default
        if capabilities["multi_session_execution_v1"] == true { flags.insert(.multiSessionExecution) }
        if capabilities["session_scoped_client_tools_v1"] == true { flags.insert(.sessionScopedClientTools) }
        if capabilities["activity_snapshot_v1"] == true { flags.insert(.activitySnapshot) }
        if capabilities["workspace_execution_policy_v1"] == true { flags.insert(.workspaceExecutionPolicy) }
        if capabilities["session_attention_snapshot_v1"] == true { flags.insert(.sessionAttentionSnapshot) }
        if capabilities["session_attention_delta_v1"] == true { flags.insert(.sessionAttentionDelta) }
        if capabilities["managed_worktree_v1"] == true { flags.insert(.managedWorktree) }
        return flags
    }

    public var allowsMultiSessionExecution: Bool {
        let value = flags
        return value.contains(.multiSessionExecution)
            && value.contains(.sessionScopedClientTools)
            && value.contains(.workspaceExecutionPolicy)
    }

    public static let legacy = RuntimeCapabilitySnapshot(schema: "legacy", protocolVersion: 0)

    public var supportsManagedWorktree: Bool {
        flags.contains(.managedWorktree) && flags.contains(.workspaceExecutionPolicy)
    }
}

public struct RuntimeTerminalActivity: Codable, Sendable, Equatable {
    public let turnID: String
    public let kind: String
    public let sequence: Int64
    public let at: String?

    enum CodingKeys: String, CodingKey {
        case kind, sequence, at
        case turnID = "turn_id"
    }

    public init(turnID: String, kind: String, sequence: Int64, at: String? = nil) {
        self.turnID = turnID
        self.kind = kind
        self.sequence = sequence
        self.at = at
    }

}

public struct RuntimeSessionActivity: Codable, Sendable, Equatable, Identifiable {
    public let sessionID: String
    public let turnID: String?
    public let activeTurnID: String?
    public let state: String
    public let lastSequence: Int64?
    /// Nil means the Runtime did not publish this broker detail. It must not be
    /// interpreted as a known zero while the broker contract is still disabled.
    public let pendingApprovalCount: Int?
    public let pendingClientToolCount: Int?
    public let queuePosition: Int?
    public let latestTerminal: RuntimeTerminalActivity?
    public let updatedAt: String?
    public let executionPolicy: String?
    public let workspaceID: String?
    public let baseWorkspaceID: String?
    public let worktree: ManagedWorktreeMetadata?

    public var id: String { sessionID }
    public var effectiveActiveTurnID: String? { activeTurnID ?? turnID }

    enum CodingKeys: String, CodingKey {
        case state
        case sessionID = "session_id"
        case turnID = "turn_id"
        case activeTurnID = "active_turn_id"
        case lastSequence = "last_sequence"
        case pendingApprovalCount = "pending_approval_count"
        case pendingClientToolCount = "pending_client_tool_count"
        case queuePosition = "queue_position"
        case latestTerminal = "latest_terminal"
        case updatedAt = "updated_at"
        case executionPolicy = "execution_policy"
        case workspaceID = "workspace_id"
        case baseWorkspaceID = "base_workspace_id"
        case worktree
    }

    public init(
        sessionID: String,
        turnID: String? = nil,
        activeTurnID: String? = nil,
        state: String,
        lastSequence: Int64? = nil,
        pendingApprovalCount: Int? = nil,
        pendingClientToolCount: Int? = nil,
        queuePosition: Int? = nil,
        latestTerminal: RuntimeTerminalActivity? = nil,
        updatedAt: String? = nil,
        executionPolicy: String? = nil,
        workspaceID: String? = nil,
        baseWorkspaceID: String? = nil,
        worktree: ManagedWorktreeMetadata? = nil
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.activeTurnID = activeTurnID ?? turnID
        self.state = state
        self.lastSequence = lastSequence
        self.pendingApprovalCount = pendingApprovalCount
        self.pendingClientToolCount = pendingClientToolCount
        self.queuePosition = queuePosition
        self.latestTerminal = latestTerminal
        self.updatedAt = updatedAt
        self.executionPolicy = executionPolicy
        self.workspaceID = workspaceID
        self.baseWorkspaceID = baseWorkspaceID
        self.worktree = worktree
    }
}

public struct RuntimeActivitySnapshot: Codable, Sendable, Equatable {
    public let generatedAt: String?
    public let cursor: Int64?
    public let isDelta: Bool
    public let sessions: [RuntimeSessionActivity]

    enum CodingKeys: String, CodingKey {
        case sessions, cursor
        case isDelta = "is_delta"
        case generatedAt = "generated_at"
    }

    public init(
        generatedAt: String? = nil,
        cursor: Int64? = nil,
        isDelta: Bool = false,
        sessions: [RuntimeSessionActivity]
    ) {
        self.generatedAt = generatedAt
        self.cursor = cursor
        self.isDelta = isDelta
        self.sessions = sessions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt)
        cursor = try container.decodeIfPresent(Int64.self, forKey: .cursor)
        isDelta = try container.decodeIfPresent(Bool.self, forKey: .isDelta) ?? false
        sessions = try container.decode([RuntimeSessionActivity].self, forKey: .sessions)
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
