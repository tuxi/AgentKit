import Foundation

public enum BackgroundJobStatus: String, Codable, Sendable, Hashable {
    case running, exited, failed, canceled, unknown
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
    public var isTerminal: Bool { self == .exited || self == .failed || self == .canceled }
}

public struct BackgroundJobSnapshot: Codable, Sendable, Hashable, Identifiable {
    public let jobID: String
    public let sessionID: String
    public let turnID: String
    public let callID: String
    public let command: String
    public let status: BackgroundJobStatus
    public let exitCode: Int?
    public let durationMs: Int64
    public let cancelRequested: Bool
    public let outputTail: String
    public var id: String { jobID }
    public var owner: BackgroundJobOwner { .init(jobID: jobID, turnID: turnID, callID: callID) }
    enum CodingKeys: String, CodingKey {
        case jobID = "job_id", sessionID = "session_id", turnID = "turn_id", callID = "call_id"
        case command, status, exitCode = "exit_code", durationMs = "duration_ms"
        case cancelRequested = "cancel_requested", outputTail = "output_tail"
    }
    public init(jobID: String, sessionID: String, turnID: String, callID: String, command: String,
                status: BackgroundJobStatus, exitCode: Int? = nil, durationMs: Int64 = 0,
                cancelRequested: Bool = false, outputTail: String = "") {
        self.jobID = jobID; self.sessionID = sessionID; self.turnID = turnID; self.callID = callID
        self.command = command; self.status = status; self.exitCode = exitCode
        self.durationMs = durationMs; self.cancelRequested = cancelRequested; self.outputTail = outputTail
    }
}

public struct BackgroundJobOwner: Sendable, Hashable {
    public let jobID: String
    public let turnID: String
    public let callID: String
    public init(jobID: String, turnID: String, callID: String) {
        self.jobID = jobID; self.turnID = turnID; self.callID = callID
    }
}

struct BackgroundJobListPayload: Decodable { let jobs: [BackgroundJobSnapshot] }
struct BackgroundJobCancelPayload: Decodable { let job: BackgroundJobSnapshot }
struct BackgroundJobCancelRequest: Encodable { let turn_id: String; let call_id: String }
enum BackgroundJobControlError: Error { case runtimeChanged, invalidOwner, invalidSnapshot }
