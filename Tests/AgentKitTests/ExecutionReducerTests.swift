//
//  ExecutionReducerTests.swift
//  AgentKitTests
//
//  Phase A: assistant text segmentation. Live streaming must split assistant
//  text into separate, correctly-positioned nodes at tool / invocation
//  boundaries — not one concatenated node forced to the turn end.
//

import XCTest
@testable import AgentKit

final class ExecutionReducerTests: XCTestCase {

    private func todoArguments(
        content: String = "Create skill",
        activeFormKey: String = "activeForm"
    ) -> JSONValue {
        .object([
            "todos": .array([
                .object([
                    "content": .string(content),
                    activeFormKey: .string("Creating skill"),
                    "status": .string("in_progress"),
                ]),
            ]),
        ])
    }

    private func assistantTexts(_ graph: ExecutionGraph) -> [String] {
        graph.linearWalk().compactMap { node in
            if case .assistantMessage(let t, _) = node.payload { return t }
            return nil
        }
    }

    private func firstIndex(_ nodes: [GraphNode], where predicate: (GraphNode) -> Bool) -> Int? {
        nodes.firstIndex(where: predicate)
    }

    func testTurnFailedFinalizesRunningNodesAndAppendsError() {
        var reducer = ExecutionReducer()
        var graph = ExecutionGraph()
        let turn = "t1"
        let events: [AgentEvent] = [
            .turnStarted(turnID: turn, text: "check commit"),
            .toolStarted(turnID: turn, callID: "c1",
                         tool: ToolCall(callID: "c1", toolName: "git_status", toolArgs: nil)),
            .turnFailed(turnID: turn, text: nil, err: "model api error: status=401", errorCode: "auth_expired"),
        ]

        for event in events { _ = reducer.reduce(event, into: &graph) }

        XCTAssertFalse(graph.nodes.values.contains { $0.turnID == turn && $0.status == .running })
        XCTAssertEqual(graph.nodes["c1"]?.status, .failed)
        XCTAssertTrue(graph.nodes.values.contains { node in
            guard case .system(let payload) = node.payload else { return false }
            return payload.kind == .error && payload.text.contains("status=401")
        })
    }

    func testLocalCancelFinalizesRunningNodes() {
        var reducer = ExecutionReducer()
        var graph = ExecutionGraph()
        let turn = "t1"
        _ = reducer.reduce(.turnStarted(turnID: turn, text: "check commit"), into: &graph)
        _ = reducer.reduce(.toolStarted(turnID: turn, callID: "c1",
                                        tool: ToolCall(callID: "c1", toolName: "git_status", toolArgs: nil)), into: &graph)

        reducer.cancelActiveTurn(turnID: turn, graph: &graph)

        XCTAssertFalse(graph.nodes.values.contains { $0.turnID == turn && $0.status == .running })
        XCTAssertEqual(graph.nodes["c1"]?.status, .cancelled)
    }

    func testPersistedTurnCancelledReplaysAsCancelled() {
        var reducer = ExecutionReducer()
        var graph = ExecutionGraph()
        let turn = "t1"
        _ = reducer.reduce(.turnStarted(turnID: turn, text: "check commit"), into: &graph)
        _ = reducer.reduce(.toolStarted(
            turnID: turn,
            callID: "c1",
            tool: ToolCall(callID: "c1", toolName: "git_status", toolArgs: nil)
        ), into: &graph)

        _ = reducer.reduce(.turnCancelled(turnID: turn, reason: "user_requested"), into: &graph)

        XCTAssertFalse(graph.nodes.values.contains { $0.turnID == turn && $0.status == .running })
        XCTAssertEqual(graph.nodes["c1"]?.status, .cancelled)
        XCTAssertFalse(graph.nodes.values.contains { node in
            if case .system(let payload) = node.payload { return payload.kind == .error }
            return false
        })
    }

