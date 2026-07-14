//
//  ManagedWorktree.swift
//  AgentKit
//
//  Runtime-owned managed worktree protocol models.
//

import Foundation

public enum ManagedWorktreeBaseRef: String, Codable, Sendable, Equatable, CaseIterable {
    /// Create from the source workspace's current committed HEAD.
    case head
    /// Create from origin/HEAD. Runtime does not implicitly fetch in v1.
    case fresh
}

public struct ManagedWorktreeCreateRequest: Codable, Sendable, Equatable {
    public let managed: Bool
    public let suggestedName: String?
    public let baseRef: ManagedWorktreeBaseRef?

    enum CodingKeys: String, CodingKey {
        case managed
        case suggestedName = "suggested_name"
        case baseRef = "base_ref"
    }

    public init(
        managed: Bool = true,
        suggestedName: String? = nil,
        baseRef: ManagedWorktreeBaseRef? = .head
    ) {
        self.managed = managed
        self.suggestedName = suggestedName
        self.baseRef = baseRef
    }
}

/// Runtime metadata returned by conversation list/detail/activity endpoints.
///
/// State and baseRef intentionally remain strings so a newer Runtime can add a
/// lifecycle value without making an older AgentKit fail the entire list decode.
public struct ManagedWorktreeMetadata: Codable, Sendable, Equatable, Hashable {
    public let managed: Bool
    public let name: String?
    public let branch: String?
    public let baseRef: String?
    public let state: String
    public let needsRebind: Bool

    enum CodingKeys: String, CodingKey {
        case managed, name, branch, state
        case baseRef = "base_ref"
        case needsRebind = "needs_rebind"
    }

    public init(
        managed: Bool,
        name: String? = nil,
        branch: String? = nil,
        baseRef: String? = nil,
        state: String,
        needsRebind: Bool = false
    ) {
        self.managed = managed
        self.name = name
        self.branch = branch
        self.baseRef = baseRef
        self.state = state
        self.needsRebind = needsRebind
    }

    public var isReady: Bool { state == "ready" && !needsRebind }

    public var requiresAttention: Bool {
        needsRebind || ["missing", "failed", "remove_failed"].contains(state)
    }
}

public struct RuntimeAPIWarning: Codable, Sendable, Equatable, Hashable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}
