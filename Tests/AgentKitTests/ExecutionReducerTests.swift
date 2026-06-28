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

    private func assistantTexts(_ graph: ExecutionGraph) -> [String] {
        graph.linearWalk().compactMap { node in
            if case .assistantMessage(let t) = node.payload { return t }
            return nil
        }
    }

    private func firstIndex(_ nodes: [GraphNode], where predicate: (GraphNode) -> Bool) -> Int? {
        nodes.firstIndex(where: predicate)
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
            .modelFinished(turnID: turn, promptTokens: 100, elapsedMs: 10, err: nil),
            .modelStarted(turnID: turn, invocationID: "inv2"),
            .tokenDelta(turnID: turn, text: "B"),
            .turnFinished(turnID: turn, text: "B"),
        ]
        for e in events { _ = reducer.reduce(e, into: &graph) }

        // Two distinct segments, not "AB" merged.
        XCTAssertEqual(assistantTexts(graph), ["A", "B"])

        // A before the tool, B after it.
        let nodes = graph.linearWalk()
        let idxA = firstIndex(nodes) { if case .assistantMessage(let t) = $0.payload { return t == "A" }; return false }
        let idxB = firstIndex(nodes) { if case .assistantMessage(let t) = $0.payload { return t == "B" }; return false }
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
            .turnFinished(turnID: turn, text: "full answer"),
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
            .modelFinished(turnID: turn, promptTokens: 1, elapsedMs: 1, err: nil),
            .turnFinished(turnID: turn, text: "Here is the answer"),
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
            .turnFinished(turnID: turn, text: "Hello world"),
        ]
        for e in events { _ = reducer.reduce(e, into: &graph) }

        XCTAssertEqual(assistantTexts(graph), ["Hello world"])
    }
}