    func testRuntimeEngineCancelClearsWorkingIndicatorAndToolSpinner() async {
        let engine = RuntimeEngine(sessionID: "session_1")
        await engine.ingest(.turnStarted(turnID: "t1", text: "check commit"))
        await engine.ingest(.toolStarted(
            turnID: "t1",
            callID: "c1",
            tool: ToolCall(callID: "c1", toolName: "git_status", toolArgs: nil)
        ))

        await engine.cancelActiveTurn()
        let snapshot = await engine.currentSnapshot()

        XCTAssertNil(snapshot.turnStartedAt)
        XCTAssertFalse(snapshot.timeline.contains { node in
            guard case .tool(let tool) = node.kind else { return false }
            return tool.status == .running
        })
    }

    func testRuntimeModelStatsAccumulateAndDeduplicateInvocationReplay() async {
        let engine = RuntimeEngine(sessionID: "session_1")
        await engine.ingest(.turnStarted(turnID: "t1", text: "measure"))
        let first = AgentEvent.modelFinished(
            turnID: "t1", promptTokens: 100, completionTokens: 20,
            totalTokens: 120, billingUnits: 125, elapsedMs: 30,
            invocationID: "inv_1", err: nil
        )
        await engine.ingest(first)
        await engine.ingest(first) // SSE/WebSocket replay
        await engine.ingest(.modelFinished(
            turnID: "t1", promptTokens: 200, completionTokens: 30,
            totalTokens: nil, billingUnits: nil, elapsedMs: 40,
            invocationID: "inv_2", err: nil
        ))

        let stats = await engine.currentSnapshot().modelStats
        XCTAssertEqual(stats?.contextTokens, 200)
        XCTAssertEqual(stats?.totalTokens, 350) // 120 + legacy fallback (200 + 30)
        XCTAssertEqual(stats?.usageUnits, 125)
        XCTAssertTrue(stats?.hasUsageUnits == true)
        XCTAssertEqual(stats?.elapsedMs, 70)
        XCTAssertEqual(stats?.invocationCount, 2)

        await engine.ingest(.turnStarted(turnID: "t2", text: "new turn"))
        let nextStats = await engine.currentSnapshot().modelStats
        XCTAssertNil(nextStats)
    }

    func testSuccessfulTodoToolProvidesFallbackWhenCanonicalEventIsMissing() async {
        let engine = RuntimeEngine(sessionID: "session_1")
        await engine.ingest(.turnStarted(turnID: "t1", text: "plan"))
        await engine.ingest(.toolStarted(
            turnID: "t1",
            callID: "todo_1",
            tool: ToolCall(
                callID: "todo_1",
                toolName: "todo_write",
                toolArgs: todoArguments()
            )
        ))
        await engine.ingest(.toolFinished(
            turnID: "t1",
            callID: "todo_1",
            result: ToolResult(
                callID: "todo_1",
                toolName: "todo_write",
                observation: "ok",
                error: nil
            )
        ))

        let snapshot = await engine.currentSnapshot()
        let todos = snapshot.latestTodos
        XCTAssertEqual(todos, [
            TodoItem(content: "Create skill", activeForm: "Creating skill", status: .inProgress),
        ])
        XCTAssertEqual(snapshot.turns.first?.todos, todos)
    }

    func testCanonicalTodoEventWinsOverToolFallback() async {
        let engine = RuntimeEngine(sessionID: "session_1")
        await engine.ingest(.turnStarted(turnID: "t1", text: "plan"))
        await engine.ingest(.toolStarted(
            turnID: "t1",
            callID: "todo_1",
            tool: ToolCall(
                callID: "todo_1",
                toolName: "TodoWrite",
                toolArgs: todoArguments(content: "Stale", activeFormKey: "active_form")
            )
        ))
        let canonical = [TodoItem(content: "Canonical", status: .pending)]
        await engine.ingest(.todoUpdated(turnID: "t1", todos: canonical))
        await engine.ingest(.toolFinished(
            turnID: "t1",
            callID: "todo_1",
            result: ToolResult(
                callID: "todo_1",
                toolName: "TodoWrite",
                observation: "ok",
                error: nil
            )
        ))

        let todos = await engine.currentSnapshot().latestTodos
        XCTAssertEqual(todos, canonical)
    }

