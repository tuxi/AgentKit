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

/// Generates a prompt-independent, ASCII-only readability hint. Runtime remains
/// authoritative and appends its stable reservation suffix before using the value
/// as either a checkout directory or Git ref.
enum ManagedWorktreeSuggestedNameGenerator {
    private static let adjectives = [
        "agile", "calm", "curious", "eager", "fervent", "focused",
        "gentle", "lucid", "nimble", "patient", "steady", "vivid",
    ]
    private static let surnames = [
        "babbage", "curie", "darwin", "einstein", "faraday", "hopper",
        "lovelace", "mirzakhani", "newton", "noether", "ramanujan", "turing",
    ]

    static func make() -> String {
        let adjective = adjectives.randomElement() ?? "steady"
        let surname = surnames.randomElement() ?? "turing"
        return "\(adjective)-\(surname)"
    }
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        managed = try container.decode(Bool.self, forKey: .managed)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        baseRef = try container.decodeIfPresent(String.self, forKey: .baseRef)
        state = try container.decode(String.self, forKey: .state)
        // Runtime omits false values (`omitempty`). Missing therefore means the
        // checkout is currently bound, not a malformed response.
        needsRebind = try container.decodeIfPresent(Bool.self, forKey: .needsRebind) ?? false
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

public struct ManagedWorktreeRemoveRequest: Codable, Sendable, Equatable {
    public let requestID: String
    public let force: Bool

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case force
    }

    public init(requestID: String, force: Bool = false) {
        self.requestID = requestID
        self.force = force
    }
}

public struct ManagedWorktreeDirtySummary: Codable, Sendable, Equatable {
    public let modifiedFiles: Int
    public let untrackedFiles: Int
    public let newCommits: Int

    enum CodingKeys: String, CodingKey {
        case modifiedFiles = "modified_files"
        case untrackedFiles = "untracked_files"
        case newCommits = "new_commits"
    }

    public init(modifiedFiles: Int = 0, untrackedFiles: Int = 0, newCommits: Int = 0) {
        self.modifiedFiles = modifiedFiles
        self.untrackedFiles = untrackedFiles
        self.newCommits = newCommits
    }

    public var hasRisk: Bool {
        modifiedFiles > 0 || untrackedFiles > 0 || newCommits > 0
    }
}

public struct ManagedWorktreeRemoveResponse: Codable, Sendable, Equatable {
    public let sessionID: String
    public let worktree: ManagedWorktreeMetadata

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case worktree
    }

    public init(sessionID: String, worktree: ManagedWorktreeMetadata) {
        self.sessionID = sessionID
        self.worktree = worktree
    }
}

public struct ManagedWorktreeRemovalError: Error, Sendable, Equatable, LocalizedError {
    public let code: String
    public let message: String
    public let sessionID: String?
    public let summary: ManagedWorktreeDirtySummary?

    public init(
        code: String,
        message: String,
        sessionID: String? = nil,
        summary: ManagedWorktreeDirtySummary? = nil
    ) {
        self.code = code
        self.message = message
        self.sessionID = sessionID
        self.summary = summary
    }

    public var errorDescription: String? { message }
    public var isDirtyConflict: Bool { code == "worktree_dirty" }
}

struct ManagedWorktreeErrorPayload: Codable, Sendable, Equatable {
    let code: String
    let message: String
    let sessionID: String?
    let summary: ManagedWorktreeDirtySummary?

    enum CodingKeys: String, CodingKey {
        case code, message, summary
        case sessionID = "session_id"
    }
}

public enum ConversationWorktreeDisposition: Sendable, Equatable {
    /// Delete only Runtime conversation state. The checkout and branch remain.
    case keep
    /// Remove the checkout first, then delete conversation state.
    case remove
}

public enum ConversationDeletionError: Error, Sendable, Equatable, LocalizedError {
    case active(String)

    public var errorDescription: String? {
        switch self {
        case .active(let state):
            return "任务当前处于\(state)状态，请先等待结束或取消后再删除。"
        }
    }
}
