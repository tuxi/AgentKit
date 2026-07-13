//
//  TimelineProjectionTurnsTests.swift
//  AgentKitTests
//
//  Phase B: Turn → Block projection. Lifecycle folds into the footer; text and
//  tools stay interleaved; live and history converge on the same structure.
//

import XCTest
@testable import AgentKit

final class TimelineProjectionTurnsTests: XCTestCase {

    private func reduce(_ events: [AgentEvent]) -> ExecutionGraph {
        var reducer = ExecutionReducer()
        var graph = ExecutionGraph()
        for e in events { _ = reducer.reduce(e, into: &graph) }
        return graph
    }

    private func tool(_ callID: String, _ name: String) -> ToolCall {
        ToolCall(callID: callID, toolName: name, toolArgs: nil)
    }
    private func result(_ callID: String, _ name: String) -> ToolResult {
        ToolResult(callID: callID, toolName: name, observation: "ok", error: nil, elapsedMs: 5)
    }

    /// Block-kind tag for order assertions.
    private func tags(_ blocks: [TurnBlock]) -> [String] {
        blocks.map { block in
            switch block {
            case .text: return "text"
            case .toolGroup: return "tools"
            case .artifact: return "artifact"
            case .system: return "system"
            case .childStream: return "childStream"
            }
        }
    }

    // Live turn: thinking → text → tool → text. Lifecycle → footer, not blocks.
    func testInterleavedTurnFoldsBlocksAndFooter() {
        let turn = "t1"
        let graph = reduce([
            .turnStarted(turnID: turn, text: "do it"),
            .modelStarted(turnID: turn, invocationID: "inv1"),
            .thinking(turnID: turn, text: "let me look"),
            .tokenDelta(turnID: turn, text: "Checking"),
            .toolStarted(turnID: turn, callID: "c1", tool: tool("c1", "grep")),
            .toolFinished(turnID: turn, callID: "c1", result: result("c1", "grep")),
            .modelFinished(turnID: turn, promptTokens: 1200, completionTokens: 0, totalTokens: nil, billingUnits: nil, elapsedMs: 30, invocationID: "inv1", err: nil),
            .modelStarted(turnID: turn, invocationID: "inv2"),
            .tokenDelta(turnID: turn, text: "Done"),
            .modelFinished(turnID: turn, promptTokens: 1500, completionTokens: 0, totalTokens: nil, billingUnits: nil, elapsedMs: 20, invocationID: "inv2", err: nil),
            .turnFinished(turnID: turn, text: "Done", textAnnotations: []),
        ])

        let turns = TimelineProjection().projectTurns(graph, isLive: true)
        XCTAssertEqual(turns.count, 1)
        let t = turns[0]

        XCTAssertEqual(t.userPrompt?.text, "do it")
        // No "model invoked/finished" blocks. Thinking renders as an assistant
        // reply (text), interleaved with tools.
        XCTAssertEqual(tags(t.blocks), ["text", "text", "tools", "text"])

        // Footer aggregates the two invocations.
        XCTAssertNotNil(t.footer)
        XCTAssertEqual(t.footer?.invocationCount, 2)
        XCTAssertEqual(t.footer?.elapsedMs, 50)      // 30 + 20
        XCTAssertEqual(t.footer?.contextTokens, 1500) // last invocation context
        XCTAssertEqual(t.footer?.totalTokens, 2700)

        // Narration ("let me look") + replies, in arrival order.
        let texts: [String] = t.blocks.compactMap {
            if case .text(_, let p) = $0 { return p.text }; return nil
        }
        XCTAssertEqual(texts, ["let me look", "Checking", "Done"])
    }