    func testTodoStateRestoresFromHistory() async {
        let engine = RuntimeEngine(sessionID: "session_1")
        let historical = [
            TodoItem(content: "Done", status: .completed),
            TodoItem(content: "Next", activeForm: "Doing next", status: .inProgress),
        ]

        await engine.importHistory([
            .turnStarted(turnID: "t1", text: "plan"),
            .todoUpdated(turnID: "t1", todos: historical),
            .turnFinished(turnID: "t1", text: "planned", textAnnotations: []),
        ])

        let snapshot = await engine.currentSnapshot()
        let todos = snapshot.latestTodos
        XCTAssertEqual(todos, historical)
        XCTAssertEqual(snapshot.turns.first?.todos, historical)

        await engine.ingest(.turnStarted(turnID: "t2", text: "next question"))
        let nextSnapshot = await engine.currentSnapshot()
        XCTAssertEqual(nextSnapshot.turns.first?.todos, historical)
        XCTAssertTrue(nextSnapshot.turns.last?.todos.isEmpty == true)
    }

    func testPlanStaysWithOwningTurnAndRecordsDecision() async {
        let engine = RuntimeEngine(sessionID: "session_1")
        await engine.ingest(.turnStarted(turnID: "t1", text: "make a plan"))
        await engine.ingest(.planApprovalRequest(
            turnID: "t1",
            request: PlanApprovalRequest(
                id: "approval_1",
                planID: "plan_1",
                title: "Implementation plan",
                content: "1. Inspect\n2. Implement",
                deadlineMs: nil,
                sessionId: "session_1",
                turnId: "t1"
            )
        ))

        var snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.turns.first?.plans.first?.status, .pending)
        XCTAssertEqual(snapshot.turns.first?.plans.first?.requestID, "approval_1")

