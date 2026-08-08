//
//  ContextEventsTests.swift
//  AgentKitTests
//
//  Context management & verification events (docs/macos-agentkit-context-events.md):
//  context_edited / context_pruned / compacted (+ineffective) / pre_mutation / verified.
//  Covers wire decode, reducer handlers, turn projection, and web document blocks.
//

import XCTest
@testable import AgentKit

final class ContextEventsTests: XCTestCase {

    // MARK: - Helpers

    private func decodeEvent(_ json: String) throws -> AgentEvent? {
        let frame = try JSONDecoder().decode(WireFrame.self, from: Data(json.utf8))
        return AgentEvent.from(wire: frame)
    }

    private func reduce(_ events: [AgentEvent]) -> ExecutionGraph {
        var reducer = ExecutionReducer()
        var graph = ExecutionGraph()
        for e in events { _ = reducer.reduce(e, into: &graph) }
        return graph
    }

    private func systemNodes(_ graph: ExecutionGraph) -> [(SystemPayloadKind, String, [String: String])] {
        graph.nodes.values.compactMap { node in
            guard case .system(let payload) = node.payload else { return nil }
            return (payload.kind, payload.text, payload.metadata)
        }
    }

    // MARK: - Wire decode

    func testDecodeContextEdited() throws {
        let event = try decodeEvent(
            #"{"kind":"context_edited","at":"2026-07-02T10:00:00.000Z","turn_id":"t1","text":"cleared 3 stale tool results"}"#
        )
        guard case .contextEdited(let turnID, let text)? = event else {
            return XCTFail("expected contextEdited, got \(String(describing: event))")
        }
        XCTAssertEqual(turnID, "t1")
        XCTAssertEqual(text, "cleared 3 stale tool results")
    }

    func testDecodeContextPruned() throws {
        let event = try decodeEvent(
            #"{"kind":"context_pruned","at":"2026-07-02T10:00:01.000Z","turn_id":"t1","before_tokens":3000,"saved_tokens":1200}"#
        )
        guard case .contextPruned(let turnID, let beforeTokens, let savedTokens)? = event else {
            return XCTFail("expected contextPruned, got \(String(describing: event))")
        }
        XCTAssertEqual(turnID, "t1")
        XCTAssertEqual(beforeTokens, 3000)
        XCTAssertEqual(savedTokens, 1200)
    }

    func testDecodePreMutation() throws {
        let event = try decodeEvent(
            #"{"kind":"pre_mutation","at":"2026-07-02T10:00:02.000Z","turn_id":"t1","text":"Edit is safe: only appends a case to the enum."}"#
        )
        guard case .preMutation(let turnID, let text)? = event else {
            return XCTFail("expected preMutation, got \(String(describing: event))")
        }
        XCTAssertEqual(turnID, "t1")
        XCTAssertEqual(text, "Edit is safe: only appends a case to the enum.")
    }

    func testDecodeVerified() throws {
        let event = try decodeEvent(
            #"{"kind":"verified","at":"2026-07-02T10:00:03.000Z","turn_id":"t1","text":"go build ./...: ok"}"#
        )
        guard case .verified(let turnID, let text)? = event else {
            return XCTFail("expected verified, got \(String(describing: event))")
        }
        XCTAssertEqual(turnID, "t1")
        XCTAssertEqual(text, "go build ./...: ok")
    }

    func testDecodeCompactedWithIneffectiveTrue() throws {
        let event = try decodeEvent(
            #"{"kind":"compacted","at":"2026-07-02T10:00:04.000Z","turn_id":"t1","before_tokens":1000,"after_tokens":950,"saved_tokens":50,"summary_chars":120,"ratio":0.95,"ineffective":true}"#
        )
        guard case .compacted(let turnID, let before, let after, let saved, let chars, let ratio, let ineffective)? = event else {
            return XCTFail("expected compacted, got \(String(describing: event))")
        }
        XCTAssertEqual(turnID, "t1")
        XCTAssertEqual(before, 1000)
        XCTAssertEqual(after, 950)
        XCTAssertEqual(saved, 50)
        XCTAssertEqual(chars, 120)
        XCTAssertEqual(ratio, 0.95)
        XCTAssertTrue(ineffective)
    }

    func testDecodeCompactedWithoutIneffectiveDefaultsFalse() throws {
        let event = try decodeEvent(
            #"{"kind":"compacted","at":"2026-07-02T10:00:04.000Z","turn_id":"t1","before_tokens":1000,"after_tokens":500,"saved_tokens":500,"summary_chars":800,"ratio":0.5}"#
        )
        guard case .compacted(_, _, _, _, _, _, let ineffective)? = event else {
            return XCTFail("expected compacted, got \(String(describing: event))")
        }
        XCTAssertFalse(ineffective)
    }

    // MARK: - Reducer

