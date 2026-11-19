import Foundation

public struct TextSupplementRequest: Codable, Sendable, Equatable {
    public let requestID: String
    public let expectedTurnID: String
    public let text: String
    public init(requestID: String = UUID().uuidString, expectedTurnID: String, text: String) {
        self.requestID = requestID; self.expectedTurnID = expectedTurnID; self.text = text
    }
    enum CodingKeys: String, CodingKey { case requestID = "request_id", expectedTurnID = "expected_turn_id", text }
}
public struct TextSupplementReceipt: Codable, Sendable, Equatable {
    public struct Input: Codable, Sendable, Equatable {
        public let sessionID: String
        public let requestID: String
        public let expectedTurnID: String
        public let text: String
        enum CodingKeys: String, CodingKey { case sessionID = "session_id", requestID = "request_id", expectedTurnID = "expected_turn_id", text }
    }
    public let input: Input
    public let sequence: Int64
    /// Open vocabulary: an unknown server state is never treated as success.
    public let state: String
}
public struct SupplementApplicationReceipt: Codable, Sendable, Equatable {
    public let requestID: String
    public let turnID: String
    public let sequence: Int64
    public let appliedAt: String
    public let text: String?
    public init(requestID: String, turnID: String, sequence: Int64, appliedAt: String, text: String? = nil) {
        self.requestID = requestID
        self.turnID = turnID
        self.sequence = sequence
        self.appliedAt = appliedAt
        self.text = text
    }
    enum CodingKeys: String, CodingKey { case requestID = "request_id", turnID = "turn_id", sequence, appliedAt = "applied_at", text }
}
public protocol TextSupplementClient: Sendable {
    func runtimeCapabilities() async throws -> RuntimeCapabilitySnapshot
    func backgroundJobRuntimeIdentity() async throws -> String
    func submitTextSupplement(sessionID: String, request: TextSupplementRequest, runtimeIdentity: String) async throws -> TextSupplementReceipt
    func queryTextSupplement(sessionID: String, requestID: String, runtimeIdentity: String) async throws -> TextSupplementReceipt
}
public struct TextSupplementDelivery: Codable, Sendable, Equatable {
    public let runtimeIdentity: String
    public let request: TextSupplementRequest
    public var state: String
    public var sequence: Int64?

    var needsConfirmation: Bool {
        !["pending_apply", "applied", "cancelled", "failed", "rejected"].contains(state)
    }
}

/// Recovery only queries; loss of a response is not permission to submit again.
public actor TextSupplementDeliveryCoordinator {
    private let client: any TextSupplementClient
    private let store: any ConversationLocalStateStore
    public init(client: any TextSupplementClient, store: any ConversationLocalStateStore) { self.client = client; self.store = store }

    public func submit(sessionID: String, request: TextSupplementRequest) async throws {
        guard !sessionID.isEmpty, !request.expectedTurnID.isEmpty, !request.requestID.isEmpty,
              !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.text.count <= 100_000 else { throw RuntimeHTTPError.unsupported }
        guard try await client.runtimeCapabilities().capabilities["user_supplement_text_v1"] == true else { throw RuntimeHTTPError.unsupported }
        let identity = try await client.backgroundJobRuntimeIdentity()
        guard !identity.isEmpty else { throw RuntimeHTTPError.unsupported }
        let key = ConversationLocalStateKey.session(sessionID)
        let existing = try store.state(for: key)?.textSupplementDeliveries.first { $0.request.requestID == request.requestID }
        if let existing {
            guard existing.runtimeIdentity == identity, existing.request == request else { throw RuntimeHTTPError.unsupported }
            // Explicit callers recover an uncertain request before deciding to retry.
            try await recover(sessionID: sessionID)
            return
        }
        let record = TextSupplementDelivery(runtimeIdentity: identity, request: request, state: "unconfirmed")
        try store.updateState(for: key) { $0.textSupplementDeliveries.append(record) }
        do {
            let receipt = try await client.submitTextSupplement(sessionID: sessionID, request: request, runtimeIdentity: identity)
            try merge(receipt, sessionID: sessionID, identity: identity)
        } catch {
            if case RuntimeHTTPError.unexpectedStatus(let status, _) = error, [400, 409, 501].contains(status) {
                try store.updateState(for: key) { state in
                    if let i = state.textSupplementDeliveries.firstIndex(where: { $0.request.requestID == request.requestID }), state.textSupplementDeliveries[i].state != "applied" {
                        state.textSupplementDeliveries[i].state = "rejected"
                    }
                }
            }
            throw error
        }
    }

    @discardableResult
    public func recover(sessionID: String) async throws -> Bool {
        guard try await client.runtimeCapabilities().capabilities["user_supplement_text_v1"] == true else { return false }
        let identity = try await client.backgroundJobRuntimeIdentity()
        let records = try store.state(for: .session(sessionID))?.textSupplementDeliveries ?? []
        var allConfirmed = true
        for record in records where !["applied", "cancelled", "failed", "rejected"].contains(record.state) {
            guard record.runtimeIdentity == identity else {
                allConfirmed = false
                continue
            }
            do { try merge(try await client.queryTextSupplement(sessionID: sessionID, requestID: record.request.requestID, runtimeIdentity: identity), sessionID: sessionID, identity: identity) }
            catch { allConfirmed = false }
        }
        return allConfirmed
    }

    public func apply(_ receipt: SupplementApplicationReceipt, sessionID: String) async throws {
        let identity = try await client.backgroundJobRuntimeIdentity()
        try store.updateState(for: .session(sessionID)) { state in
            guard let i = state.textSupplementDeliveries.firstIndex(where: { $0.runtimeIdentity == identity && $0.request.requestID == receipt.requestID && $0.request.expectedTurnID == receipt.turnID }),
                  receipt.sequence > 0,
                  state.textSupplementDeliveries[i].sequence == nil || state.textSupplementDeliveries[i].sequence == receipt.sequence else { return }
            state.textSupplementDeliveries[i].state = "applied"
            state.textSupplementDeliveries[i].sequence = receipt.sequence
        }
    }
    private func merge(_ receipt: TextSupplementReceipt, sessionID: String, identity: String) throws {
        guard receipt.input.sessionID == sessionID, receipt.sequence > 0 else { throw RuntimeHTTPError.unsupported }
        guard let stored = try store.state(for: .session(sessionID))?.textSupplementDeliveries.first(where: { $0.request.requestID == receipt.input.requestID }),
              stored.runtimeIdentity == identity, stored.request.expectedTurnID == receipt.input.expectedTurnID,
              stored.request.text == receipt.input.text else { throw RuntimeHTTPError.unsupported }
        try store.updateState(for: .session(sessionID)) { state in
            guard let i = state.textSupplementDeliveries.firstIndex(where: { $0.runtimeIdentity == identity && $0.request.requestID == receipt.input.requestID }),
                  state.textSupplementDeliveries[i].request.expectedTurnID == receipt.input.expectedTurnID,
                  state.textSupplementDeliveries[i].request.text == receipt.input.text,
                  state.textSupplementDeliveries[i].sequence == nil || state.textSupplementDeliveries[i].sequence == receipt.sequence,
                  state.textSupplementDeliveries[i].state != "applied" else { return }
            state.textSupplementDeliveries[i].state = receipt.state
            state.textSupplementDeliveries[i].sequence = receipt.sequence
        }
    }
}
