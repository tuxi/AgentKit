//
//  RuntimeSessionChannel.swift
//  AgentKit
//
//  A session-bound runtime control plane. Selection never changes its routing.
//

import Foundation

/// A bidirectional runtime channel permanently bound to one server-owned session.
///
/// Unlike the legacy methods on `RuntimeClient`, every operation on this value has an
/// unambiguous target. One channel may be retained for every active conversation.
public protocol RuntimeSessionChannel: Sendable {
    var sessionID: String { get }
    var isConnected: Bool { get }

    func connect(since: Int) async throws -> AsyncStream<AgentEvent>
    func send(input: AgentInput) async
    func registerTools(_ tools: [ClientToolInfo]) async
    func sendApproval(id: String, approved: Bool) async
    func sendApproval(id: String, decision: String, scope: String?) async
    func sendPlanApproval(id: String, approved: Bool) async
    func cancelTurn() async
    func disconnect() async
    func capabilities() async -> AgentCapabilityFlags
}

/// Compatibility channel for third-party `RuntimeClient` implementations that have
/// not adopted session-bound channels yet. It deliberately preserves the legacy
/// single-binding behavior; the conversation supervisor serializes new turns when the
/// runtime does not advertise multi-session execution.
final class LegacyRuntimeSessionChannel: RuntimeSessionChannel, @unchecked Sendable {
    let sessionID: String
    private let client: any RuntimeClient
    private var connected = false

    init(sessionID: String, client: any RuntimeClient) {
        self.sessionID = sessionID
        self.client = client
    }

    var isConnected: Bool { connected }

    func connect(since: Int) async throws -> AsyncStream<AgentEvent> {
        let stream = try await client.connect(conversationID: sessionID, since: since)
        connected = true
        return stream
    }

    func send(input: AgentInput) async { await client.send(input: input) }
    func registerTools(_ tools: [ClientToolInfo]) async { await client.registerTools(tools) }
    func sendApproval(id: String, approved: Bool) async {
        await client.sendApproval(id: id, approved: approved)
    }
    func sendApproval(id: String, decision: String, scope: String?) async {
        await client.sendApproval(id: id, decision: decision, scope: scope)
    }
    func sendPlanApproval(id: String, approved: Bool) async {
        await client.sendPlanApproval(id: id, approved: approved)
    }
    func cancelTurn() async { await client.cancelTurn() }

    func disconnect() async {
        await client.disconnect()
        connected = false
    }

    func capabilities() async -> AgentCapabilityFlags { .default }
}

