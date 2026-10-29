import Foundation

/// CodingTask cursors belong to the Store, not to Session or Flux streams.
public struct CodingTaskIdentity: Hashable, Sendable {
    public let serverID: String
    public let storeID: String
}

public struct CodingTaskCapabilities: Codable, Sendable {
    public let server_id: String
    public let store_id: String
    public let capabilities: [String]
    public var identity: CodingTaskIdentity { .init(serverID: server_id, storeID: store_id) }
}

/// Unknown payload fields and event kinds remain inspectable across protocol versions.
public indirect enum CodingTaskJSON: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Decimal), string(String), array([Self]), object([String: Self])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Decimal.self) { self = .number(v) }
        else if let v = try? c.decode([Self].self) { self = .array(v) }
        else { self = .object(try c.decode([String: Self].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public subscript(_ key: String) -> Self? { if case .object(let v) = self { return v[key] }; return nil }
    public var text: String? { if case .string(let v) = self { return v }; return nil }
    public var display: String {
        if let text { return text }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "—"
    }
}

public struct CodingTaskSessionRef: Codable, Sendable {
    public let kind: String
    public let server_id, store_id, session_id, session_handle, runtime_kind: String?
    public func localSession(in identity: CodingTaskIdentity) -> String? {
        guard kind == "local", server_id == identity.serverID, store_id == identity.storeID else { return nil }
        return session_id
    }
}
public struct CodingTaskParticipation: Codable, Sendable, Identifiable {
    public let participation_id, task_id, agent_id, role, observation_level: String
    public let session_ref: CodingTaskSessionRef
    public var id: String { participation_id }
}
public struct CodingTaskAttempt: Codable, Sendable, Identifiable {
    public let attempt_id, task_id, participation_id, stage, status: String
    public let iteration: Int
    public let source_ref: CodingTaskJSON
    public let execution_evidence: CodingTaskJSON?
    public var id: String { attempt_id }
}
public struct CodingTaskArtifact: Codable, Sendable, Identifiable {
    public let artifact_id, attempt_id, kind, version, capture_mode: String
    public let content_hash: String?
    public let source_ref: CodingTaskJSON
    public let content: CodingTaskJSON?
    public let truncated: Bool
    public var id: String { artifact_id }
}
public struct CodingTaskSummary: Codable, Sendable, Identifiable {
    public let task_id, workspace_ref, goal, mode, state, phase, revision, snapshot_task_seq, task_acceptance: String
    public let wait_reason: String?
    public var id: String { task_id }
}
public struct CodingTaskSnapshot: Codable, Sendable {
    public let schema, task_id, workspace_ref, goal, mode, state, phase, revision, snapshot_task_seq, task_acceptance: String
    public let wait_reason: String?
    public let managed_run: CodingTaskJSON?
    public let acceptance: [String]
    public let participations: [CodingTaskParticipation]
    public let attempts: [CodingTaskAttempt]
    public let artifact_refs: [CodingTaskArtifact]
    public let pending_attention: [CodingTaskJSON]?
    public let usage: CodingTaskJSON?
    public let cost_usd: Double?
    public var executionRounds: Int {
        let executors = Set(participations.filter { $0.role == "executor" }.map(\.id))
        return attempts.filter { executors.contains($0.participation_id) && $0.source_ref["turn_id"]?.text != nil }.count
    }
}
public struct CodingTaskEvent: Codable, Sendable, Identifiable {
    public let event_id, task_id, task_seq, task_revision, recorded_at, kind: String
    public let participation_id, attempt_id: String?
    public let payload: CodingTaskJSON
    public var id: String { event_id }
    public var isSystem: Bool {
        kind.hasPrefix("run.") || kind.hasPrefix("task.") || kind.hasPrefix("review.gate") || kind == "review.invalidated"
    }
}
public struct CodingTaskEventPage: Codable, Sendable {
    public let task_id, after, next_cursor: String
    public let events: [CodingTaskEvent]
    public let has_more, resync_required: Bool
}
public struct CodingTaskFileImage: Codable, Sendable {
    public let path: String
    public let exists: Bool
    public let mode: UInt32
    public let data: Data?
    public var text: String? { data.flatMap { String(data: $0, encoding: .utf8) } }
}
public struct CodingTaskWorkspaceImage: Codable, Sendable {
    public let head, status: String
    public let index, files: [CodingTaskFileImage]?
}
public struct CodingTaskReviewBundle: Codable, Sendable {
    public let schema, attempt_id, turn_id, event_cursor, patch, index_patch, validation_status: String
    public let iteration: Int
    public let source, plan: CodingTaskJSON
    public let baseline, candidate: CodingTaskWorkspaceImage
    public let execution_evidence: CodingTaskJSON?
}

/// Optional port: existing RuntimeClient implementations keep their original contract.
public protocol CodingTaskReading: Sendable {
    func codingTaskCapabilities() async throws -> CodingTaskCapabilities
    func codingTasks() async throws -> [CodingTaskSummary]
    func codingTaskSnapshot(id: String) async throws -> CodingTaskSnapshot
    func codingTaskEvents(id: String, after: String) async throws -> CodingTaskEventPage
    func codingTaskBundle(taskID: String, artifactID: String) async throws -> CodingTaskReviewBundle
}