    func testReducerCreatesSystemNodesForContextAndVerificationEvents() {
        let turn = "t1"
        let graph = reduce([
            .turnStarted(turnID: turn, text: "do it"),
            .contextEdited(turnID: turn, text: "cleared 2 stale tool results"),
            .contextPruned(turnID: turn, beforeTokens: 3000, savedTokens: 1200),
            .compacted(turnID: turn, beforeTokens: 1200, afterTokens: 500,
                       savedTokens: 700, summaryChars: 400, ratio: 0.42, ineffective: true),
            .preMutation(turnID: turn, text: "Edit is additive and safe."),
            .verified(turnID: turn, text: "go build ./...: ok"),
        ])

        let systems = systemNodes(graph)
        func first(_ kind: SystemPayloadKind) -> (String, [String: String])? {
            systems.first { $0.0 == kind }.map { ($0.1, $0.2) }
        }

        let edited = first(.contextEdited)
        XCTAssertEqual(edited?.0, "cleared 2 stale tool results")

        let pruned = first(.contextPruned)
        XCTAssertEqual(pruned?.0, "Context pruned: saved 1200 tokens (3000 → 1800)")
        XCTAssertEqual(pruned?.1["beforeTokens"], "3000")
        XCTAssertEqual(pruned?.1["savedTokens"], "1200")
        XCTAssertEqual(pruned?.1["afterTokens"], "1800")

        let compacted = first(.contextCompact)
        XCTAssertEqual(compacted?.0, "Context compacted: 1200 → 500 tokens (saved 700)")
        XCTAssertEqual(compacted?.1["ineffective"], "true")
        XCTAssertEqual(compacted?.1["ratio"], "0.4")

        let pre = first(.preMutation)
        XCTAssertEqual(pre?.0, "Edit is additive and safe.")

        let verified = first(.verified)
        XCTAssertEqual(verified?.0, "go build ./...: ok")
    }

    func testReducerSkipsEmptyPreMutationAndContextEdited() {
        let turn = "t1"
        let graph = reduce([
            .turnStarted(turnID: turn, text: "do it"),
            .preMutation(turnID: turn, text: ""),
            .contextEdited(turnID: turn, text: ""),
        ])
        let systems = systemNodes(graph)
        XCTAssertFalse(systems.contains { $0.0 == .preMutation })
        XCTAssertFalse(systems.contains { $0.0 == .contextEdited })
    }

    // MARK: - Turn projection

    func testProjectionSurfacesContextAndVerificationBlocks() {
        let turn = "t1"
        let graph = reduce([
            .turnStarted(turnID: turn, text: "do it"),
            .contextEdited(turnID: turn, text: "cleared 2 stale tool results"),
            .contextPruned(turnID: turn, beforeTokens: 3000, savedTokens: 1200),
            .compacted(turnID: turn, beforeTokens: 1200, afterTokens: 500,
                       savedTokens: 700, summaryChars: 400, ratio: 0.42, ineffective: true),
            .preMutation(turnID: turn, text: "Edit is additive and safe."),
            .verified(turnID: turn, text: "go build ./...: ok"),
            .skillLoaded(toolName: "general-readme-skill", skillVersion: "1.0.0"),
            .turnFinished(turnID: turn, text: "Done", textAnnotations: []),
        ])

        let turns = TimelineProjection().projectTurns(graph)
        XCTAssertEqual(turns.count, 1)
        let blocks = turns[0].blocks

        let systemKinds = blocks.compactMap { block -> SystemNodeKind? in
            guard case .system(_, let payload) = block else { return nil }
            return payload.kind
        }

        XCTAssertTrue(systemKinds.contains(.contextEdited), "contextEdited must surface, got \(systemKinds)")
        XCTAssertTrue(systemKinds.contains(.contextPruned), "contextPruned must surface, got \(systemKinds)")
        XCTAssertTrue(systemKinds.contains(.contextCompact), "contextCompact must surface, got \(systemKinds)")
        XCTAssertTrue(systemKinds.contains(.preMutation), "preMutation must surface, got \(systemKinds)")
        XCTAssertTrue(systemKinds.contains(.verified), "verified must surface, got \(systemKinds)")
        XCTAssertFalse(systemKinds.contains(.skillLoaded), "skillLoaded stays demoted, got \(systemKinds)")
    }

    // MARK: - Web document blocks

    func testWebDocumentCarriesSystemKindAndMetadata() throws {
        let turn = ConversationTurn(
            id: "turn-1",
            userPrompt: MessageNodePayload(role: .user, text: "compress"),
            blocks: [
                .system(
                    id: "sys-compact",
                    SystemNodePayload(
                        kind: .contextCompact,
                        text: "Context compacted: 1000 → 500 tokens (saved 500)",
                        metadata: ["ineffective": "true", "beforeTokens": "1000"]
                    )
                ),
                .system(
                    id: "sys-verified",
                    SystemNodePayload(
                        kind: .verified,
                        text: "go build ./...: ok"
                    )
                ),
            ],
            footer: TurnStats(contextTokens: 1_000, totalTokens: 1_100, elapsedMs: 10, invocationCount: 1),
            isLive: false
        )
        let snapshot = RuntimeSnapshot(timeline: [], turns: [turn], generation: 7)
        let document = ConversationWebDocumentBuilder.build(
            snapshot: snapshot,
            conversationID: "conversation-1"
        )

        let blocks = document.turns.first?.blocks ?? []
        XCTAssertEqual(blocks.count, 2)

        XCTAssertEqual(blocks[0].id, "sys-compact")
        XCTAssertEqual(blocks[0].kind, .system)
        XCTAssertEqual(blocks[0].systemKind, "contextCompact")
        XCTAssertEqual(blocks[0].metadata?["ineffective"], "true")
        XCTAssertEqual(blocks[0].metadata?["beforeTokens"], "1000")
        XCTAssertEqual(blocks[0].text, "Context compacted: 1000 → 500 tokens (saved 500)")

        XCTAssertEqual(blocks[1].systemKind, "verified")
        XCTAssertNil(blocks[1].metadata, "verified has no metadata → nil")
    }
}
