//
//  ConversationTurnCoordinator.swift
//  AgentKit
//
//  Client-side safety gate used until the runtime advertises multi-session safety.
//

import Foundation

/// Serializes turn-starting inputs across sessions for legacy runtimes. Control frames,
/// approvals and client-tool results never pass through this gate.
public actor ConversationTurnCoordinator {
    private var activeSessions: Set<String> = []
    private var queue: [UUID] = []
    private var ticketSessions: [UUID: String] = [:]

    public init() {}

    public func enqueue(sessionID: String) -> UUID {
        let ticket = UUID()
        queue.append(ticket)
        ticketSessions[ticket] = sessionID
        return ticket
    }

    /// Non-blocking FIFO acquisition. Callers may poll from a cancellable task.
    public func tryAcquire(
        ticket: UUID,
        sessionID: String,
        allowsConcurrentSessions: Bool
    ) -> Bool {
        guard ticketSessions[ticket] == sessionID else { return false }

        let canRun: Bool
        if activeSessions.contains(sessionID) {
            // Runtime invariant: one active turn per session, regardless of global
            // multi-session capability.
            canRun = false
        } else if allowsConcurrentSessions {
            canRun = true
        } else {
            canRun = activeSessions.isEmpty
        }
        guard canRun, queue.first == ticket else { return false }

        queue.removeFirst()
        ticketSessions.removeValue(forKey: ticket)
        activeSessions.insert(sessionID)
        return true
    }

    public func cancel(ticket: UUID) {
        queue.removeAll { $0 == ticket }
        ticketSessions.removeValue(forKey: ticket)
    }

    public func markActive(sessionID: String) {
        activeSessions.insert(sessionID)
    }

    public func release(sessionID: String) {
        activeSessions.remove(sessionID)
    }

    public func isQueued(ticket: UUID) -> Bool {
        ticketSessions[ticket] != nil
    }
}
