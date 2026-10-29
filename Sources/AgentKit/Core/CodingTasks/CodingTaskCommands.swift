import Foundation
import Observation

public struct CodingTaskReceipt: Codable, Sendable {
    public let id: String
    public let task_id: String?
    public let status: String
}

public struct CodingTaskCreateRequest: Codable, Sendable, Equatable {
    public let request_id, workspace_session_id, goal: String
    public let acceptance: [String]
}

public struct CodingTaskExecutorRequest: Encodable, Sendable {
    public let request_id: String
    public let role = "executor"
    public let session_ref: CodingTaskSessionRef
    enum CodingKeys: String, CodingKey { case request_id, role, session_ref }
    public init(requestID: String, sessionID: String, identity: CodingTaskIdentity) {
        request_id = requestID
        session_ref = .init(kind: "local", server_id: identity.serverID, store_id: identity.storeID,
                            session_id: sessionID, session_handle: nil, runtime_kind: nil)
    }
}

public struct CodingTaskStartRequest: Codable, Sendable, Equatable {
    public let request_id, plan_artifact_id, executor_participation_id, reviewer_participation_id: String
    public let max_iterations: Int
    public let files, validation_commands: [String]
    public let executor_model: String?
    public init(request_id: String, plan_artifact_id: String, executor_participation_id: String,
                reviewer_participation_id: String, max_iterations: Int, files: [String],
                validation_commands: [String], executor_model: String? = nil) {
        self.request_id = request_id; self.plan_artifact_id = plan_artifact_id
        self.executor_participation_id = executor_participation_id; self.reviewer_participation_id = reviewer_participation_id
        self.max_iterations = max_iterations; self.files = files; self.validation_commands = validation_commands
        self.executor_model = executor_model
    }
}

/// Optional catalog selection; generation parameters remain owned by the Runtime.
public protocol CodingTaskModelReading: Sendable {
    func codingTaskModels() async throws -> RuntimeServerModelCatalog
}

/// Host operations only; no generation overrides, review impersonation or recovery commands.
public protocol CodingTaskWriting: Sendable {
    func createCodingTask(_ request: CodingTaskCreateRequest, identity: CodingTaskIdentity) async throws -> CodingTaskReceipt
    func attachCodingTaskExecutor(taskID: String, request: CodingTaskExecutorRequest, identity: CodingTaskIdentity) async throws -> CodingTaskReceipt
    func startCodingTask(taskID: String, request: CodingTaskStartRequest, identity: CodingTaskIdentity) async throws -> CodingTaskReceipt
}

public enum CodingTaskActionPolicy {
    public static func canStart(_ task: CodingTaskSnapshot, capabilities: CodingTaskCapabilities) -> Bool {
        capabilities.capabilities.contains("task_managed_workflow_v1") && capabilities.capabilities.contains("task_review_gate_v1")
            && task.managed_run == nil && task.task_acceptance == "not_reviewed"
            && ["active", "waiting"].contains(task.state)
            && ["planning", "implementing"].contains(task.phase)
            && !["recovery_required", "candidate_invalidated"].contains(task.wait_reason ?? "")
            && !plans(task).isEmpty
            && task.participations.contains { $0.role == "executor" && $0.session_ref.localSession(in: capabilities.identity) != nil }
            && task.participations.contains { $0.role == "reviewer" && $0.observation_level == "reported" }
    }
    public static func plans(_ task: CodingTaskSnapshot) -> [CodingTaskArtifact] {
        task.artifact_refs.filter { $0.kind == "plan" && $0.capture_mode == "reported" && $0.content_hash?.isEmpty == false && !$0.truncated }
    }
    static func validate(_ request: CodingTaskStartRequest, task: CodingTaskSnapshot, capabilities: CodingTaskCapabilities) throws {
        if let model = request.executor_model {
            guard capabilities.capabilities.contains("task_executor_model_v1"), !model.isEmpty,
                  model.utf8.count <= 256, model.contains("/"),
                  model.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            else { throw CodingTaskReadError.protocolMismatch }
        }
        guard canStart(task, capabilities: capabilities), (1...5).contains(request.max_iterations),
              !request.files.isEmpty, request.files.count <= 64, request.validation_commands.count <= 16,
              !request.validation_commands.isEmpty,
              Set(request.files).count == request.files.count,
              request.files.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 && !$0.hasPrefix("/")
                  && !$0.split(separator: "/").contains("..") && !$0.split(separator: "/").contains(".")
                  && !$0.contains("//") && !$0.hasSuffix("/") && $0.rangeOfCharacter(from: CharacterSet(charactersIn: "\0\r\n\t\\")) == nil }),
              request.validation_commands.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 4096 && !$0.contains("\0") }),
              plans(task).contains(where: { $0.id == request.plan_artifact_id }),
              task.participations.contains(where: { $0.id == request.executor_participation_id && $0.role == "executor" && $0.session_ref.localSession(in: capabilities.identity) != nil }),
              task.participations.contains(where: { $0.id == request.reviewer_participation_id && $0.role == "reviewer" && $0.observation_level == "reported" })
        else { throw CodingTaskReadError.protocolMismatch }
    }
}

