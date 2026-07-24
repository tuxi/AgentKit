//
//  WorkflowTests.swift
//  AgentKitTests
//
//  Flux Workflow DAG — decode + reducer 测试。
//  使用 code-agent/internal/server/testdata/ golden fixtures。
//  对照协议：runtime-event-contract-v1.md §5.8。
//

import XCTest
@testable import AgentKit

@MainActor
final class WorkflowTests: XCTestCase {

    // MARK: - Helpers

    private func decodeEvent(_ json: String) throws -> AgentEvent? {
        let frame = try JSONDecoder().decode(WireFrame.self, from: Data(json.utf8))
        return AgentEvent.from(wire: frame)
    }

    private func loadFixture(_ name: String) throws -> String {
        let fixtureDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/flux-workflow")
        let url = fixtureDir.appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func decodeFixture(_ name: String) throws -> AgentEvent? {
        try decodeEvent(loadFixture(name))
    }

    private func makeStore() -> WorkflowStore {
        WorkflowStore()
    }

    // MARK: - Decode: workflow_started

    func testDecodeWorkflowStarted() throws {
        let event = try decodeFixture("workflow_started.json")
        guard case .workflowStarted(let turnID, let callID, let workflowID)? = event else {
            return XCTFail("expected workflowStarted, got \(String(describing: event))")
        }
        XCTAssertEqual(turnID, "turn_42")
        XCTAssertEqual(callID, "call_plan_1")
        XCTAssertEqual(workflowID, "wf_a1b2c3d4e5f6a7b8")
    }

    // MARK: - Decode: workflow_plan_ready (new flat `tool` format)

    func testDecodeWorkflowPlanReady() throws {
        let event = try decodeFixture("workflow_plan_ready.json")
        guard case .workflowPlanReady(let turnID, let callID, let wf)? = event else {
            return XCTFail("expected workflowPlanReady, got \(String(describing: event))")
        }
        XCTAssertEqual(turnID, "turn_42")
        XCTAssertEqual(callID, "call_plan_1")
        XCTAssertEqual(wf.workflowID, "wf_a1b2c3d4e5f6a7b8")
        XCTAssertEqual(wf.goal, "搭建 Python CLI 项目")

        // 6 nodes from golden fixture
        XCTAssertEqual(wf.nodes.count, 6, "plan_ready should have 6 nodes")
        XCTAssertEqual(wf.nodes[0].name, "create_dirs")
        XCTAssertEqual(wf.nodes[0].type, "tool")
        XCTAssertEqual(wf.nodes[0].toolName, "run_command",
                       "flat `tool` field should be decoded as toolName")

        XCTAssertEqual(wf.nodes[1].name, "write_pkg_init")
        XCTAssertEqual(wf.nodes[1].toolName, "write_file")

        // 6 edges
        XCTAssertEqual(wf.edges.count, 6, "plan_ready should have 6 edges")
        XCTAssertEqual(wf.edges[0].from, "create_dirs")
        XCTAssertEqual(wf.edges[0].to, "write_pkg_init")
    }

    // MARK: - Decode: workflow_task_state_changed

    func testDecodeWorkflowTaskStateChanged() throws {
        let event = try decodeFixture("workflow_task_state_changed_pending_to_running.json")
        guard case .workflowTaskStateChanged(let turnID, let wf)? = event else {
            return XCTFail("expected workflowTaskStateChanged, got \(String(describing: event))")
        }
        XCTAssertEqual(turnID, "turn_42")
        XCTAssertEqual(wf.workflowID, "wf_a1b2c3d4e5f6a7b8")
        XCTAssertEqual(wf.taskID, 1001)
        XCTAssertEqual(wf.rootTaskID, 1001)
        XCTAssertEqual(wf.from, "pending")
        XCTAssertEqual(wf.to, "running")
        XCTAssertEqual(wf.sequence, 5)
        XCTAssertEqual(wf.message, "Task is running")
        XCTAssertEqual(wf.progress, 0)
    }

    // MARK: - Decode: workflow_node_state_changed

    func testDecodeWorkflowNodeStateChanged() throws {
        let event = try decodeFixture("workflow_node_state_changed_pending_to_running.json")
        guard case .workflowNodeStateChanged(let turnID, let wf)? = event else {
            return XCTFail("expected workflowNodeStateChanged, got \(String(describing: event))")
        }
        XCTAssertEqual(turnID, "turn_42")
        XCTAssertEqual(wf.workflowID, "wf_a1b2c3d4e5f6a7b8")
        XCTAssertEqual(wf.taskID, 1001)
        XCTAssertEqual(wf.nodeName, "create_dirs")
        XCTAssertEqual(wf.from, "pending")
        XCTAssertEqual(wf.to, "running")
        XCTAssertEqual(wf.terminal, false)
        XCTAssertEqual(wf.progress, 0)
        XCTAssertEqual(wf.sequence, 6)
        XCTAssertEqual(wf.message, "Node is running")
    }

    func testDecodeWorkflowNodeStateChangedRunningToFailed() throws {
        let event = try decodeFixture("workflow_node_state_changed_running_to_failed.json")
        guard case .workflowNodeStateChanged(_, let wf)? = event else {
            return XCTFail("expected workflowNodeStateChanged, got \(String(describing: event))")
        }
        XCTAssertEqual(wf.nodeName, "write_cli")
        XCTAssertEqual(wf.from, "running")
        XCTAssertEqual(wf.to, "failed")
        XCTAssertEqual(wf.error, "file not found: src/cli.py")
    }

    func testDecodeWorkflowNodeStateChangedToSkipped() throws {
        let event = try decodeFixture("workflow_node_state_changed_pending_to_skipped.json")
        guard case .workflowNodeStateChanged(_, let wf)? = event else {
            return XCTFail("expected workflowNodeStateChanged, got \(String(describing: event))")
        }
        XCTAssertEqual(wf.nodeName, "optional_lint")
        XCTAssertEqual(wf.to, "skipped")
    }

    func testDecodeWorkflowNodeStateChangedToAwaiting() throws {
        let event = try decodeFixture("workflow_node_state_changed_running_to_awaiting.json")
        guard case .workflowNodeStateChanged(_, let wf)? = event else {
            return XCTFail("expected workflowNodeStateChanged, got \(String(describing: event))")
        }
        XCTAssertEqual(wf.nodeName, "get_device_info")
        XCTAssertEqual(wf.to, "awaiting")
        XCTAssertEqual(wf.progress, 0.35)
    }

    // MARK: - Decode: workflow_suspended

    func testDecodeWorkflowSuspended() throws {
        let event = try decodeFixture("workflow_suspended.json")
        guard case .workflowSuspended(let turnID, let wf)? = event else {
            return XCTFail("expected workflowSuspended, got \(String(describing: event))")
        }
        XCTAssertEqual(turnID, "turn_42")
        XCTAssertEqual(wf.workflowID, "wf_a1b2c3d4e5f6a7b8")
        XCTAssertEqual(wf.taskID, 1001)
        XCTAssertEqual(wf.status, "suspended")
        XCTAssertEqual(wf.nodeName, "get_device_info")
        XCTAssertEqual(wf.reason, "client_tool_await")
        XCTAssertEqual(wf.resumable, true)
    }

    // MARK: - Decode: workflow_finished

    func testDecodeWorkflowFinished() throws {
        let event = try decodeFixture("workflow_finished.json")
        guard case .workflowFinished(let turnID, let wf)? = event else {
            return XCTFail("expected workflowFinished, got \(String(describing: event))")
        }
        XCTAssertEqual(turnID, "turn_42")
        XCTAssertEqual(wf.workflowID, "wf_a1b2c3d4e5f6a7b8")
        XCTAssertEqual(wf.taskID, 1001)
        XCTAssertEqual(wf.status, "success")
        XCTAssertNotNil(wf.output)
    }

    // MARK: - Decode: workflow_failed

    func testDecodeWorkflowFailed() throws {
        let event = try decodeFixture("workflow_failed.json")
        guard case .workflowFailed(let turnID, let wf)? = event else {
            return XCTFail("expected workflowFailed, got \(String(describing: event))")
        }
        XCTAssertEqual(turnID, "turn_42")
        XCTAssertEqual(wf.workflowID, "wf_a1b2c3d4e5f6a7b8")
        XCTAssertEqual(wf.status, "failed")
        XCTAssertEqual(wf.error, "node \"run_tests\" failed: exit code 1")
    }

    func testDecodeWorkflowFailedPlanning() throws {
        let event = try decodeFixture("workflow_failed_planning.json")
        guard case .workflowFailed(let turnID, let wf)? = event else {
            return XCTFail("expected workflowFailed, got \(String(describing: event))")
        }
        XCTAssertEqual(turnID, "turn_42")
        XCTAssertEqual(wf.status, "failed")
        XCTAssertEqual(wf.error, "no eligible tools are available")
    }

    // MARK: - Decode: workflow_task_failed / succeeded / suspended (bracket events)

    func testDecodeWorkflowTaskFailed() throws {
        let event = try decodeFixture("workflow_task_failed.json")
        guard case .workflowTaskFailed(let turnID, let wf)? = event else {
            return XCTFail("expected workflowTaskFailed, got \(String(describing: event))")
        }
        XCTAssertEqual(turnID, "turn_42")
        XCTAssertEqual(wf.workflowID, "wf_a1b2c3d4e5f6a7b8")
        XCTAssertEqual(wf.taskID, 1001)
        XCTAssertEqual(wf.rootTaskID, 1001)
        XCTAssertEqual(wf.message, "Task failed")
        XCTAssertEqual(wf.error, "node execution error")
        XCTAssertEqual(wf.progress, 0.5)
        XCTAssertEqual(wf.sequence, 22)
    }

    func testDecodeWorkflowTaskSucceeded() throws {
        let event = try decodeFixture("workflow_task_succeeded.json")
        guard case .workflowTaskSucceeded(let turnID, let wf)? = event else {
            return XCTFail("expected workflowTaskSucceeded, got \(String(describing: event))")
        }
        XCTAssertEqual(turnID, "turn_42")
        XCTAssertEqual(wf.workflowID, "wf_a1b2c3d4e5f6a7b8")
        XCTAssertEqual(wf.taskID, 1001)
        XCTAssertEqual(wf.message, "Task completed successfully")
        XCTAssertEqual(wf.progress, 1)
        XCTAssertEqual(wf.sequence, 25)
    }

    func testDecodeWorkflowTaskSuspended() throws {
        let event = try decodeFixture("workflow_task_suspended.json")
        guard case .workflowTaskSuspended(let turnID, let wf)? = event else {
            return XCTFail("expected workflowTaskSuspended, got \(String(describing: event))")
        }
        XCTAssertEqual(turnID, "turn_42")
        XCTAssertEqual(wf.workflowID, "wf_a1b2c3d4e5f6a7b8")
        XCTAssertEqual(wf.taskID, 1001)
        XCTAssertEqual(wf.message, "Task suspended")
        XCTAssertEqual(wf.progress, 0.35)
        XCTAssertEqual(wf.sequence, 17)
    }

    // MARK: - Decode: workflow_node_progress (transient)

    func testDecodeWorkflowNodeProgress() throws {
        let event = try decodeFixture("workflow_node_progress.json")
        guard case .workflowNodeProgress(let turnID, let wf)? = event else {
            return XCTFail("expected workflowNodeProgress, got \(String(describing: event))")
        }
        XCTAssertEqual(turnID, "turn_42")
        XCTAssertEqual(wf.workflowID, "wf_a1b2c3d4e5f6a7b8")
        XCTAssertEqual(wf.nodeName, "run_tests")
        XCTAssertEqual(wf.progress, 0.7)
    }

    // MARK: - Decode: workflow_tool_log (transient, message field)

    func testDecodeWorkflowToolLog() throws {
        let event = try decodeFixture("workflow_tool_log.json")
        guard case .workflowToolLog(let turnID, let wf)? = event else {
            return XCTFail("expected workflowToolLog, got \(String(describing: event))")
        }
        XCTAssertEqual(turnID, "turn_42")
        XCTAssertEqual(wf.workflowID, "wf_a1b2c3d4e5f6a7b8")
        XCTAssertEqual(wf.nodeName, "run_tests")
        // Golden fixture: log content is in workflow.message
        XCTAssertTrue(wf.chunk.contains("test_reverse_string PASSED"),
                      "tool_log chunk should come from workflow.message")
    }

    // MARK: - Unknown kind forward compatibility

    func testUnknownWorkflowKindDoesNotCrash() throws {
        let json = """
        {"kind":"workflow_future_unknown","session_id":"s1","turn_id":"t1"}
        """
        let event = try decodeEvent(json)
        XCTAssertNil(event, "unknown workflow kind should return nil, not crash")
    }

    // MARK: - Reducer: plan_ready builds DAG from golden fixture data

    func testPlanReadyBuildsDAG() throws {
        let store = makeStore()

        // Use the real golden fixture to build DAG
        let event = try decodeFixture("workflow_plan_ready.json")
        store.reduce(event!)

        guard let run = store.runs["wf_a1b2c3d4e5f6a7b8"] else {
            return XCTFail("run not created")
        }
        XCTAssertEqual(run.goal, "搭建 Python CLI 项目")
        XCTAssertEqual(run.nodes.count, 6)
        XCTAssertEqual(run.nodes["create_dirs"]?.toolName, "run_command")
        XCTAssertEqual(run.nodes["create_dirs"]?.type, "tool")
        // All nodes start as .pending until node_state_changed events arrive
        XCTAssertEqual(run.nodes["create_dirs"]?.state, .pending)
        XCTAssertEqual(run.edges.count, 6)
    }

    // MARK: - Reducer: node state transitions

    func testNodeStateTransitions() {
        let store = makeStore()

        // Setup: plan_ready
        store.reduce(.workflowPlanReady(turnID: "t1", callID: "call_p", workflow: WorkflowPlanReadyData(
            workflowID: "wf_1", parentCallID: "call_p", goal: nil,
            nodes: [WorkflowPlanNode(name: "step1", type: "tool")],
            edges: []
        )))

        // pending → running
        store.reduce(.workflowNodeStateChanged(turnID: "t1", workflow: WorkflowNodeStateChange(
            workflowID: "wf_1", parentCallID: nil, taskID: 1,
            nodeName: "step1", from: "pending", to: "running",
            terminal: false, progress: 0, sequence: 1
        )))
        XCTAssertEqual(store.runs["wf_1"]?.nodes["step1"]?.state, .running)

        // running → success
        store.reduce(.workflowNodeStateChanged(turnID: "t1", workflow: WorkflowNodeStateChange(
            workflowID: "wf_1", parentCallID: nil, taskID: 1,
            nodeName: "step1", from: "running", to: "success",
            terminal: true, progress: 1.0, sequence: 2
        )))
        XCTAssertEqual(store.runs["wf_1"]?.nodes["step1"]?.state, .success)
        XCTAssertTrue(store.runs["wf_1"]?.nodes["step1"]?.terminal ?? false)
    }

    // MARK: - Reducer: client awaiting not terminal

    func testClientAwaitingNotTerminal() {
        let store = makeStore()

        store.reduce(.workflowPlanReady(turnID: "t1", callID: "call_p", workflow: WorkflowPlanReadyData(
            workflowID: "wf_1", parentCallID: "call_p", goal: nil,
            nodes: [WorkflowPlanNode(name: "capture", type: "tool")],
            edges: []
        )))

        // Node → awaiting
        store.reduce(.workflowNodeStateChanged(turnID: "t1", workflow: WorkflowNodeStateChange(
            workflowID: "wf_1", parentCallID: nil, taskID: 1,
            nodeName: "capture", from: "running", to: "awaiting",
            terminal: false, progress: 0.5, sequence: 1
        )))
        XCTAssertEqual(store.runs["wf_1"]?.nodes["capture"]?.state, .awaiting)

        // Task → suspended
        store.reduce(.workflowTaskStateChanged(turnID: "t1", workflow: WorkflowTaskStateChange(
            workflowID: "wf_1", taskID: 1, from: "running", to: "suspended", sequence: 2
        )))
        XCTAssertEqual(store.runs["wf_1"]?.status, .suspended)

        // suspended 不是终态
        XCTAssertFalse(store.runs["wf_1"]?.status.isTerminal ?? true)
        // awaiting 也不是终态
        XCTAssertFalse(store.runs["wf_1"]?.nodes["capture"]?.state.isTerminal ?? true)
    }

    // MARK: - Reducer: workflow finished

    func testWorkflowFinished() {
        let store = makeStore()

        store.reduce(.workflowPlanReady(turnID: "t1", callID: "call_p", workflow: WorkflowPlanReadyData(
            workflowID: "wf_1", parentCallID: "call_p", goal: nil,
            nodes: [WorkflowPlanNode(name: "a", type: "start")],
            edges: []
        )))

        let output = JSONValue.object(["result": .string("done")])
        store.reduce(.workflowFinished(turnID: "t1", workflow: WorkflowFinishedData(
            workflowID: "wf_1", taskID: 1, status: "success", output: output
        )))

        XCTAssertEqual(store.runs["wf_1"]?.status, .success)
        XCTAssertNotNil(store.runs["wf_1"]?.output)
        XCTAssertTrue(store.runs["wf_1"]?.status.isTerminal ?? false)
    }

    // MARK: - Reducer: workflow failed

    func testWorkflowFailed() {
        let store = makeStore()

        store.reduce(.workflowPlanReady(turnID: "t1", callID: "call_p", workflow: WorkflowPlanReadyData(
            workflowID: "wf_1", parentCallID: "call_p", goal: nil,
            nodes: [WorkflowPlanNode(name: "bad", type: "tool")],
            edges: []
        )))

        // Mark node as failed
        store.reduce(.workflowNodeStateChanged(turnID: "t1", workflow: WorkflowNodeStateChange(
            workflowID: "wf_1", parentCallID: nil, taskID: 1,
            nodeName: "bad", from: "running", to: "failed",
            terminal: true, progress: 0.8, sequence: 1,
            error: "permission denied"
        )))

        // Workflow-level failed
        store.reduce(.workflowFailed(turnID: "t1", workflow: WorkflowFailedData(
            workflowID: "wf_1", taskID: 1, status: "failed", error: "node bad failed"
        )))

        XCTAssertEqual(store.runs["wf_1"]?.status, .failed)
        XCTAssertEqual(store.runs["wf_1"]?.error, "node bad failed")
        XCTAssertEqual(store.runs["wf_1"]?.nodes["bad"]?.state, .failed)
        XCTAssertEqual(store.runs["wf_1"]?.nodes["bad"]?.error, "permission denied")
    }

    // MARK: - Reducer: task bracket events

    func testWorkflowTaskBracketFailed() {
        let store = makeStore()

        store.reduce(.workflowPlanReady(turnID: "t1", callID: "call_p", workflow: WorkflowPlanReadyData(
            workflowID: "wf_1", parentCallID: "call_p", goal: nil,
            nodes: [WorkflowPlanNode(name: "n", type: "tool")],
            edges: []
        )))

        store.reduce(.workflowTaskFailed(turnID: "t1", workflow: WorkflowTaskBracketData(
            workflowID: "wf_1", taskID: 1, rootTaskID: 1,
            message: "Task failed", error: "node execution error",
            progress: 0.5, sequence: 22
        )))

        XCTAssertEqual(store.runs["wf_1"]?.status, .failed)
        XCTAssertEqual(store.runs["wf_1"]?.error, "node execution error")
        XCTAssertEqual(store.runs["wf_1"]?.lastSequence, 22)
    }

    func testWorkflowTaskBracketSucceeded() {
        let store = makeStore()

        store.reduce(.workflowPlanReady(turnID: "t1", callID: "call_p", workflow: WorkflowPlanReadyData(
            workflowID: "wf_1", parentCallID: "call_p", goal: nil,
            nodes: [WorkflowPlanNode(name: "n", type: "tool")],
            edges: []
        )))

        store.reduce(.workflowTaskSucceeded(turnID: "t1", workflow: WorkflowTaskBracketData(
            workflowID: "wf_1", taskID: 1, rootTaskID: 1,
            message: "Task completed", progress: 1, sequence: 25
        )))

        XCTAssertEqual(store.runs["wf_1"]?.status, .success)
        XCTAssertEqual(store.runs["wf_1"]?.lastSequence, 25)
    }

    func testWorkflowTaskBracketSuspended() {
        let store = makeStore()

        store.reduce(.workflowPlanReady(turnID: "t1", callID: "call_p", workflow: WorkflowPlanReadyData(
            workflowID: "wf_1", parentCallID: "call_p", goal: nil,
            nodes: [WorkflowPlanNode(name: "n", type: "tool")],
            edges: []
        )))

        store.reduce(.workflowTaskSuspended(turnID: "t1", workflow: WorkflowTaskBracketData(
            workflowID: "wf_1", taskID: 1, rootTaskID: 1,
            message: "Task suspended", progress: 0.35, sequence: 17
        )))

        XCTAssertEqual(store.runs["wf_1"]?.status, .suspended)
        XCTAssertFalse(store.runs["wf_1"]?.status.isTerminal ?? true)
    }

    // MARK: - Seq idempotent

    func testSeqIdempotent() {
        let store = makeStore()

        store.reduce(.workflowPlanReady(turnID: "t1", callID: "call_p", workflow: WorkflowPlanReadyData(
            workflowID: "wf_1", parentCallID: "call_p", goal: nil,
            nodes: [WorkflowPlanNode(name: "n", type: "tool")],
            edges: []
        )))

        // First apply: seq 5, state → running
        store.reduce(.workflowNodeStateChanged(turnID: "t1", workflow: WorkflowNodeStateChange(
            workflowID: "wf_1", parentCallID: nil, taskID: 1,
            nodeName: "n", from: "ready", to: "running",
            terminal: false, progress: 0.3, sequence: 5
        )))
        XCTAssertEqual(store.runs["wf_1"]?.nodes["n"]?.state, .running)

        // Duplicate: same seq 5 — should be IGNORED
        store.reduce(.workflowNodeStateChanged(turnID: "t1", workflow: WorkflowNodeStateChange(
            workflowID: "wf_1", parentCallID: nil, taskID: 1,
            nodeName: "n", from: "running", to: "success",
            terminal: true, progress: 1.0, sequence: 5
        )))
        XCTAssertEqual(store.runs["wf_1"]?.nodes["n"]?.state, .running,
                       "duplicate seq should be ignored")

        // Newer seq: 6, should be applied
        store.reduce(.workflowNodeStateChanged(turnID: "t1", workflow: WorkflowNodeStateChange(
            workflowID: "wf_1", parentCallID: nil, taskID: 1,
            nodeName: "n", from: "running", to: "success",
            terminal: true, progress: 1.0, sequence: 6
        )))
        XCTAssertEqual(store.runs["wf_1"]?.nodes["n"]?.state, .success)
    }

    // MARK: - Unknown states do not crash

    func testUnknownNodeStateNoCrash() {
        let store = makeStore()

        store.reduce(.workflowPlanReady(turnID: "t1", callID: "call_p", workflow: WorkflowPlanReadyData(
            workflowID: "wf_1", parentCallID: "call_p", goal: nil,
            nodes: [WorkflowPlanNode(name: "n", type: "tool")],
            edges: []
        )))

        store.reduce(.workflowNodeStateChanged(turnID: "t1", workflow: WorkflowNodeStateChange(
            workflowID: "wf_1", parentCallID: nil, taskID: 1,
            nodeName: "n", from: "running", to: "future_state_v99",
            terminal: true, progress: 0.5, sequence: 1
        )))

        guard let node = store.runs["wf_1"]?.nodes["n"] else {
            return XCTFail("node not found")
        }
        if case .unknown(let v) = node.state {
            XCTAssertEqual(v, "future_state_v99")
        } else {
            XCTFail("expected .unknown, got \(node.state)")
        }
        XCTAssertTrue(node.terminal)
    }

    func testUnknownTaskStatusNoCrash() {
        let store = makeStore()

        store.reduce(.workflowPlanReady(turnID: "t1", callID: "call_p", workflow: WorkflowPlanReadyData(
            workflowID: "wf_1", parentCallID: "call_p", goal: nil,
            nodes: [WorkflowPlanNode(name: "n", type: "tool")],
            edges: []
        )))

        store.reduce(.workflowTaskStateChanged(turnID: "t1", workflow: WorkflowTaskStateChange(
            workflowID: "wf_1", taskID: 1, from: "running", to: "future_status_v42", sequence: 1
        )))

        guard let run = store.runs["wf_1"] else {
            return XCTFail("run not found")
        }
        if case .unknown(let v) = run.status {
            XCTAssertEqual(v, "future_status_v42")
        } else {
            XCTFail("expected .unknown, got \(run.status)")
        }
    }

    // MARK: - Replay rebuilds DAG

    func testReplayRebuildsDAG() {
        let store = makeStore()

        let events: [AgentEvent] = [
            .workflowStarted(turnID: "t1", callID: "call_p", workflowID: "wf_1"),
            .workflowPlanReady(turnID: "t1", callID: "call_p", workflow: WorkflowPlanReadyData(
                workflowID: "wf_1", parentCallID: "call_p", goal: "Replay test",
                nodes: [WorkflowPlanNode(name: "x", type: "tool")],
                edges: []
            )),
            .workflowNodeStateChanged(turnID: "t1", workflow: WorkflowNodeStateChange(
                workflowID: "wf_1", parentCallID: nil, taskID: 1,
                nodeName: "x", from: "pending", to: "running",
                terminal: false, progress: 0.5, sequence: 1
            )),
            .workflowNodeStateChanged(turnID: "t1", workflow: WorkflowNodeStateChange(
                workflowID: "wf_1", parentCallID: nil, taskID: 1,
                nodeName: "x", from: "running", to: "success",
                terminal: true, progress: 1.0, sequence: 2
            )),
            .workflowTaskSucceeded(turnID: "t1", workflow: WorkflowTaskBracketData(
                workflowID: "wf_1", taskID: 1, message: "done", progress: 1, sequence: 3
            )),
        ]

        store.replay(events)

        guard let run = store.runs["wf_1"] else {
            return XCTFail("run not created after replay")
        }
        XCTAssertEqual(run.goal, "Replay test")
        XCTAssertEqual(run.nodes.count, 1)
        XCTAssertEqual(run.nodes["x"]?.state, .success)
        XCTAssertEqual(run.status, .success)
        XCTAssertEqual(run.lastSequence, 3)
    }

    // MARK: - Transient does not update lastSequence

    func testTransientDoesNotUpdateLastSequence() {
        let store = makeStore()

        store.reduce(.workflowPlanReady(turnID: "t1", callID: "call_p", workflow: WorkflowPlanReadyData(
            workflowID: "wf_1", parentCallID: "call_p", goal: nil,
            nodes: [WorkflowPlanNode(name: "n", type: "tool")],
            edges: []
        )))
        store.reduce(.workflowNodeStateChanged(turnID: "t1", workflow: WorkflowNodeStateChange(
            workflowID: "wf_1", parentCallID: nil, taskID: 1,
            nodeName: "n", from: "pending", to: "running",
            terminal: false, progress: 0, sequence: 10
        )))
        XCTAssertEqual(store.runs["wf_1"]?.lastSequence, 10)

        // Transient progress — no seq
        store.reduce(.workflowNodeProgress(turnID: "t1", workflow: WorkflowProgressData(
            workflowID: "wf_1", nodeName: "n", progress: 0.5
        )))

        // lastSequence should NOT have changed
        XCTAssertEqual(store.runs["wf_1"]?.lastSequence, 10)
        // But progress should be updated
        XCTAssertEqual(store.runs["wf_1"]?.nodes["n"]?.progress, 0.5)
    }

    // MARK: - Tool stream/log accumulation

    func testToolStreamAccumulation() {
        let store = makeStore()

        store.reduce(.workflowPlanReady(turnID: "t1", callID: "call_p", workflow: WorkflowPlanReadyData(
            workflowID: "wf_1", parentCallID: "call_p", goal: nil,
            nodes: [WorkflowPlanNode(name: "build", type: "tool")],
            edges: []
        )))

        store.reduce(.workflowToolLog(turnID: "t1", workflow: WorkflowToolStreamData(
            workflowID: "wf_1", nodeName: "build", chunk: "Compiling...\n"
        )))
        store.reduce(.workflowToolStream(turnID: "t1", workflow: WorkflowToolStreamData(
            workflowID: "wf_1", nodeName: "build", chunk: "Linking...\n"
        )))

        let output = store.runs["wf_1"]?.nodes["build"]?.streamOutput
        XCTAssertEqual(output, "Compiling...\nLinking...\n")
    }

    // MARK: - Suspended state workflow

    func testSuspendedWorkflowTracksNode() {
        let store = makeStore()

        store.reduce(.workflowPlanReady(turnID: "t1", callID: "call_p", workflow: WorkflowPlanReadyData(
            workflowID: "wf_1", parentCallID: "call_p", goal: nil,
            nodes: [WorkflowPlanNode(name: "camera", type: "tool")],
            edges: []
        )))

        store.reduce(.workflowNodeStateChanged(turnID: "t1", workflow: WorkflowNodeStateChange(
            workflowID: "wf_1", parentCallID: nil, taskID: 1,
            nodeName: "camera", from: "running", to: "awaiting",
            terminal: false, progress: 0.3, sequence: 1
        )))

        store.reduce(.workflowSuspended(turnID: "t1", workflow: WorkflowSuspendedData(
            workflowID: "wf_1", parentCallID: nil, taskID: 1,
            status: "suspended", nodeName: "camera",
            reason: "等待相机权限", resumable: true
        )))

        let run = store.runs["wf_1"]
        XCTAssertEqual(run?.status, .suspended)
        XCTAssertEqual(run?.suspendedNodeName, "camera")
        XCTAssertEqual(run?.nodes["camera"]?.state, .awaiting)
        XCTAssertFalse(run?.status.isTerminal ?? true)
    }

    // MARK: - Multiple workflow runs coexist

    func testMultipleWorkflowRunsCoexist() {
        let store = makeStore()

        store.reduce(.workflowPlanReady(turnID: "t1", callID: "call_a", workflow: WorkflowPlanReadyData(
            workflowID: "wf_a", parentCallID: "call_a", goal: "A",
            nodes: [WorkflowPlanNode(name: "na", type: "tool")],
            edges: []
        )))

        store.reduce(.workflowPlanReady(turnID: "t2", callID: "call_b", workflow: WorkflowPlanReadyData(
            workflowID: "wf_b", parentCallID: "call_b", goal: "B",
            nodes: [WorkflowPlanNode(name: "nb", type: "tool")],
            edges: []
        )))

        XCTAssertEqual(store.runs.count, 2)
        XCTAssertEqual(store.runs["wf_a"]?.goal, "A")
        XCTAssertEqual(store.runs["wf_b"]?.goal, "B")

        // Update wf_a independently
        store.reduce(.workflowNodeStateChanged(turnID: "t1", workflow: WorkflowNodeStateChange(
            workflowID: "wf_a", parentCallID: nil, taskID: 1,
            nodeName: "na", from: "pending", to: "success",
            terminal: true, progress: 1.0, sequence: 1
        )))

        XCTAssertEqual(store.runs["wf_a"]?.nodes["na"]?.state, .success)
        // wf_b untouched
        XCTAssertEqual(store.runs["wf_b"]?.nodes["nb"]?.state, .pending)
    }

    // MARK: - Workflow started event

    func testWorkflowStartedCreatesEmptyRun() {
        let store = makeStore()

        store.reduce(.workflowStarted(turnID: "t1", callID: "call_p", workflowID: "wf_new"))

        guard let run = store.runs["wf_new"] else {
            return XCTFail("run not created")
        }
        XCTAssertEqual(run.parentCallID, "call_p")
        XCTAssertEqual(run.status, .pending)
        XCTAssertEqual(run.nodes.count, 0)
        XCTAssertEqual(run.edges.count, 0)
    }

    // MARK: - Nil-sequence events are applied (not dropped)

    /// 当服务端未填充 sequence 字段时，事件 payload 的 sequence 为 nil，
    /// 此时事件应该被无条件应用，而不是被 seq 去重逻辑丢弃。
    func testNilSequenceEventsAreApplied() {
        let store = makeStore()

        store.reduce(.workflowPlanReady(turnID: "t1", callID: "call_p", workflow: WorkflowPlanReadyData(
            workflowID: "wf_1", parentCallID: "call_p", goal: nil,
            nodes: [WorkflowPlanNode(name: "n", type: "tool")],
            edges: []
        )))

        // Simulate node_state_changed WITHOUT a sequence (server hasn't implemented seq yet)
        store.reduce(.workflowNodeStateChanged(turnID: "t1", workflow: WorkflowNodeStateChange(
            workflowID: "wf_1", parentCallID: nil, taskID: 1,
            nodeName: "n", from: "pending", to: "running",
            terminal: false, progress: 0.3,
            sequence: nil  // ← KEY: no sequence
        )))
        XCTAssertEqual(store.runs["wf_1"]?.nodes["n"]?.state, .running,
                       "nil-sequence events should be applied unconditionally")
        XCTAssertEqual(store.runs["wf_1"]?.lastSequence, 0,
                       "nil-sequence events should not update lastSequence")

        // Second nil-sequence event should also be applied (not dropped as duplicate)
        store.reduce(.workflowNodeStateChanged(turnID: "t1", workflow: WorkflowNodeStateChange(
            workflowID: "wf_1", parentCallID: nil, taskID: 1,
            nodeName: "n", from: "running", to: "success",
            terminal: true, progress: 1.0,
            sequence: nil
        )))
        XCTAssertEqual(store.runs["wf_1"]?.nodes["n"]?.state, .success,
                       "multiple nil-seq events should all be applied")

        // task_state_changed with nil sequence
        store.reduce(.workflowTaskStateChanged(turnID: "t1", workflow: WorkflowTaskStateChange(
            workflowID: "wf_1", taskID: 1, from: "running", to: "success",
            sequence: nil
        )))
        XCTAssertEqual(store.runs["wf_1"]?.status, .success,
                       "nil-seq task state change should also be applied")
    }

    // MARK: - Phase 4: Snapshot decode

    func testDecodeSnapshot() throws {
        let json = """
        {
            "workflow_id": "wf_test",
            "goal": "Snapshot test",
            "task": {"id": 100, "status": "success", "progress": 1.0, "output": {"result": "ok"}},
            "nodes": [
                {"name": "a", "state": "success", "terminal": true, "active": false},
                {"name": "b", "state": "failed", "terminal": true, "active": false, "error": "boom", "progress": 0.3}
            ],
            "edges": [{"from": "a", "to": "b"}],
            "snapshot_sequence": 42
        }
        """
        let snapshot = try JSONDecoder().decode(WorkflowSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.workflowId, "wf_test")
        XCTAssertEqual(snapshot.goal, "Snapshot test")
        XCTAssertEqual(snapshot.snapshotSequence, 42)
        XCTAssertEqual(snapshot.task?.id, 100)
        XCTAssertEqual(snapshot.task?.status, "success")
        XCTAssertEqual(snapshot.nodes.count, 2)
        XCTAssertEqual(snapshot.nodes[0].name, "a")
        XCTAssertEqual(snapshot.nodes[0].state, "success")
        XCTAssertTrue(snapshot.nodes[0].terminal)
        XCTAssertEqual(snapshot.nodes[1].state, "failed")
        XCTAssertEqual(snapshot.nodes[1].error, "boom")
        XCTAssertEqual(snapshot.nodes[1].progress, 0.3)
        XCTAssertEqual(snapshot.edges.count, 1)
        XCTAssertEqual(snapshot.edges[0].from, "a")
        XCTAssertEqual(snapshot.edges[0].to, "b")
    }

    // MARK: - Phase 4: applySnapshot builds complete DAG with correct states

    func testApplySnapshotBuildsCompleteDAG() {
        let store = makeStore()

        let snapshot = WorkflowSnapshot(
            workflowId: "wf_snap", goal: "Complete DAG",
            task: WorkflowSnapshotTask(id: 200, status: "success", progress: 1.0, output: nil),
            nodes: [
                WorkflowSnapshotNode(name: "start", state: "success", terminal: true, active: false, error: nil, progress: 1.0, output: nil),
                WorkflowSnapshotNode(name: "step1", state: "success", terminal: true, active: false, error: nil, progress: 1.0, output: nil),
                WorkflowSnapshotNode(name: "step2", state: "failed", terminal: true, active: false, error: "timeout", progress: 0.5, output: nil),
                WorkflowSnapshotNode(name: "end", state: "skipped", terminal: true, active: false, error: nil, progress: 0, output: nil),
            ],
            edges: [WorkflowSnapshotEdge(from: "start", to: "step1"),
                     WorkflowSnapshotEdge(from: "step1", to: "step2"),
                     WorkflowSnapshotEdge(from: "step2", to: "end")],
            snapshotSequence: 42
        )

        store.applySnapshot(snapshot)

        guard let run = store.runs["wf_snap"] else {
            return XCTFail("run not created from snapshot")
        }

        XCTAssertEqual(run.goal, "Complete DAG")
        XCTAssertEqual(run.status, .success)
        XCTAssertEqual(run.taskID, 200)
        XCTAssertEqual(run.nodes.count, 4)
        XCTAssertEqual(run.nodes["step1"]?.state, .success)
        XCTAssertEqual(run.nodes["step2"]?.state, .failed)
        XCTAssertEqual(run.nodes["step2"]?.error, "timeout")
        XCTAssertEqual(run.nodes["end"]?.state, .skipped)
        XCTAssertEqual(run.edges.count, 3)
        XCTAssertEqual(run.lastSequence, 42)
    }

    // MARK: - Phase 4: Events with seq <= snapshotSequence are filtered

    func testSnapshotSequenceFiltersIncrementalEvents() {
        let store = makeStore()

        // Apply snapshot with seq 42
        let snapshot = WorkflowSnapshot(
            workflowId: "wf_snap", goal: nil,
            task: WorkflowSnapshotTask(id: 1, status: "running", progress: 0.5, output: nil),
            nodes: [WorkflowSnapshotNode(name: "n", state: "running", terminal: false, active: true, error: nil, progress: 0.5, output: nil)],
            edges: [],
            snapshotSequence: 42
        )
        store.applySnapshot(snapshot)
        XCTAssertEqual(store.runs["wf_snap"]?.nodes["n"]?.state, .running)

        // Event with seq 30 (<= 42) should be DROPPED
        store.reduce(.workflowNodeStateChanged(turnID: "t1", workflow: WorkflowNodeStateChange(
            workflowID: "wf_snap", parentCallID: nil, taskID: 1,
            nodeName: "n", from: "running", to: "success",
            terminal: true, progress: 1.0, sequence: 30
        )))
        XCTAssertEqual(store.runs["wf_snap"]?.nodes["n"]?.state, .running,
                       "seq 30 <= 42 should be dropped as already covered by snapshot")

        // Event with seq 50 (> 42) should be APPLIED
        store.reduce(.workflowNodeStateChanged(turnID: "t1", workflow: WorkflowNodeStateChange(
            workflowID: "wf_snap", parentCallID: nil, taskID: 1,
            nodeName: "n", from: "running", to: "success",
            terminal: true, progress: 1.0, sequence: 50
        )))
        XCTAssertEqual(store.runs["wf_snap"]?.nodes["n"]?.state, .success,
                       "seq 50 > 42 should be applied")
        XCTAssertEqual(store.runs["wf_snap"]?.lastSequence, 50)
    }
}
