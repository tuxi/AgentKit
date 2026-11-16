import XCTest
@testable import AgentKit

final class TurnOutcomePresentationTests: XCTestCase {
    private let english = ToolTranscriptText(locale: "en")
    private let budget = "model api error: status=400 type=invalid_request_error message=Upstream request failed: [invalid_request_error] This model's maximum context length is 1048576 tokens. However, you requested 393216 output tokens and your prompt contains at least 655361 input tokens, for a total of at least 1048577 tokens. Please reduce the length of the input prompt or the number of requested output tokens."

    func testBudgetPreservesOneTokenDifference() throws {
        let value = try XCTUnwrap(TurnOutcomePresentation.make(.init(kind: .error, text: budget), text: english))
        XCTAssertEqual(value.title, "Context budget exceeded")
        XCTAssertTrue(value.canManageContext)
        XCTAssertEqual(value.facts.filter { $0.label != "HTTP" }.map(\.value), ["1,048,576 tokens", "655,361 tokens", "393,216 tokens", "1,048,577 tokens", "1 token"])
        XCTAssertEqual(value.diagnostic, budget)
    }
    func testCancellationUsesActualReasonAndNeverStopped() throws {
        for metadata in [["type": "cancelled", "reason": "user_requested"], ["type": "cancelled"]] {
            let value = try XCTUnwrap(TurnOutcomePresentation.make(.init(kind: .modelActivity, text: "已取消 — user_requested", metadata: metadata), text: english))
            XCTAssertEqual(value.title, "Turn cancelled")
            XCTAssertTrue(value.diagnostic.isEmpty)
            XCTAssertFalse(value.canManageContext)
        }
        let unknown = TurnOutcomePresentation.make(.init(kind: .modelActivity, text: "已取消", metadata: ["type": "cancelled"]), text: english)
        XCTAssertEqual(unknown?.title, "Turn interrupted")
        XCTAssertNil(TurnOutcomePresentation.make(.init(kind: .modelActivity, text: "completed", metadata: ["phase": "finished"])))
    }
    func testDoesNotGuessBudgetFromHTTP400OrCredentialsFrom403() throws {
        let invalid = try XCTUnwrap(TurnOutcomePresentation.make(.init(kind: .error, text: "status=400 invalid parameter"), text: english))
        XCTAssertEqual(invalid.title, "Model request rejected")
        XCTAssertFalse(invalid.canManageContext)
        for code in ["403", "429", "unknown"] {
            XCTAssertEqual(TurnOutcomePresentation.make(.init(kind: .error, text: "upstream failed", metadata: ["code": code]), text: english)?.title, "Turn could not complete")
        }
    }
    func testDiagnosticMasksCredentialsWithoutHidingBudget() {
        let raw = #"Authorization: Bearer private-fixture-value {"api_key":"json-fixture-value"} input_tokens=655361 total 1048577 tokens"#
        let clean = TurnOutcomePresentation.sanitize(raw)
        XCTAssertFalse(clean.contains("private-fixture-value"))
        XCTAssertFalse(clean.contains("json-fixture-value"))
        XCTAssertTrue(clean.contains("655361"))
        XCTAssertTrue(clean.contains("1048577"))
        let escaped = #"error {"api_key":"first\"second", "token":"third"} total_tokens=1048577"#
        let sanitized = TurnOutcomePresentation.sanitize(escaped)
        XCTAssertFalse(sanitized.contains("first"))
        XCTAssertFalse(sanitized.contains("second"))
        XCTAssertFalse(sanitized.contains("third"))
        XCTAssertTrue(sanitized.contains("1048577"))
    }
    func testRepeatedTerminalEventsKeepIdentityAndEarlierOutput() {
        let a = SystemNodePayload(kind: .error, text: "first")
        let b = SystemNodePayload(kind: .error, text: "latest")
        let blocks = TurnOutcomePresentation.normalize([.text(id: "text", .init(role: .assistant, text: "partial answer")), .system(id: "first", a), .system(id: "second", b)])
        XCTAssertEqual(blocks.count, 2)
        guard case .system(let id, let payload) = blocks.last else { return XCTFail() }
        XCTAssertEqual(id, "first")
        XCTAssertEqual(payload.text, "latest")
    }

    func testReducerDeduplicatesWithinEachTurnInstance() {
        var reducer = ExecutionReducer()
        var graph = ExecutionGraph()
        _ = reducer.reduce(.turnStarted(turnID: "reused", text: "first"), into: &graph)
        for message in ["first failure", "updated failure"] {
            _ = reducer.reduce(.turnFailed(turnID: "reused", text: nil, err: message, errorCode: nil), into: &graph)
        }
        XCTAssertEqual(graph.nodes.values.filter { $0.kind == .system }.count, 1)
        _ = reducer.reduce(.turnStarted(turnID: "reused", text: "second"), into: &graph)
        _ = reducer.reduce(.turnCancelled(turnID: "reused", reason: "user_requested"), into: &graph)
        _ = reducer.reduce(.turnCancelled(turnID: "reused", reason: nil), into: &graph)
        let outcomes = graph.nodes.values.compactMap { node -> SystemPayload? in
            if case .system(let payload) = node.payload { return payload }; return nil
        }
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertTrue(outcomes.contains { $0.text == "updated failure" })
        XCTAssertTrue(outcomes.contains { $0.metadata["reason"] == "user_requested" })
    }

    @MainActor func testWebUsesSanitizedDiagnosticAndUnknownUsage() throws {
        let payload = SystemNodePayload(kind: .error, text: "Authorization: Bearer fixture-secret")
        let turn = ConversationTurn(id: "t", userPrompt: nil, blocks: [.system(id: "err", payload)], footer: .init(contextTokens: 0, totalTokens: 0, elapsedMs: 0, invocationCount: 1, hasTokenUsage: false), isLive: false)
        let document = ConversationWebDocumentBuilder.build(snapshot: .init(timeline: [], turns: [turn]), conversationID: "c")
        XCTAssertEqual(document.turns[0].footer?.totalTokens, "—")
        XCTAssertNotNil(document.turns[0].blocks[0].outcome)
        let encoded = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        XCTAssertFalse(encoded.contains("fixture-secret"))
    }
}