/// A retry retains the original payload/request ID. Reads and polling never submit commands.
@MainActor @Observable
public final class CodingTaskActions {
    public private(set) var busy = false
    public private(set) var errorMessage: String?
    public private(set) var createdTaskID: String?
    public private(set) var completed = false
    public private(set) var createRequest: CodingTaskCreateRequest?
    public private(set) var startRequest: CodingTaskStartRequest?
    private let reader: any CodingTaskReading
    private let writer: any CodingTaskWriting
    private let identity: CodingTaskIdentity
    public init(reader: any CodingTaskReading, writer: any CodingTaskWriting, identity: CodingTaskIdentity) {
        self.reader = reader; self.writer = writer; self.identity = identity
    }

    public func create(sessionID: String, goal: String, acceptance: [String]) async {
        guard !busy, !completed else { return }
        if createRequest == nil {
            let value = goal.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sessionID.isEmpty, !value.isEmpty, value.utf8.count <= 16384, acceptance.count <= 32 else {
                errorMessage = "请选择执行会话并填写有效目标（验收条件最多 32 项）。"; return
            }
            createRequest = .init(request_id: "task-ui-\(UUID().uuidString)", workspace_session_id: sessionID, goal: value, acceptance: acceptance)
        }
        guard let request = createRequest else { return }
        busy = true; defer { busy = false }
        do {
            let caps = try await reader.codingTaskCapabilities()
            guard caps.identity == identity, caps.capabilities.contains("task_links_v1") else { throw CodingTaskReadError.identityChanged }
            if createdTaskID == nil {
                let receipt = try await writer.createCodingTask(request, identity: identity)
                guard !receipt.id.isEmpty else { throw CodingTaskReadError.protocolMismatch }
                createdTaskID = receipt.id
            }
            guard let id = createdTaskID else { throw CodingTaskReadError.protocolMismatch }
            _ = try await writer.attachCodingTaskExecutor(taskID: id, request: .init(requestID: request.request_id + "-executor", sessionID: request.workspace_session_id, identity: identity), identity: identity)
            completed = true; errorMessage = nil
        } catch { errorMessage = "创建或关联尚未确认。重试将使用相同请求；请先核对任务列表。\n" + CodingTaskStore.message(error) }
    }

    public func start(taskID: String, request: CodingTaskStartRequest) async {
        guard !busy, !completed else { return }
        let pending = startRequest ?? request
        guard pending == request else { return }
        busy = true; defer { busy = false }
        do {
            let caps = try await reader.codingTaskCapabilities()
            guard caps.identity == identity else { throw CodingTaskReadError.identityChanged }
            let snapshot = try await reader.codingTaskSnapshot(id: taskID)
            guard snapshot.task_id == taskID else { throw CodingTaskReadError.protocolMismatch }
            if snapshot.managed_run == nil { try CodingTaskActionPolicy.validate(pending, task: snapshot, capabilities: caps) }
            else {
                // Uncertain ACK: only replay our exact idempotent request, never allocate a fresh Run.
                guard startRequest != nil, snapshot.managed_run?["command_id"]?.text != nil,
                      snapshot.managed_run?["state"]?.text != "recovery_required", snapshot.wait_reason != "recovery_required"
                else { throw CodingTaskReadError.protocolMismatch }
            }
            startRequest = pending
            _ = try await writer.startCodingTask(taskID: taskID, request: pending, identity: identity)
            completed = true; errorMessage = nil
        } catch { errorMessage = "启动结果尚未确认。请刷新原任务；重试会保留同一请求 ID。\n" + CodingTaskStore.message(error) }
    }
}
