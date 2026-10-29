import Foundation
import XCTest
@testable import AgentKit

private actor TaskCommandFixture: CodingTaskReading, CodingTaskWriting {
    var snapshot: CodingTaskSnapshot
    let identity: CodingTaskIdentity
    var creates: [CodingTaskCreateRequest] = []
    var starts: [CodingTaskStartRequest] = []
    var attachments = 0
    var createdIDs: Set<String> = []
    var lostCreateACK = false
    var failAttachment = false
    var lostStartACK = false
    var wrongStore = false
    var modelSelection = false
    func enableModelSelection() { modelSelection = true }
    init(snapshot: CodingTaskSnapshot) {
        self.snapshot = snapshot
        let local = snapshot.participations.first { $0.session_ref.kind == "local" }!.session_ref
        identity = .init(serverID: local.server_id!, storeID: local.store_id!)
    }
    func configure(createACK: Bool = false, attachment: Bool = false, startACK: Bool = false, wrongStore: Bool = false) {
        lostCreateACK = createACK; failAttachment = attachment; lostStartACK = startACK; self.wrongStore = wrongStore
    }
    func codingTaskCapabilities() async throws -> CodingTaskCapabilities {
        .init(server_id: identity.serverID, store_id: wrongStore ? "wrong" : identity.storeID,
              capabilities: ["task_links_v1", "task_timeline_v1", "task_managed_workflow_v1", "task_review_gate_v1"] + (modelSelection ? ["task_executor_model_v1"] : []))
    }
    func existingRun(state: String) throws {
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        raw["managed_run"] = ["state": state, "command_id": "existing-command"]
        if state == "recovery_required" { raw["wait_reason"] = state }
        snapshot = try JSONDecoder().decode(CodingTaskSnapshot.self, from: JSONSerialization.data(withJSONObject: raw))
    }
    func codingTasks() async throws -> [CodingTaskSummary] { [] }
    func codingTaskSnapshot(id: String) async throws -> CodingTaskSnapshot { snapshot }
    func codingTaskEvents(id: String, after: String) async throws -> CodingTaskEventPage { throw RuntimeHTTPError.unsupported }
    func codingTaskBundle(taskID: String, artifactID: String) async throws -> CodingTaskReviewBundle { throw RuntimeHTTPError.unsupported }
    func createCodingTask(_ request: CodingTaskCreateRequest, identity: CodingTaskIdentity) async throws -> CodingTaskReceipt {
        creates.append(request); createdIDs.insert(request.request_id)
        if lostCreateACK { lostCreateACK = false; throw URLError(.networkConnectionLost) }
        return .init(id: "created-task", task_id: "created-task", status: "recorded")
    }
    func attachCodingTaskExecutor(taskID: String, request: CodingTaskExecutorRequest, identity: CodingTaskIdentity) async throws -> CodingTaskReceipt {
        attachments += 1
        if failAttachment { failAttachment = false; throw URLError(.timedOut) }
        return .init(id: "executor", task_id: taskID, status: "recorded")
    }
    func startCodingTask(taskID: String, request: CodingTaskStartRequest, identity: CodingTaskIdentity) async throws -> CodingTaskReceipt {
        starts.append(request)
        if lostStartACK { lostStartACK = false; throw URLError(.timedOut) }
        return .init(id: "run", task_id: taskID, status: "recorded")
    }
}

private func plannedTask() throws -> CodingTaskSnapshot {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/coding-task/managed.json")
    let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var value = try XCTUnwrap(document["snapshot"] as? [String: Any])
    value.removeValue(forKey: "managed_run")
    value["task_acceptance"] = "not_reviewed"; value["state"] = "waiting"; value["phase"] = "planning"
    value["wait_reason"] = "execution_not_started"
    return try JSONDecoder().decode(CodingTaskSnapshot.self, from: JSONSerialization.data(withJSONObject: value))
}