    func testFooterAccumulatesUsageAndDeduplicatesReplayedInvocation() {
        let turn = "t1"
        let finished = AgentEvent.modelFinished(
            turnID: turn, promptTokens: 52_444, completionTokens: 199,
            totalTokens: 52_643, billingUnits: 53_112, elapsedMs: 7_500,
            invocationID: "inv_15", err: nil
        )
        let graph = reduce([
            .turnStarted(turnID: turn, text: "do it"),
            finished,
            finished, // persisted-event replay
            .modelFinished(turnID: turn, promptTokens: 51_000, completionTokens: 100,
                           totalTokens: 51_100, billingUnits: 51_500, elapsedMs: 1_000,
                           invocationID: "inv_16", err: nil),
        ])
        let footer = TimelineProjection().projectTurns(graph).first?.footer
        XCTAssertEqual(footer?.contextTokens, 51_000)
        XCTAssertEqual(footer?.totalTokens, 103_743)
        XCTAssertEqual(footer?.usageUnits, 104_612)
        XCTAssertTrue(footer?.hasUsageUnits == true)
        XCTAssertEqual(footer?.invocationCount, 2)
        XCTAssertEqual(footer?.elapsedMs, 8_500)
    }

    // Same narration on both `thinking` and `token_delta` shows once, not twice.
    func testDuplicateThinkingAndTokenMergeToOne() {
        let turn = "t1"
        let graph = reduce([
            .turnStarted(turnID: turn, text: "q"),
            .modelStarted(turnID: turn, invocationID: "inv1"),
            .tokenDelta(turnID: turn, text: "Let me trace the data flow"),
            .thinking(turnID: turn, text: "Let me trace the data flow"),
            .toolStarted(turnID: turn, callID: "c1", tool: tool("c1", "grep")),
            .toolFinished(turnID: turn, callID: "c1", result: result("c1", "grep")),
        ])
        let turns = TimelineProjection().projectTurns(graph, isLive: true)
        // One narration block, not two identical ones.
        XCTAssertEqual(tags(turns[0].blocks), ["text", "tools"])
        let texts = turns[0].blocks.compactMap { block -> String? in
            if case .text(_, let p) = block { return p.text }; return nil
        }
        XCTAssertEqual(texts, ["Let me trace the data flow"])
    }

    // No lifecycle/text reorder leaks: assistant text is NOT forced to the end.
    func testAssistantTextNotPinnedToEnd() {
        let turn = "t1"
        let graph = reduce([
            .turnStarted(turnID: turn, text: "q"),
            .modelStarted(turnID: turn, invocationID: "inv1"),
            .tokenDelta(turnID: turn, text: "first"),
            .toolStarted(turnID: turn, callID: "c1", tool: tool("c1", "grep")),
            .toolFinished(turnID: turn, callID: "c1", result: result("c1", "grep")),
            .modelFinished(turnID: turn, promptTokens: 10, completionTokens: 0, totalTokens: nil, billingUnits: nil, elapsedMs: 1, invocationID: nil, err: nil),
        ])
        let turns = TimelineProjection().projectTurns(graph, isLive: true)
        // text BEFORE tools — not sunk below them.
        XCTAssertEqual(tags(turns[0].blocks), ["text", "tools"])
    }

    // Two consecutive same-name tools fold into one group with an ×N summary.
    func testConsecutiveToolsMergeIntoGroup() {
        let turn = "t1"
        let graph = reduce([
            .turnStarted(turnID: turn, text: "q"),
            .modelStarted(turnID: turn, invocationID: "inv1"),
            .toolStarted(turnID: turn, callID: "c1", tool: tool("c1", "read_file")),
            .toolFinished(turnID: turn, callID: "c1", result: result("c1", "read_file")),
            .toolStarted(turnID: turn, callID: "c2", tool: tool("c2", "read_file")),
            .toolFinished(turnID: turn, callID: "c2", result: result("c2", "read_file")),
        ])
        let turns = TimelineProjection().projectTurns(graph, isLive: false)
        XCTAssertEqual(tags(turns[0].blocks), ["tools"])
        guard case .toolGroup(let g) = turns[0].blocks[0] else { return XCTFail("expected group") }
        XCTAssertEqual(g.tools.count, 2)
        XCTAssertEqual(g.summary, "read_file ×2")
    }

