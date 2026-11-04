import XCTest
@testable import AgentKit

/// Probe: the moment a live turn finishes, the per-turn bottom row must become
/// renderable on BOTH renderers in the same snapshot:
///   - Web: `turn.copyActionID` / `shareActionID` become non-nil (they are nil
///     while `turn.isLive`), so `turn-actions` appears without waiting for the
///     next turn or an app restart.
///   - iOS: the last text block's `isStreaming` clears, so `bottomRow`'s copy
///     button (`!isAnswerStreaming`) appears.
final class TurnActionsAvailabilityTests: XCTestCase {
    @MainActor
    private func finishedEngine() async -> RuntimeEngine {
        let engine = RuntimeEngine(sessionID: "s")
        await engine.markLive()
        await engine.ingest(.turnStarted(turnID: "t1", text: "hello"))
        await engine.ingest(.tokenDelta(turnID: "t1", text: "partial "))
        await engine.ingest(.tokenDelta(turnID: "t1", text: "answer"))
        await engine.ingest(.turnFinished(turnID: "t1", text: "partial answer", textAnnotations: []))
        return engine
    }

    @MainActor
    func testFinishedTurnClearsStreamingFlagImmediately() async {
        let engine = await finishedEngine()
        let snapshot = await engine.currentSnapshot()
        let turn = try! XCTUnwrap(snapshot.turns.last)
        XCTAssertFalse(turn.isLive)

        let lastText = turn.blocks.reversed().compactMap { block -> MessageNodePayload? in
            if case .text(_, let payload) = block { return payload }
            return nil
        }.first
        let payload = try! XCTUnwrap(lastText, "turn must end with a text block")
        XCTAssertFalse(
            payload.isStreaming,
            "the answer's streaming flag must clear on turn_finished, not on the next turn"
        )
    }

    @MainActor
    func testFinishedTurnRegistersCopyActionImmediately() async {
        let engine = await finishedEngine()
        let snapshot = await engine.currentSnapshot()
        let registry = ConversationWebActionRegistry()
        registry.beginRevision(1)
        let document = ConversationWebDocumentBuilder.build(
            snapshot: snapshot,
            conversationID: "c",
            revision: 1,
            registerAction: registry.register
        )
        registry.finishRevision(
            retaining: ConversationWebDocumentBuilder.actionTokens(in: document)
        )

        let turn = try! XCTUnwrap(document.turns.last)
        XCTAssertNotNil(
            turn.copyActionID,
            "copy action must register the moment the turn finishes"
        )
        XCTAssertNotNil(turn.shareActionID)
    }

    /// E2E over the reuse + diff pipeline the live workbench actually runs:
    /// acknowledged live document → finished snapshot → buildWithStableTurns
    /// → differ. The stable-turn fast path must NOT swallow the finish flip,
    /// otherwise `turn-actions` waits for the next turn or a restart.
    @MainActor
    func testFinishFlipSurvivesReuseAndDiff() async {
        let engine = RuntimeEngine(sessionID: "s")
        await engine.markLive()
        await engine.ingest(.turnStarted(turnID: "t1", text: "hello"))
        await engine.ingest(.tokenDelta(turnID: "t1", text: "answer"))

        let liveSnapshot = await engine.currentSnapshot()
        let registry = ConversationWebActionRegistry()
        registry.beginRevision(1)
        let liveDocument = ConversationWebDocumentBuilder.buildWithStableTurns(
            snapshot: liveSnapshot,
            conversationID: "c",
            revision: 1,
            registerAction: registry.register
        ).document
        registry.finishRevision(
            retaining: ConversationWebDocumentBuilder.actionTokens(in: liveDocument)
        )
        XCTAssertNil(liveDocument.turns.last?.copyActionID, "live turn has no actions yet")

        await engine.ingest(.turnFinished(turnID: "t1", text: "answer", textAnnotations: []))
        let finishedSnapshot = await engine.currentSnapshot()

        registry.beginRevision(2)
        let buildResult = ConversationWebDocumentBuilder.buildWithStableTurns(
            snapshot: finishedSnapshot,
            conversationID: "c",
            revision: 2,
            reusing: .init(
                snapshot: liveSnapshot,
                document: liveDocument,
                extensionContributions: [:]
            ),
            registerAction: registry.register
        )
        let finishedDocument = buildResult.document
        registry.finishRevision(
            retaining: ConversationWebDocumentBuilder.actionTokens(in: finishedDocument)
        )

        XCTAssertFalse(
            buildResult.stableTurnIDs.contains("t1"),
            "the finish flip (isLive, clock, actions) must dirty the turn"
        )
        let update = ConversationWebDocumentDiffer.update(
            from: liveDocument,
            to: finishedDocument,
            stableTurnIDs: buildResult.stableTurnIDs
        )
        let ops = try! XCTUnwrap(update?.patch?.operations)
        let updatedTurn = ops.compactMap { operation -> ConversationWebDocument.Turn? in
            guard operation.kind == .updateTurn || operation.kind == .replaceTurn else {
                return nil
            }
            return operation.turn
        }.last
        let turn = try! XCTUnwrap(
            updatedTurn,
            "the finished turn must produce an updateTurn/replaceTurn operation"
        )
        XCTAssertNotNil(turn.copyActionID, "the operation must carry the copy action")
        XCTAssertNotNil(turn.shareActionID)
    }

    @MainActor
    func testRuntimeModelSelectionPreservesProviderRouteThroughProjection() async throws {
        let engine = RuntimeEngine(sessionID: "s")
        await engine.markLive()
        await engine.ingest(.turnStarted(turnID: "t1", text: "hello"))
        var request = ModelRequestInfo(modelName: "deepseek/deepseek-v4.1-flash",
                                       provider: "openai_compatible", reasoningEffort: nil)
        request.selection = try JSONDecoder().decode(ModelSelectionIdentity.self, from: Data(
            #"{"resolved_model":"openrouter/auto","provider":"openrouter"}"#.utf8
        ))
        await engine.ingest(.modelRequest(turnID: "t1", invocationID: "i1", request: request))
        let requestedSnapshot = await engine.currentSnapshot()
        XCTAssertEqual(requestedSnapshot.turns.last?.modelRoute, "openrouter/auto")
        let actualSelection = try JSONDecoder().decode(ModelSelectionIdentity.self, from: Data(
            #"{"resolved_model":"openrouter/auto","actual_model":"deepseek/deepseek-v4.1-flash","provider":"openai_compatible"}"#.utf8
        ))
        await engine.ingest(.modelFinished(
            turnID: "t1", promptTokens: 100, completionTokens: 100, totalTokens: 200,
            billingUnits: nil, elapsedMs: 100, invocationID: "i1", err: nil,
            selection: actualSelection
        ))
        await engine.ingest(.turnFinished(turnID: "t1", text: "done", textAnnotations: []))
        let snapshot = await engine.currentSnapshot()
        let document = ConversationWebDocumentBuilder.build(snapshot: snapshot, conversationID: "c")
        XCTAssertEqual(document.turns.last?.modelRoute, "openrouter/deepseek/deepseek-v4.1-flash")
    }

}
