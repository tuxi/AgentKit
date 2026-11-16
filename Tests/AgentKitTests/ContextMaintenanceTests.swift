import XCTest
@testable import AgentKit

enum ContextMaintenanceFixtures {
    static func value(_ status: String, id: String = "op-1", after: Int? = nil, committed: Bool = true, error: String? = nil) -> ContextMaintenance {
        .init(operationID: id, phase: status == "running" ? "summarizing" : status == "pending" ? "measuring" : "finished",
            status: status, committed: committed, beforeTokens: 231602, afterTokens: after,
            estimatedSavedTokens: 24738, clearedResults: 38, summaryGenerated: !["running", "failed", "canceled"].contains(status),
            measurementSource: after == nil ? "unknown" : "measured", error: error)
    }
    static func payload(_ value: ContextMaintenance) throws -> SystemNodePayload {
        .init(kind: .contextCompact, text: "", metadata: ["maintenance": String(decoding: try JSONEncoder().encode(value), as: UTF8.self)])
    }
}

final class ContextMaintenanceTests: XCTestCase {
    private let text = ToolTranscriptText(locale: "en")
    private func presentation(_ value: ContextMaintenance, live: Bool = true) throws -> ContextMaintenancePresentation {
        try XCTUnwrap(ContextMaintenancePresentation.make(ContextMaintenanceFixtures.payload(value), live: live, text: text))
    }
    func testMeasuredUsageIsNotSummedWithPruningEstimates() throws {
        let p = try presentation(ContextMaintenanceFixtures.value("completed", after: 32390))
        XCTAssertEqual(p.summary, "231.6K → 32.4K tokens")
        XCTAssertEqual(p.steps.filter { $0.label == "Context usage" }.map(\.value), ["231,602 → 32,390 tokens"])
        XCTAssertTrue(p.steps.contains { $0.value == "Estimated reduction: 24,738 tokens" })
        XCTAssertFalse(p.summary.contains("223"), "never add pruning savings to the measured final delta")
    }
    func testLimitedFailureRollbackAndCancellationAreDifferent() throws {
        let limited = try presentation(ContextMaintenanceFixtures.value("limited", after: 210000))
        XCTAssertEqual(limited.summary, "Limited compaction benefit")
        XCTAssertTrue(limited.note?.contains("threshold") == true)
        let failed = try presentation(ContextMaintenanceFixtures.value("failed", committed: false, error: "summary token budget exceeded"))
        XCTAssertEqual(failed.status, "failed")
        XCTAssertFalse(failed.steps.contains { $0.label == "Context usage" })
        XCTAssertTrue(failed.note?.contains("not committed") == true)
        XCTAssertTrue(failed.steps.contains { $0.value == "summary token budget exceeded" }, "the word token alone is not a secret")
        let canceled = try presentation(ContextMaintenanceFixtures.value("canceled", committed: false))
        XCTAssertEqual(canceled.summary, "Maintenance canceled")
    }
    func testUnmeasuredUsageAndInterruptedReplayNeverLookLikeZeroOrLiveWork() throws {
        let pending = try presentation(ContextMaintenanceFixtures.value("pending"))
        XCTAssertTrue(pending.summary.contains("unconfirmed"))
        XCTAssertFalse(pending.summary.contains("0 tokens"))
        let replay = try presentation(ContextMaintenanceFixtures.value("running", committed: false), live: false)
        XCTAssertEqual(replay.status, "interrupted")
        XCTAssertEqual(replay.summary, "Maintenance incomplete")
    }
    func testLegacyGroupingPreservesNarrationAndThinkingBoundaries() throws {
        let cleared = TurnBlock.system(id: "clear", .init(kind: .contextEdited, text: "cleared 38 stale tool results"))
        let pruned = TurnBlock.system(id: "prune", .init(kind: .contextPruned, text: "raw", metadata: ["savedTokens": "24738"]))
        let thought = TurnBlock.thinking(id: "thought", .init(text: "reason", isStreaming: false))
        let compacted = TurnBlock.system(id: "compact", .init(kind: .contextCompact, text: "raw", metadata: ["beforeTokens": "231602", "afterTokens": "32390"]))
        let merged = ContextMaintenancePresentation.mergeLegacyBlocks([cleared, pruned, thought, compacted])
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged.first?.id, "clear")
        guard case .system(_, let payload) = merged[0] else { return XCTFail("missing context disclosure") }
        let p = try XCTUnwrap(ContextMaintenancePresentation.make(payload, live: false, text: text))
        XCTAssertEqual(p.steps.count, 2)
        XCTAssertEqual(p.steps.first?.value, "38 results")
        XCTAssertTrue(p.note?.contains("historical") == true)
        XCTAssertEqual(merged[1], thought)
        let unknown = try XCTUnwrap(ContextMaintenancePresentation.make(.init(kind: .contextCompact, text: "", metadata: ["afterTokens": "0"]), live: false, text: text))
        XCTAssertTrue(unknown.summary.contains("unconfirmed"))
    }
    func testWireDecodingAndReducerKeepOneRecordAtItsOriginalPositionAcrossTurns() throws {
        var reducer = ExecutionReducer(); var graph = ExecutionGraph()
        _ = reducer.reduce(.turnStarted(turnID: "t1", text: "start"), into: &graph)
        let running = ContextMaintenanceFixtures.value("running", committed: false)
        let wireObject: [String: Any] = ["kind": "context_maintenance", "turn_id": "t1", "context_maintenance": try JSONSerialization.jsonObject(with: JSONEncoder().encode(running))]
        let wire = try JSONDecoder().decode(WireFrame.self, from: JSONSerialization.data(withJSONObject: wireObject))
        let event = try XCTUnwrap(AgentEvent.from(wire: wire))
        let ids = reducer.reduce(event, into: &graph)
        XCTAssertEqual(ids.count, 1)
        _ = reducer.reduce(.turnStarted(turnID: "t2", text: "next"), into: &graph)
        let updated = reducer.reduce(.contextMaintenance(turnID: "t2", value: ContextMaintenanceFixtures.value("completed", after: 32390)), into: &graph)
        XCTAssertEqual(ids, updated)
        XCTAssertEqual(graph.nodes[ids[0]]?.turnID, "t1", "late measurement does not migrate to a later turn")
        XCTAssertEqual(graph.nodeOrder.filter { $0 == ids[0] }.count, 1)
        let legacy = try JSONDecoder().decode(WireFrame.self, from: Data(#"{"kind":"compacted","context_operation_id":"op-1","after_tokens":32390}"#.utf8))
        XCTAssertNil(AgentEvent.from(wire: legacy), "new runtime legacy compatibility event is not displayed twice")
    }
    func testRecoveryRetainsPriorFailureReasonWithoutLeavingFailedStatus() throws {
        var reducer = ExecutionReducer(); var graph = ExecutionGraph()
        _ = reducer.reduce(.turnStarted(turnID: "t", text: "start"), into: &graph)
        let failed = ContextMaintenanceFixtures.value("failed", committed: false, error: "Earlier summary timeout")
        _ = reducer.reduce(.contextMaintenance(turnID: "t", value: failed), into: &graph)
        _ = reducer.reduce(.contextMaintenance(turnID: "t", value: ContextMaintenanceFixtures.value("completed", after: 32390)), into: &graph)
        guard case .system(let payload)? = graph.nodes["context-maintenance:op-1"]?.payload else { return XCTFail("missing context transaction") }
        let view = try XCTUnwrap(ContextMaintenancePresentation.make(.init(kind: .contextCompact, text: payload.text, metadata: payload.metadata), live: false, text: text))
        XCTAssertEqual(view.status, "completed")
        XCTAssertTrue(view.steps.contains { $0.value == "Earlier summary timeout" })
        XCTAssertEqual(view.summary, "231.6K → 32.4K tokens")
    }

    func testPrivateErrorAndNativeDisclosureKeepCompleteUsefulContent() throws {
        let failed = try presentation(ContextMaintenanceFixtures.value("failed", committed: false, error: "HTTP 401 Bearer abc123"))
        XCTAssertTrue(failed.steps.contains { $0.value.contains("[redacted]") })
        XCTAssertFalse(failed.steps.contains { $0.value.contains("abc123") })
        let payload = try ContextMaintenanceFixtures.payload(ContextMaintenanceFixtures.value("failed", committed: false, error: "Summary unavailable"))
        let turn = ConversationTurn(id: "turn", userPrompt: nil, blocks: [.system(id: "maintenance", payload)], footer: nil, isLive: false)
        let closed = TurnTranscriptBuilder.build(turn: turn, state: .init())
        XCTAssertFalse(closed.attributedString.string.contains("Summary unavailable"))
        let open = TurnTranscriptBuilder.build(turn: turn, state: .init(expandedThinkingIDs: ["maintenance"]))
        XCTAssertTrue(open.attributedString.string.contains("Summary unavailable"))
        XCTAssertTrue(open.actions.values.contains(.toggleThinking(id: "maintenance")))
    }
}