@MainActor
final class CodingTaskCommandTests: XCTestCase {
    func testCreateLostACKRetriesSamePayloadAndAllocatesOnce() async throws {
        let fixture = TaskCommandFixture(snapshot: try plannedTask())
        let identity = await fixture.identity
        let actions = CodingTaskActions(reader: fixture, writer: fixture, identity: identity)
        await fixture.configure(createACK: true)
        await actions.create(sessionID: "session", goal: "goal", acceptance: ["criterion"])
        XCTAssertFalse(actions.completed); XCTAssertNotNil(actions.errorMessage)
        await actions.create(sessionID: "different-session", goal: "changed text", acceptance: [])
        XCTAssertTrue(actions.completed); XCTAssertEqual(actions.createdTaskID, "created-task")
        let requests = await fixture.creates, count = await fixture.createdIDs.count
        XCTAssertEqual(requests.count, 2); XCTAssertEqual(requests.first, requests.last); XCTAssertEqual(count, 1)
    }

    func testAttachmentFailureDoesNotCreateAnotherTask() async throws {
        let fixture = TaskCommandFixture(snapshot: try plannedTask())
        let actions = CodingTaskActions(reader: fixture, writer: fixture, identity: await fixture.identity)
        await fixture.configure(attachment: true)
        await actions.create(sessionID: "session", goal: "goal", acceptance: [])
        XCTAssertEqual(actions.createdTaskID, "created-task"); XCTAssertFalse(actions.completed)
        await actions.create(sessionID: "session", goal: "goal", acceptance: [])
        let requests = await fixture.creates, count = await fixture.attachments
        XCTAssertEqual(requests.count, 1); XCTAssertEqual(count, 2); XCTAssertTrue(actions.completed)
    }

    func testIdentityChangeRejectsCommandBeforeWriting() async throws {
        let fixture = TaskCommandFixture(snapshot: try plannedTask())
        let actions = CodingTaskActions(reader: fixture, writer: fixture, identity: await fixture.identity)
        await fixture.configure(wrongStore: true)
        await actions.create(sessionID: "session", goal: "goal", acceptance: [])
        let requests = await fixture.creates
        XCTAssertTrue(requests.isEmpty); XCTAssertFalse(actions.completed)
    }

    func testStartRetryRetainsOriginalRequestAndNoModelOverrides() async throws {
        let snapshot = try plannedTask(), fixture = TaskCommandFixture(snapshot: try plannedTask())
        let actions = CodingTaskActions(reader: fixture, writer: fixture, identity: await fixture.identity)
        let request = try startRequest(snapshot)
        await fixture.configure(startACK: true)
        await actions.start(taskID: snapshot.task_id, request: request)
        XCTAssertFalse(actions.completed)
        await actions.start(taskID: snapshot.task_id, request: request)
        XCTAssertTrue(actions.completed)
        let starts = await fixture.starts
        XCTAssertEqual(starts, [request, request])
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(Set(keys.keys), ["request_id", "plan_artifact_id", "executor_participation_id", "reviewer_participation_id", "max_iterations", "files", "validation_commands"])
    }

    func testInvalidStartDoesNotFreezeEditableDraftOrDispatch() async throws {
        let snapshot = try plannedTask(), fixture = TaskCommandFixture(snapshot: try plannedTask())
        let actions = CodingTaskActions(reader: fixture, writer: fixture, identity: await fixture.identity)
        let request = try startRequest(snapshot, files: ["../outside"])
        await actions.start(taskID: snapshot.task_id, request: request)
        XCTAssertNil(actions.startRequest)
        let starts = await fixture.starts
        XCTAssertTrue(starts.isEmpty)
    }

    func testTerminalOrRecoveryTaskNeverOffersStart() async throws {
        let snapshot = try plannedTask(), fixture = TaskCommandFixture(snapshot: try plannedTask())
        let caps = try await fixture.codingTaskCapabilities()
        XCTAssertTrue(CodingTaskActionPolicy.canStart(snapshot, capabilities: caps))
        for state in ["failed", "cancelled", "completed"] {
            var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
            raw["state"] = state
            let next = try JSONDecoder().decode(CodingTaskSnapshot.self, from: JSONSerialization.data(withJSONObject: raw))
            XCTAssertFalse(CodingTaskActionPolicy.canStart(next, capabilities: caps))
        }
        let noManaged = CodingTaskCapabilities(server_id: caps.server_id, store_id: caps.store_id, capabilities: ["task_links_v1"])
        XCTAssertFalse(CodingTaskActionPolicy.canStart(snapshot, capabilities: noManaged))
    }

