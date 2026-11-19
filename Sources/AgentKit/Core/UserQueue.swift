import Foundation

public struct UserQueueRequest: Codable, Equatable, Sendable {
    public let requestID: String
    public let text: String
    public let model: String
    public let reasoningEffort: String?

    public init(requestID: String = UUID().uuidString, text: String, model: String, reasoningEffort: String? = nil) {
        self.requestID = requestID
        self.text = text
        self.model = model
        self.reasoningEffort = reasoningEffort
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id", text, model, reasoningEffort = "reasoning_effort"
    }
}

public struct UserQueueReceipt: Decodable, Sendable {
    public struct Input: Decodable, Sendable {
        public struct ExecutionContext: Decodable, Sendable {
            public let wireModel: String
            public let reasoningEffort: String?
            enum CodingKeys: String, CodingKey {
                case wireModel = "wire_model", reasoningEffort = "reasoning_effort"
            }
        }
        public let sessionID: String
        public let requestID: String
        public let text: String
        public let selectionEffort: String?
        public let context: ExecutionContext

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id", requestID = "request_id", text
            case selectionEffort = "selection_effort", context
        }
    }

    public let input: Input
    public let sequence: Int64
    public let revision: Int64
    public let state: String

    func matches(_ request: UserQueueRequest, sessionID: String) -> Bool {
        input.sessionID == sessionID && input.requestID == request.requestID
            && input.text == request.text && input.context.wireModel == request.model
            && (input.selectionEffort ?? "") == (request.reasoningEffort ?? "")
    }
}

public struct UserQueuePage: Decodable, Sendable {
    public struct Cursor: Decodable, Sendable {
        public let sessionID: String
        public let revision: Int64
        public let afterSequence: Int64
        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id", revision, afterSequence = "after_sequence"
        }
    }
    public let revision: Int64
    public let state: String
    public let pauseReason: String?
    public let items: [UserQueueReceipt]
    public let next: Cursor?
    public let controls: Bool?
    public let interrupted: UserQueueReceipt?
    public let resumeSupported: Bool?
    enum CodingKeys: String, CodingKey {
        case revision, state, pauseReason = "pause_reason", items, next, controls, interrupted, resumeSupported = "resume_supported"
    }
}

public struct UserQueueChange: Encodable, Sendable {
    public let revision: Int64
    public let action: Action
    public let requestID: String?

    public enum Action: String, Encodable, Sendable { case resume, remove
        case resumeInterrupted = "resume_interrupted"
    }

    public init(revision: Int64, action: Action, requestID: String? = nil) {
        self.revision = revision
        self.action = action
        self.requestID = requestID
    }

    enum CodingKeys: String, CodingKey {
        case revision, action, requestID = "request_id"
    }
}

public protocol UserQueueClient: Sendable {
    func controlUserQueue(sessionID: String, change: UserQueueChange, serverID: String) async throws
    func userQueueServerID() async throws -> String
    func enqueueUserMessage(sessionID: String, value: UserQueueRequest, serverID: String) async throws -> UserQueueReceipt
    func queryUserQueueMessage(sessionID: String, requestID: String, serverID: String) async throws -> UserQueueReceipt
    func listUserQueue(sessionID: String, cursor: UserQueuePage.Cursor?, serverID: String) async throws -> UserQueuePage
}

public extension UserQueueClient {
    func controlUserQueue(sessionID: String, change: UserQueueChange, serverID: String) async throws {
        throw RuntimeHTTPError.unsupported
    }
}

public struct PendingUserQueueRequest: Codable, Equatable, Sendable {
    public let serverID: String
    public let request: UserQueueRequest
}
