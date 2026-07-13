//
//  ConversationAttention.swift
//  AgentKit
//
//  Client-owned read state and host-facing attention events. Runtime publishes
//  durable facts; AgentKit decides whether those facts still need user attention.
//

import Foundation

public enum ConversationTerminalOutcome: String, Sendable, Equatable {
    case succeeded
    case failed
    case cancelled
}

public struct ConversationTerminalAttention: Sendable, Equatable, Identifiable {
    public let sessionID: String
    public let turnID: String
    public let outcome: ConversationTerminalOutcome
    public let sequence: Int64
    public let occurredAt: String?

    public var id: String { "\(sessionID):terminal:\(sequence)" }

    public init(
        sessionID: String,
        turnID: String,
        outcome: ConversationTerminalOutcome,
        sequence: Int64,
        occurredAt: String? = nil
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.outcome = outcome
        self.sequence = sequence
        self.occurredAt = occurredAt
    }
}

/// Emitted once for each newly observed attention fact. The host may translate
/// these values into local notifications; AgentKit never requests notification
/// permission itself.
public enum ConversationAttentionEvent: Sendable, Equatable {
    case approvalRequired(
        sessionID: String,
        turnID: String?,
        pendingCount: Int,
        sequence: Int64
    )
    case turnCompleted(ConversationTerminalAttention)
}

/// Persistence boundary for GUI-owned read and notification cursors.
public protocol ConversationAttentionReadStore: Sendable {
    var hasEstablishedBaseline: Bool { get }
    func establishBaseline()

    func lastSeenTerminalSequence(for sessionID: String) -> Int64?
    func setLastSeenTerminalSequence(_ sequence: Int64, for sessionID: String)

    func lastNotifiedTerminalSequence(for sessionID: String) -> Int64?
    func setLastNotifiedTerminalSequence(_ sequence: Int64, for sessionID: String)

    func lastNotifiedApprovalSequence(for sessionID: String) -> Int64?
    func setLastNotifiedApprovalSequence(_ sequence: Int64, for sessionID: String)
}

/// Default local persistence. Session IDs are server-assigned and stable across
/// Runtime restarts, so they are safe keys for client-owned attention cursors.
public final class UserDefaultsConversationAttentionReadStore: ConversationAttentionReadStore, @unchecked Sendable {
    public static let shared = UserDefaultsConversationAttentionReadStore()

    private let defaults: UserDefaults
    private let namespace: String
    private let lock = NSLock()

    public init(
        defaults: UserDefaults = .standard,
        namespace: String = "AgentKit.ConversationAttention.v1"
    ) {
        self.defaults = defaults
        self.namespace = namespace
    }

    public var hasEstablishedBaseline: Bool {
        lock.withLock { defaults.bool(forKey: key("baseline")) }
    }

    public func establishBaseline() {
        lock.withLock { defaults.set(true, forKey: key("baseline")) }
    }

    public func lastSeenTerminalSequence(for sessionID: String) -> Int64? {
        value(in: "seen-terminal", sessionID: sessionID)
    }

    public func setLastSeenTerminalSequence(_ sequence: Int64, for sessionID: String) {
        setValue(sequence, in: "seen-terminal", sessionID: sessionID)
    }

    public func lastNotifiedTerminalSequence(for sessionID: String) -> Int64? {
        value(in: "notified-terminal", sessionID: sessionID)
    }

    public func setLastNotifiedTerminalSequence(_ sequence: Int64, for sessionID: String) {
        setValue(sequence, in: "notified-terminal", sessionID: sessionID)
    }

    public func lastNotifiedApprovalSequence(for sessionID: String) -> Int64? {
        value(in: "notified-approval", sessionID: sessionID)
    }

    public func setLastNotifiedApprovalSequence(_ sequence: Int64, for sessionID: String) {
        setValue(sequence, in: "notified-approval", sessionID: sessionID)
    }

    private func value(in bucket: String, sessionID: String) -> Int64? {
        lock.withLock {
            let values = defaults.dictionary(forKey: key(bucket)) ?? [:]
            return (values[sessionID] as? NSNumber)?.int64Value
        }
    }

    private func setValue(_ value: Int64, in bucket: String, sessionID: String) {
        lock.withLock {
            var values = defaults.dictionary(forKey: key(bucket)) ?? [:]
            values[sessionID] = NSNumber(value: value)
            defaults.set(values, forKey: key(bucket))
        }
    }

    private func key(_ suffix: String) -> String { "\(namespace).\(suffix)" }
}
