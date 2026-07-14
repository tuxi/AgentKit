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

    func lastReadSequence(for sessionID: String) -> Int64?
    func setLastReadSequence(_ sequence: Int64, for sessionID: String)
}

public extension ConversationAttentionReadStore {
    func lastReadSequence(for sessionID: String) -> Int64? {
        lastSeenTerminalSequence(for: sessionID)
    }

    func setLastReadSequence(_ sequence: Int64, for sessionID: String) {
        setLastSeenTerminalSequence(sequence, for: sessionID)
    }
}

/// Default attention adapter backed by the unified local-state database. Reads
/// fall back to the previous UserDefaults store once, so an upgrade cannot emit
/// every historical terminal as a new notification.
public final class ConversationLocalStateAttentionReadStore: ConversationAttentionReadStore, @unchecked Sendable {
    public static let shared = ConversationLocalStateAttentionReadStore(
        localStateStore: SQLiteConversationLocalStateStore.shared
    )

    private enum Cursor {
        case seenTerminal
        case notifiedTerminal
        case notifiedApproval
    }

    private let localStateStore: any ConversationLocalStateStore
    private let legacyStore: UserDefaultsConversationAttentionReadStore?

    public init(
        localStateStore: any ConversationLocalStateStore,
        legacyStore: UserDefaultsConversationAttentionReadStore? = .shared
    ) {
        self.localStateStore = localStateStore
        self.legacyStore = legacyStore
    }

    public var hasEstablishedBaseline: Bool {
        if localStateStore.hasEstablishedAttentionBaseline { return true }
        guard legacyStore?.hasEstablishedBaseline == true else { return false }
        try? localStateStore.establishAttentionBaseline()
        return true
    }

    public func establishBaseline() {
        try? localStateStore.establishAttentionBaseline()
    }

    public func lastSeenTerminalSequence(for sessionID: String) -> Int64? {
        cursor(.seenTerminal, sessionID: sessionID)
    }

    public func setLastSeenTerminalSequence(_ sequence: Int64, for sessionID: String) {
        setCursor(.seenTerminal, sequence: sequence, sessionID: sessionID)
    }

    public func lastNotifiedTerminalSequence(for sessionID: String) -> Int64? {
        cursor(.notifiedTerminal, sessionID: sessionID)
    }

    public func setLastNotifiedTerminalSequence(_ sequence: Int64, for sessionID: String) {
        setCursor(.notifiedTerminal, sequence: sequence, sessionID: sessionID)
    }

    public func lastNotifiedApprovalSequence(for sessionID: String) -> Int64? {
        cursor(.notifiedApproval, sessionID: sessionID)
    }

    public func setLastNotifiedApprovalSequence(_ sequence: Int64, for sessionID: String) {
        setCursor(.notifiedApproval, sequence: sequence, sessionID: sessionID)
    }

    public func lastReadSequence(for sessionID: String) -> Int64? {
        (try? localStateStore.state(for: .session(sessionID))?.lastReadSequence) ?? nil
    }

    public func setLastReadSequence(_ sequence: Int64, for sessionID: String) {
        try? localStateStore.updateState(for: .session(sessionID)) { state in
            state.lastReadSequence = max(state.lastReadSequence, sequence)
        }
    }

    private func cursor(_ cursor: Cursor, sessionID: String) -> Int64? {
        let state = try? localStateStore.state(for: .session(sessionID))
        let value: Int64
        switch cursor {
        case .seenTerminal: value = state?.lastSeenTerminalSequence ?? 0
        case .notifiedTerminal: value = state?.lastNotifiedTerminalSequence ?? 0
        case .notifiedApproval: value = state?.lastNotifiedApprovalSequence ?? 0
        }
        if value > 0 { return value }

        let legacy: Int64?
        switch cursor {
        case .seenTerminal: legacy = legacyStore?.lastSeenTerminalSequence(for: sessionID)
        case .notifiedTerminal: legacy = legacyStore?.lastNotifiedTerminalSequence(for: sessionID)
        case .notifiedApproval: legacy = legacyStore?.lastNotifiedApprovalSequence(for: sessionID)
        }
        if let legacy {
            setCursor(cursor, sequence: legacy, sessionID: sessionID)
            return legacy
        }
        return state == nil ? nil : 0
    }

    private func setCursor(_ cursor: Cursor, sequence: Int64, sessionID: String) {
        try? localStateStore.updateState(for: .session(sessionID)) { state in
            switch cursor {
            case .seenTerminal:
                state.lastSeenTerminalSequence = max(state.lastSeenTerminalSequence, sequence)
                state.lastReadSequence = max(state.lastReadSequence, sequence)
            case .notifiedTerminal:
                state.lastNotifiedTerminalSequence = max(state.lastNotifiedTerminalSequence, sequence)
            case .notifiedApproval:
                state.lastNotifiedApprovalSequence = max(state.lastNotifiedApprovalSequence, sequence)
            }
        }
    }
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