        await engine.resolvePlanApproval(requestID: "approval_1", approved: true)
        snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.turns.first?.plans.first?.status, .approved)
        XCTAssertNil(snapshot.pendingPlanApproval)

        await engine.ingest(.turnStarted(turnID: "t2", text: "continue"))
        snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.turns.first?.plans.first?.status, .approved)
        XCTAssertTrue(snapshot.turns.last?.plans.isEmpty == true)
    }

    // Live: text → tool → text across two invocations → two segments, interleaved.
    func testAssistantTextSegmentsAcrossToolAndInvocation() {
        var reducer = ExecutionReducer()
        var graph = ExecutionGraph()
        let turn = "t1"

        let events: [AgentEvent] = [
            .turnStarted(turnID: turn, text: "hi"),
            .modelStarted(turnID: turn, invocationID: "inv1"),
            .tokenDelta(turnID: turn, text: "A"),
            .toolStarted(turnID: turn, callID: "c1",
                         tool: ToolCall(callID: "c1", toolName: "grep", toolArgs: nil)),
            .toolFinished(turnID: turn, callID: "c1",
                          result: ToolResult(callID: "c1", toolName: "grep",
                                             observation: "ok", error: nil)),
            .modelFinished(turnID: turn, promptTokens: 100, completionTokens: 0, totalTokens: nil, billingUnits: nil, elapsedMs: 10, invocationID: "inv1", err: nil),
            .modelStarted(turnID: turn, invocationID: "inv2"),
            .tokenDelta(turnID: turn, text: "B"),
            .turnFinished(turnID: turn, text: "B", textAnnotations: []),
        ]
        for e in events { _ = reducer.reduce(e, into: &graph) }

        // Two distinct segments, not "AB" merged.
        XCTAssertEqual(assistantTexts(graph), ["A", "B"])

        // A before the tool, B after it.
        let nodes = graph.linearWalk()
        let idxA = firstIndex(nodes) { if case .assistantMessage(let t, _) = $0.payload { return t == "A" }; return false }
        let idxB = firstIndex(nodes) { if case .assistantMessage(let t, _) = $0.payload { return t == "B" }; return false }
        let idxTool = firstIndex(nodes) { if case .toolCall = $0.payload { return true }; return false }
        XCTAssertNotNil(idxA); XCTAssertNotNil(idxB); XCTAssertNotNil(idxTool)
        XCTAssertLessThan(idxA!, idxTool!, "first segment must precede the tool")
        XCTAssertLessThan(idxTool!, idxB!, "second segment must follow the tool")
    }

    // Cold history replay: no deltas, full answer arrives in turn_finished →
    // a single assistant node (unchanged behaviour, no duplicate).
    func testHistoryReplayProducesSingleAssistantNode() {
        var reducer = ExecutionReducer()
        var graph = ExecutionGraph()
        let turn = "t1"

        let events: [AgentEvent] = [
            .turnStarted(turnID: turn, text: "hi"),
            .toolStarted(turnID: turn, callID: "c1",
                         tool: ToolCall(callID: "c1", toolName: "grep", toolArgs: nil)),
            .toolFinished(turnID: turn, callID: "c1",
                          result: ToolResult(callID: "c1", toolName: "grep",
                                             observation: "ok", error: nil)),
            .turnFinished(turnID: turn, text: "full answer", textAnnotations: []),
        ]
        for e in events { _ = reducer.reduce(e, into: &graph) }

        XCTAssertEqual(assistantTexts(graph), ["full answer"])
    }

    // Final answer delivered ONLY in turn_finished (not streamed), after an
    // earlier streamed segment + tool. It must be appended, not dropped.
    func testFinalAnswerFromTurnFinishedIsAppended() {
        var reducer = ExecutionReducer()
        var graph = ExecutionGraph()
        let turn = "t1"

        let events: [AgentEvent] = [
            .turnStarted(turnID: turn, text: "hi"),
            .modelStarted(turnID: turn, invocationID: "inv1"),
            .tokenDelta(turnID: turn, text: "Let me check"),
            .toolStarted(turnID: turn, callID: "c1",
                         tool: ToolCall(callID: "c1", toolName: "grep", toolArgs: nil)),
            .toolFinished(turnID: turn, callID: "c1",
                          result: ToolResult(callID: "c1", toolName: "grep",
                                             observation: "ok", error: nil)),
            .modelFinished(turnID: turn, promptTokens: 1, completionTokens: 0, totalTokens: nil, billingUnits: nil, elapsedMs: 1, invocationID: nil, err: nil),
            .turnFinished(turnID: turn, text: "Here is the answer", textAnnotations: []),
        ]
        for e in events { _ = reducer.reduce(e, into: &graph) }

        XCTAssertEqual(assistantTexts(graph), ["Let me check", "Here is the answer"])
    }

    // Live with a single invocation finalized by turn_finished (streaming text
    // not closed by a model_finished) must not duplicate the final answer.
    func testLiveSingleSegmentNoDuplicateOnTurnFinished() {
        var reducer = ExecutionReducer()
        var graph = ExecutionGraph()
        let turn = "t1"

        let events: [AgentEvent] = [
            .turnStarted(turnID: turn, text: "hi"),
            .modelStarted(turnID: turn, invocationID: "inv1"),
            .tokenDelta(turnID: turn, text: "Hello"),
            .tokenDelta(turnID: turn, text: " world"),
            .turnFinished(turnID: turn, text: "Hello world", textAnnotations: []),
        ]
        for e in events { _ = reducer.reduce(e, into: &graph) }

        XCTAssertEqual(assistantTexts(graph), ["Hello world"])
    }

    func testTurnFinishedAnnotationsAttachToStreamedFinalAnswer() {
        var reducer = ExecutionReducer()
        var graph = ExecutionGraph()
        let turn = "t1"
        let annotation = AgentTextAnnotation(
            assetID: "asset_turn_7_call_grep_001",
            kind: "file_location",
            text: "App.swift:5",
            startUTF16: 6,
            endUTF16: 17,
            sourceTurnID: turn,
            sourceCallID: "c1"
        )

        let events: [AgentEvent] = [
            .turnStarted(turnID: turn, text: "hi"),
            .modelStarted(turnID: turn, invocationID: "inv1"),
            .tokenDelta(turnID: turn, text: "Open `App.swift:5`."),
            .turnFinished(
                turnID: turn,
                text: "Open `App.swift:5`.",
                textAnnotations: [annotation]
            ),
        ]
        for e in events { _ = reducer.reduce(e, into: &graph) }

        let turns = TimelineProjection().projectTurns(graph)
        guard case .text(_, let payload)? = turns.first?.blocks.first else {
            return XCTFail("expected assistant text block")
        }
        XCTAssertEqual(payload.text, "Open `App.swift:5`.")
        XCTAssertEqual(payload.textAnnotations.first?.assetID, annotation.assetID)
    }
}
