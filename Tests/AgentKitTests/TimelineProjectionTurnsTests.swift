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
            case .thinking: return "thinking"
            case .toolGroup: return "tools"
            case .artifact: return "artifact"
            case .system: return "system"
            case .childStream: return "childStream"
            }
        }
    }

    // Live turn: thinking → text → tool → text. Lifecycle → footer, not blocks.
    // After backend fix: `thinking` carries reasoning (not assistant narration),
    // so it appears as a separate collapsible thinking block, not inline text.
    func testInterleavedTurnFoldsBlocksAndFooter() {
        let turn = "t1"
        let graph = reduce([
            .turnStarted(turnID: turn, text: "do it"),
            .modelStarted(turnID: turn, invocationID: "inv1"),
            .reasoningDelta(turnID: turn, text: "let me "),
            .reasoningDelta(turnID: turn, text: "look"),
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
        // Thinking renders as a separate collapsible card, not inline text.
        // Block order: thinking → text → tools → text.
        XCTAssertEqual(tags(t.blocks), ["thinking", "text", "tools", "text"])

        // Footer aggregates the two invocations.
        XCTAssertNotNil(t.footer)
        XCTAssertEqual(t.footer?.invocationCount, 2)
        XCTAssertEqual(t.footer?.elapsedMs, 50)      // 30 + 20
        XCTAssertEqual(t.footer?.contextTokens, 1500) // last invocation context
        XCTAssertEqual(t.footer?.totalTokens, 2700)

        // Assistant replies only (no reasoning).
        let texts: [String] = t.blocks.compactMap {
            if case .text(_, let p) = $0 { return p.text }; return nil
        }
        XCTAssertEqual(texts, ["Checking", "Done"])

        // Thinking block content is the reasoning text.
        let thinkingTexts: [String] = t.blocks.compactMap {
            if case .thinking(_, let p) = $0 { return p.text }; return nil
        }
        XCTAssertEqual(thinkingTexts, ["let me look"])
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

    // Reasoning and assistant text are distinct content types — `thinking`
    // blocks carry reasoning, `text` blocks carry the assistant's spoken reply.
    // They never merge, even if their text happens to overlap.
    func testThinkingAndTextAreDistinctBlocks() {
        let turn = "t1"
        let graph = reduce([
            .turnStarted(turnID: turn, text: "q"),
            .modelStarted(turnID: turn, invocationID: "inv1"),
            .reasoningDelta(turnID: turn, text: "I need to search"),
            .thinking(turnID: turn, text: "I need to search"),
            .tokenDelta(turnID: turn, text: "Let me look that up"),
            .toolStarted(turnID: turn, callID: "c1", tool: tool("c1", "grep")),
            .toolFinished(turnID: turn, callID: "c1", result: result("c1", "grep")),
        ])
        let turns = TimelineProjection().projectTurns(graph, isLive: true)
        // Thinking and text are separate blocks.
        XCTAssertEqual(tags(turns[0].blocks), ["thinking", "text", "tools"])
        let thinkingTexts = turns[0].blocks.compactMap { block -> String? in
            if case .thinking(_, let p) = block { return p.text }; return nil
        }
        XCTAssertEqual(thinkingTexts, ["I need to search"])
        let texts = turns[0].blocks.compactMap { block -> String? in
            if case .text(_, let p) = block { return p.text }; return nil
        }
        XCTAssertEqual(texts, ["Let me look that up"])
    }

    func testTodoUpdateDoesNotDuplicateAsModelActivityBlock() {
        let turn = "t1"
        let graph = reduce([
            .turnStarted(turnID: turn, text: "make a plan"),
            .todoUpdated(turnID: turn, todos: [
                TodoItem(content: "First", status: .completed),
                TodoItem(content: "Second", activeForm: "Doing second", status: .inProgress),
            ]),
        ])

        let projected = TimelineProjection().projectTurns(graph).first
        XCTAssertNotNil(projected)
        XCTAssertFalse(projected?.blocks.contains { block in
            if case .system = block { return true }
            return false
        } ?? true)
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

    // Reasoning deltas stream into a running thinking node; the authoritative
    // `thinking` event replaces it with the complete text, marked completed.
    func testReasoningDeltaAndThinkingReplace() {
        let turn = "t1"
        let graph = reduce([
            .turnStarted(turnID: turn, text: "analyze"),
            .modelStarted(turnID: turn, invocationID: "inv1"),
            .reasoningDelta(turnID: turn, text: "partial"),
            .reasoningDelta(turnID: turn, text: " stream"),
            .thinking(turnID: turn, text: "complete reasoning"),
            .tokenDelta(turnID: turn, text: "Answer"),
            .modelFinished(turnID: turn, promptTokens: 10, completionTokens: 0, totalTokens: nil, billingUnits: nil, elapsedMs: 1, invocationID: nil, err: nil),
        ])
        let turns = TimelineProjection().projectTurns(graph, isLive: true)
        // thinking replaces, not appends — one thinking block with the complete text.
        XCTAssertEqual(tags(turns[0].blocks), ["thinking", "text"])
        let thinkingTexts = turns[0].blocks.compactMap { block -> String? in
            if case .thinking(_, let p) = block { return p.text }; return nil
        }
        XCTAssertEqual(thinkingTexts, ["complete reasoning"])
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
