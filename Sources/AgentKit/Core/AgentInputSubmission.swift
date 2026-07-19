//
//  AgentInputSubmission.swift
//  AgentKit
//
//  Session-scoped reliable submission state for Agent Wire v1.5.
//

import Foundation

public enum AgentInputSubmissionState: Sendable, Equatable {
    case pending
    case dispatched
    case reconnecting
    case blocked(AgentInputRejection)
    case accepted(turnID: String)
    case rejected(AgentInputRejection)
}

public struct AgentInputSubmissionTicket: Sendable {
    public let requestID: String
    public let states: AsyncStream<AgentInputSubmissionState>

    init(requestID: String, states: AsyncStream<AgentInputSubmissionState>) {
        self.requestID = requestID
        self.states = states
    }

    static func terminal(
        requestID: String,
        state: AgentInputSubmissionState
    ) -> AgentInputSubmissionTicket {
        AgentInputSubmissionTicket(requestID: requestID, states: AsyncStream { continuation in
            continuation.yield(state)
            continuation.finish()
        })
    }
}

/// Owns immutable pending payloads independently of any SwiftUI task or subscriber.
actor AgentInputSubmissionCoordinator {
    private struct PayloadIdentity: Equatable {
        let text: String?
        let model: String?
        let assets: [UserAssetRef]
    }

    private struct Entry {
        let input: AgentInput
        let identity: PayloadIdentity
        var subscribers: [UUID: AsyncStream<AgentInputSubmissionState>.Continuation]
    }

    private var entries: [String: Entry] = [:]

    func register(_ input: AgentInput) -> AgentInputSubmissionTicket {
        let requestID = input.requestID ?? ""
        let identity = PayloadIdentity(text: input.text, model: input.model, assets: input.assets)
        let subscriberID = UUID()
        var capturedContinuation: AsyncStream<AgentInputSubmissionState>.Continuation?
        let stream = AsyncStream<AgentInputSubmissionState> { continuation in
            capturedContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(subscriberID, requestID: requestID) }
            }
        }
        guard let continuation = capturedContinuation else {
            return .terminal(
                requestID: requestID,
                state: .rejected(AgentInputRejection(code: "request_failed", message: "Unable to observe submission"))
            )
        }

        if var existing = entries[requestID] {
            guard existing.identity == identity else {
                continuation.yield(.rejected(AgentInputRejection(
                    code: "request_conflict",
                    message: "request_id was already used with a different payload"
                )))
                continuation.finish()
                return AgentInputSubmissionTicket(requestID: requestID, states: stream)
            }
            existing.subscribers[subscriberID] = continuation
            entries[requestID] = existing
        } else {
            entries[requestID] = Entry(
                input: input,
                identity: identity,
                subscribers: [subscriberID: continuation]
            )
        }
        continuation.yield(.pending)
        return AgentInputSubmissionTicket(requestID: requestID, states: stream)
    }

    func markDispatched(requestID: String) {
        broadcast(.dispatched, requestID: requestID)
    }

    func markReconnecting() {
        for requestID in entries.keys {
            broadcast(.reconnecting, requestID: requestID)
        }
    }

    func replayableInputs(supportsImageInput: Bool) -> [AgentInput] {
        var result: [AgentInput] = []
        for (requestID, entry) in entries {
            if !entry.input.assets.isEmpty && !supportsImageInput {
                broadcast(.blocked(AgentInputRejection(
                    code: "image_input_unsupported",
                    message: "当前服务不支持图片"
                )), requestID: requestID)
                continue
            }
            broadcast(.reconnecting, requestID: requestID)
            result.append(entry.input)
        }
        return result
    }

    func accept(requestID: String, turnID: String) {
        finish(.accepted(turnID: turnID), requestID: requestID)
    }

    func reject(requestID: String?, rejection: AgentInputRejection) {
        guard let requestID, entries[requestID] != nil else { return }
        finish(.rejected(rejection), requestID: requestID)
    }

    private func removeSubscriber(_ subscriberID: UUID, requestID: String) {
        guard var entry = entries[requestID] else { return }
        entry.subscribers.removeValue(forKey: subscriberID)
        // Intentionally retain the payload with zero subscribers. UI cancellation
        // must not cancel the reliable submission or change its request identity.
        entries[requestID] = entry
    }

    private func broadcast(_ state: AgentInputSubmissionState, requestID: String) {
        guard let entry = entries[requestID] else { return }
        for continuation in entry.subscribers.values {
            continuation.yield(state)
        }
    }

    private func finish(_ state: AgentInputSubmissionState, requestID: String) {
        guard let entry = entries.removeValue(forKey: requestID) else { return }
        for continuation in entry.subscribers.values {
            continuation.yield(state)
            continuation.finish()
        }
    }
}
