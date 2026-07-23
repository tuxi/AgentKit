//
//  WorkflowTests.swift
//  AgentKitTests
//
//  Flux Workflow DAG — decode + reducer 测试。
//  对照协议：runtime-event-contract-v1.md §5.8。
//  使用 fixtures/flux-workflow/*.json golden files。
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

    private func decodeEvent(fromFixture name: String) throws -> AgentEvent? {
        // Fixtures are at Tests/AgentKitTests/Fixtures/flux-workflow/
        let fixtureDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/flux-workflow")
        let url = fixtureDir.appendingPathComponent(name)
        let json = try String(contentsOf: url, encoding: .utf8)
        return try decodeEvent(json)
    }

    private func makeStore() -> WorkflowStore {
        WorkflowStore()
    }

    // MARK: - Decode tests (fixtures)

    func testDecodeWorkflowPlanReady() throws {
        let event = try decodeEvent(fromFixture: "workflow_plan_ready.json")
        guard case .workflowPlanReady(let turnID, let callID, let wf)? = event else {
            return XCTFail("expected workflowPlanReady, got \(String(describing: event))")
        }
        XCTAssertEqual(turnID, "turn_1")
        XCTAssertEqual(callID, "call_plan_1")
        XCTAssertEqual(wf.workflowID, "wf_0123456789abcdef")
        XCTAssertEqual(wf.goal, "读取项目并生成报告")
        XCTAssertEqual(wf.nodes.count, 3)
        XCTAssertEqual(wf.nodes[0].name, "start")
        XCTAssertEqual(wf.nodes[0].type, "start")
        XCTAssertEqual(wf.nodes[1].name, "read")
        XCTAssertEqual(wf.nodes[1].type, "tool")
        XCTAssertEqual(wf.edges.count, 2)
        XCTAssertEqual(wf.edges[0].from, "start")
        XCTAssertEqual(wf.edges[0].to, "read")
    }

    func testDecodeWorkflowNodeStateChanged() throws {
        let event = try decodeEvent(fromFixture: "workflow_node_state_changed.json")
        guard case .workflowNodeStateChanged(let turnID, let wf)? = event else {
            return XCTFail("expected workflowNodeStateChanged, got \(String(describing: event))")
        }
        XCTAssertEqual(turnID, "turn_1")
        XCTAssertEqual(wf.workflowID, "wf_0123456789abcdef")
        XCTAssertEqual(wf.taskID, 1001)
        XCTAssertEqual(wf.nodeName, "read")
        XCTAssertEqual(wf.from, "ready")
        XCTAssertEqual(wf.to, "running")
        XCTAssertEqual(wf.terminal, false)
        XCTAssertEqual(wf.progress, 0)
        XCTAssertEqual(wf.sequence, 104)
    }

    func testDecodeWorkflowClientAwaiting() throws {
        let event = try decodeEvent(fromFixture: "workflow_client_awaiting.json")
        guard case .workflowNodeStateChanged(_, let wf)? = event else {
            return XCTFail("expected workflowNodeStateChanged, got \(String(describing: event))")
        }
        XCTAssertEqual(wf.workflowID, "wf_0123456789abcdef")
        XCTAssertEqual(wf.nodeName, "capture")
        XCTAssertEqual(wf.from, "running")
        XCTAssertEqual(wf.to, "awaiting")
        XCTAssertEqual(wf.terminal, false)
    }

    func testDecodeWorkflowSuspended() throws {
        let event = try decodeEvent(fromFixture: "workflow_suspended.json")
        guard case .workflowSuspended(_, let wf)? = event else {
            return XCTFail("expected workflowSuspended, got \(String(describing: event))")
        }
        XCTAssertEqual(wf.workflowID, "wf_0123456789abcdef")
        XCTAssertEqual(wf.status, "suspended")
        XCTAssertEqual(wf.nodeName, "capture")
        XCTAssertEqual(wf.reason, "workflow suspended: async node")
        XCTAssertEqual(wf.resumable, true)
    }

    func testDecodeWorkflowFinished() throws {
        let event = try decodeEvent(fromFixture: "workflow_finished.json")
        guard case .workflowFinished(_, let wf)? = event else {
            return XCTFail("expected workflowFinished, got \(String(describing: event))")
        }
        XCTAssertEqual(wf.workflowID, "wf_0123456789abcdef")
        XCTAssertEqual(wf.taskID, 1001)
        XCTAssertEqual(wf.status, "success")
        XCTAssertNotNil(wf.output)
    }

    // MARK: - Unknown kind forward compatibility

    func testUnknownWorkflowKindDoesNotCrash() throws {
        let json = """
        {"kind":"workflow_future_unknown","session_id":"s1","turn_id":"t1"}
        """
        let event = try decodeEvent(json)
        XCTAssertNil(event, "unknown workflow kind should return nil, not crash")
    }

    // MARK: - Reducer: plan_ready builds DAG

    func testPlanReadyBuildsDAG() {
        let store = makeStore()

        // Simulate workflow_started
        store.reduce(.workflowStarted(turnID: "t1", callID: "call_p", workflowID: "wf_1"))

        // Simulate workflow_plan_ready
        let planReady = WorkflowPlanReadyData(
            workflowID: "wf_1",
            parentCallID: "call_p",
            goal: "Test DAG",
            nodes: [
                WorkflowPlanNode(name: "a", type: "start"),
                WorkflowPlanNode(name: "b", type: "tool", toolName: "read_file"),
                WorkflowPlanNode(name: "c", type: "end"),
            ],
            edges: [
                WorkflowEdge(from: "a", to: "b"),
                WorkflowEdge(from: "b", to: "c"),
            ]
        )
        store.reduce(.workflowPlanReady(turnID: "t1", callID: "call_p", workflow: planReady))

        guard let run = store.runs["wf_1"] else {
            return XCTFail("run not created")
        }
        XCTAssertEqual(run.goal, "Test DAG")
        XCTAssertEqual(run.nodes.count, 3)
        XCTAssertEqual(run.nodes["a"]?.type, "start")
        XCTAssertEqual(run.nodes["b"]?.toolName, "read_file")
        XCTAssertEqual(run.edges.count, 2)
    }

    // MARK: - Reducer: node state transitions

    func testNodeStateTransitions() {
        let store = makeStore()

        // Setup: plan_ready
        let planReady = WorkflowPlanReadyData(
            workflowID: "wf_1", parentCallID: "call_p", goal: nil,
            nodes: [WorkflowPlanNode(name: "step1", type: "tool")],
            edges: []
        )
        store.reduce(.workflowPlanReady(turnID: "t1", callID: "call_p", workflow: planReady))

        // pending → ready
        store.reduce(.workflowNodeStateChanged(turnID: "t1", workflow: WorkflowNodeStateChange(
            workflowID: "wf_1", parentCallID: nil, taskID: 1,
            nodeName: "step1", from: "pending", to: "ready",
            terminal: false, progress: 0, sequence: 1
        )))
        XCTAssertEqual(store.runs["wf_1"]?.nodes["step1"]?.state, .ready)

        // ready → running
        store.reduce(.workflowNodeStateChanged(turnID: "t1", workflow: WorkflowNodeStateChange(
            workflowID: "wf_1", parentCallID: nil, taskID: 1,
            nodeName: "step1", from: "ready", to: "running",
            terminal: false, progress: 0.2, sequence: 2
        )))
        XCTAssertEqual(store.runs["wf_1"]?.nodes["step1"]?.state, .running)
        XCTAssertEqual(store.runs["wf_1"]?.nodes["step1"]?.progress, 0.2)

        // running → success
        store.reduce(.workflowNodeStateChanged(turnID: "t1", workflow: WorkflowNodeStateChange(
            workflowID: "wf_1", parentCallID: nil, taskID: 1,
            nodeName: "step1", from: "running", to: "success",
            terminal: true, progress: 1.0, sequence: 3
        )))
        XCTAssertEqual(store.runs["wf_1"]?.nodes["step1"]?.state, .success)
        XCTAssertTrue(store.runs["wf_1"]?.nodes["step1"]?.terminal ?? false)
    }

    // MARK: - Reducer: client awaiting not terminal

    func testClientAwaitingNotTerminal() {
        let store = makeStore()

        // Setup
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

        // Duplicate: same seq 5, state → success — should be IGNORED
        store.reduce(.workflowNodeStateChanged(turnID: "t1", workflow: WorkflowNodeStateChange(
            workflowID: "wf_1", parentCallID: nil, taskID: 1,
            nodeName: "n", from: "running", to: "success",
            terminal: true, progress: 1.0, sequence: 5
        )))
        // State should still be .running (seq 5 was already applied)
        XCTAssertEqual(store.runs["wf_1"]?.nodes["n"]?.state, .running)

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

        // Unknown state string
        store.reduce(.workflowNodeStateChanged(turnID: "t1", workflow: WorkflowNodeStateChange(
            workflowID: "wf_1", parentCallID: nil, taskID: 1,
            nodeName: "n", from: "running", to: "future_state_v99",
            terminal: true, progress: 0.5, sequence: 1
        )))

        guard let node = store.runs["wf_1"]?.nodes["n"] else {
            return XCTFail("node not found")
        }

        // Should be .unknown (no crash)
        if case .unknown(let v) = node.state {
            XCTAssertEqual(v, "future_state_v99")
        } else {
            XCTFail("expected .unknown, got \(node.state)")
        }

        // terminal=true → should be treated as terminal
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
            .workflowTaskStateChanged(turnID: "t1", workflow: WorkflowTaskStateChange(
                workflowID: "wf_1", taskID: 1, from: "running", to: "success", sequence: 3
            )),
            .workflowFinished(turnID: "t1", workflow: WorkflowFinishedData(
                workflowID: "wf_1", taskID: 1, status: "success",
                output: .object(["done": .bool(true)])
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
        XCTAssertNotNil(run.output)
    }

    // MARK: - Transient does not update lastSequence

    func testTransientDoesNotUpdateLastSequence() {
        let store = makeStore()

        // Setup with seq 10
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

        let seqAfterStateChange = store.runs["wf_1"]?.lastSequence
        XCTAssertEqual(seqAfterStateChange, 10)

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
}