    // A run of different-name tools splits into same-name groups.
    func testToolsSplitBySameNameRuns() {
        let turn = "t1"
        let graph = reduce([
            .turnStarted(turnID: turn, text: "q"),
            .modelStarted(turnID: turn, invocationID: "inv1"),
            .toolStarted(turnID: turn, callID: "c1", tool: tool("c1", "read_file")),
            .toolFinished(turnID: turn, callID: "c1", result: result("c1", "read_file")),
            .toolStarted(turnID: turn, callID: "c2", tool: tool("c2", "read_file")),
            .toolFinished(turnID: turn, callID: "c2", result: result("c2", "read_file")),
            .toolStarted(turnID: turn, callID: "c3", tool: tool("c3", "grep")),
            .toolFinished(turnID: turn, callID: "c3", result: result("c3", "grep")),
            .toolStarted(turnID: turn, callID: "c4", tool: tool("c4", "read_file")),
            .toolFinished(turnID: turn, callID: "c4", result: result("c4", "read_file")),
        ])
        let turns = TimelineProjection().projectTurns(graph, isLive: false)
        // read_file ×2 | grep | read_file → 3 groups.
        XCTAssertEqual(tags(turns[0].blocks), ["tools", "tools", "tools"])
        let summaries = turns[0].blocks.compactMap { block -> String? in
            if case .toolGroup(let g) = block { return g.summary }
            return nil
        }
        XCTAssertEqual(summaries, ["read_file ×2", "grep", "read_file"])
    }

    // A restarted server can REUSE turn_id within one session. Turns must still
    // render as distinct, ordered turns with distinct ids (ForEach safety).
    func testReusedTurnIDProducesDistinctOrderedTurns() {
        var reducer = ExecutionReducer()
        var graph = ExecutionGraph()
        let events: [AgentEvent] = [
            .turnStarted(turnID: "turn_1", text: "first"),
            .turnFinished(turnID: "turn_1", text: "reply 1", textAnnotations: []),
            .turnStarted(turnID: "turn_2", text: "second"),
            .turnFinished(turnID: "turn_2", text: "reply 2", textAnnotations: []),
            // server restart → turn_id reset, reuses "turn_1"
            .turnStarted(turnID: "turn_1", text: "third"),
            .turnFinished(turnID: "turn_1", text: "reply 3", textAnnotations: []),
        ]
        for e in events { _ = reducer.reduce(e, into: &graph) }

        let turns = TimelineProjection().projectTurns(graph)
        XCTAssertEqual(turns.count, 3)
        XCTAssertEqual(turns.map { $0.userPrompt?.text }, ["first", "second", "third"])
        // All ids distinct → SwiftUI ForEach won't drop/reorder.
        XCTAssertEqual(Set(turns.map(\.id)).count, 3)
    }

    // Live and cold-history of the SAME turn converge on the same block tags.
    func testLiveAndHistoryConverge() {
        let turn = "t1"
        // Live: streamed deltas.
        let live = reduce([
            .turnStarted(turnID: turn, text: "q"),
            .modelStarted(turnID: turn, invocationID: "inv1"),
            .tokenDelta(turnID: turn, text: "Answer"),
            .toolStarted(turnID: turn, callID: "c1", tool: tool("c1", "grep")),
            .toolFinished(turnID: turn, callID: "c1", result: result("c1", "grep")),
            .modelFinished(turnID: turn, promptTokens: 10, completionTokens: 0, totalTokens: nil, billingUnits: nil, elapsedMs: 1, invocationID: nil, err: nil),
        ])
        // History-style: same shape, text delivered as a single delta run.
        let history = reduce([
            .turnStarted(turnID: turn, text: "q"),
            .modelStarted(turnID: turn, invocationID: "inv1"),
            .tokenDelta(turnID: turn, text: "Answer"),
            .toolStarted(turnID: turn, callID: "c1", tool: tool("c1", "grep")),
            .toolFinished(turnID: turn, callID: "c1", result: result("c1", "grep")),
            .modelFinished(turnID: turn, promptTokens: 10, completionTokens: 0, totalTokens: nil, billingUnits: nil, elapsedMs: 1, invocationID: nil, err: nil),
            .turnFinished(turnID: turn, text: "Answer", textAnnotations: []),
        ])
        let lt = TimelineProjection().projectTurns(live, isLive: true)[0]
        let ht = TimelineProjection().projectTurns(history, isLive: false)[0]
        XCTAssertEqual(tags(lt.blocks), tags(ht.blocks))
        XCTAssertEqual(tags(lt.blocks), ["text", "tools"])
    }
}