    func testUncertainACKMayRetryOriginalRunButNeverRecoveryFence() async throws {
        let snapshot = try plannedTask(), fixture = TaskCommandFixture(snapshot: try plannedTask())
        let actions = CodingTaskActions(reader: fixture, writer: fixture, identity: await fixture.identity)
        let request = try startRequest(snapshot)
        await fixture.configure(startACK: true)
        await actions.start(taskID: snapshot.task_id, request: request)
        try await fixture.existingRun(state: "submitted")
        await actions.start(taskID: snapshot.task_id, request: request)
        XCTAssertTrue(actions.completed)
        let submitted = await fixture.starts
        XCTAssertEqual(submitted, [request, request])
        let fenced = TaskCommandFixture(snapshot: try plannedTask())
        let pending = CodingTaskActions(reader: fenced, writer: fenced, identity: await fenced.identity)
        await fenced.configure(startACK: true)
        await pending.start(taskID: snapshot.task_id, request: request)
        try await fenced.existingRun(state: "recovery_required")
        await pending.start(taskID: snapshot.task_id, request: request)
        XCTAssertFalse(pending.completed)
        let stopped = await fenced.starts
        XCTAssertEqual(stopped.count, 1)
    }

    func testExplicitModelRequiresCapabilityAndRetryKeepsSelection() async throws {
        let snapshot = try plannedTask(), fixture = TaskCommandFixture(snapshot: try plannedTask())
        let actions = CodingTaskActions(reader: fixture, writer: fixture, identity: await fixture.identity)
        let request = try startRequest(snapshot, model: "opencode-go/qwen3.8-flash")
        await actions.start(taskID: snapshot.task_id, request: request)
        let rejected = await fixture.starts
        XCTAssertTrue(rejected.isEmpty); XCTAssertNil(actions.startRequest)
        await fixture.enableModelSelection()
        await fixture.configure(startACK: true)
        await actions.start(taskID: snapshot.task_id, request: request)
        XCTAssertFalse(actions.completed)
        await actions.start(taskID: snapshot.task_id, request: try startRequest(snapshot, model: "other/model"))
        let unchanged = await fixture.starts
        XCTAssertEqual(unchanged, [request])
        await actions.start(taskID: snapshot.task_id, request: request)
        let retries = await fixture.starts
        XCTAssertEqual(retries, [request, request]); XCTAssertTrue(actions.completed)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(payload["executor_model"] as? String, "opencode-go/qwen3.8-flash")
        XCTAssertNil(payload["model"]); XCTAssertNil(payload["max_tokens"])
    }

    func testCatalogRetainsCanonicalIDAndAcceptsLegacyDescriptors() throws {
        let base = "\"runtime_alias\":\"alias\",\"wire_model_id\":\"wire\",\"display_name\":\"Name\",\"supports_tools\":true,\"supports_reasoning\":false,\"input_modalities\":[\"text\"],\"available\":true"
        let decoder = JSONDecoder()
        let old = try decoder.decode(RuntimeServerModelDescriptor.self, from: Data("{\(base)}".utf8))
        XCTAssertNil(old.id)
        let current = try decoder.decode(RuntimeServerModelDescriptor.self, from: Data("{\(base),\"id\":\"provider/wire\"}".utf8))
        XCTAssertEqual(current.id, "provider/wire"); XCTAssertEqual(current.runtimeAlias, "alias")
    }

    func testExecutorModelSharedJSONContract() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/coding-task/executor-model.json")
        let raw = try Data(contentsOf: url)
        let request = try JSONDecoder().decode(CodingTaskStartRequest.self, from: raw)
        XCTAssertEqual(request.executor_model, "opencode-go/qwen3.8-flash"); XCTAssertEqual(request.max_iterations, 2)
        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? NSDictionary)
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? NSDictionary)
        XCTAssertEqual(before, after)
    }

    private func startRequest(_ snapshot: CodingTaskSnapshot, files: [String] = ["main.txt"], model: String? = nil) throws -> CodingTaskStartRequest {
        .init(request_id: "same-start-request", plan_artifact_id: try XCTUnwrap(CodingTaskActionPolicy.plans(snapshot).last?.id),
              executor_participation_id: try XCTUnwrap(snapshot.participations.first { $0.role == "executor" }?.id),
              reviewer_participation_id: try XCTUnwrap(snapshot.participations.first { $0.role == "reviewer" }?.id),
              max_iterations: 2, files: files, validation_commands: ["git diff --check"], executor_model: model)
    }
}
