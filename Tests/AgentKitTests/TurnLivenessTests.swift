import XCTest
@testable import AgentKit

/// Regression tests for the turn-level "is this still running?" signal that
/// drives the Codex-style process fold.
///
/// The fold must follow the *turn*, not the socket. `RuntimeEngine.isLive` is
/// "the streaming socket is connected", which stays true between turns and
/// reconnects mid-turn — projecting it as turn liveness made a finished turn
/// re-expand (`用时` header disappearing, every block visible again) as soon as
/// any later event produced a snapshot.
final class TurnLivenessTests: XCTestCase {
    private func finishedTurn(turnID: String = "t1") -> [AgentEvent] {
        [
            .turnStarted(turnID: turnID, text: "hello"),
            .tokenDelta(turnID: turnID, text: "answer"),
            .turnFinished(turnID: turnID, text: "answer", textAnnotations: []),
        ]
    }

    func testHistoryOnlyProjectsFinishedTurnAsFinished() async {
        let engine = RuntimeEngine(sessionID: "s")
        await engine.importHistory(finishedTurn())
        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.turns.count, 1)
        XCTAssertEqual(snapshot.turns.last?.isLive, false, "history replay must fold")
    }

    func testSocketConnectivityDoesNotResurrectFinishedTurn() async {
        let engine = RuntimeEngine(sessionID: "s")
        await engine.importHistory(finishedTurn())
        await engine.markLive()
        await engine.ingest(.turnAccepted(turnID: "t1", requestID: nil, text: nil))
        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(
            snapshot.turns.last?.isLive, false,
            "socket connectivity must not resurrect a finished turn as live"
        )
    }

    func testStreamingTurnStaysOpenUntilItFinishes() async {
        let engine = RuntimeEngine(sessionID: "s")
        await engine.markLive()
        await engine.ingest(.turnStarted(turnID: "t1", text: "hello"))
        await engine.ingest(.tokenDelta(turnID: "t1", text: "answer"))
        var snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.turns.last?.isLive, true, "streaming turn stays open")

        await engine.ingest(.turnFinished(turnID: "t1", text: "answer", textAnnotations: []))
        snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.turns.last?.isLive, false, "finished turn must fold")
    }

    func testTurnFoldsAgainAfterFailure() async {
        let engine = RuntimeEngine(sessionID: "s")
        await engine.markLive()
        await engine.ingest(.turnStarted(turnID: "t1", text: "hello"))
        await engine.ingest(.turnFailed(turnID: "t1", text: nil, err: "boom", errorCode: nil))
        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.turns.last?.isLive, false)
    }

    func testHistoryEndingMidTurnKeepsTurnLive() async {
        let engine = RuntimeEngine(sessionID: "s")
        await engine.importHistory([
            .turnStarted(turnID: "t1", text: "hello"),
            .tokenDelta(turnID: "t1", text: "partial"),
        ])
        await engine.markLive()
        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(
            snapshot.turns.last?.isLive, true,
            "opening the app mid-turn must keep the running turn expanded"
        )
    }

    func testPreviousTurnFoldsWhenNextTurnStarts() async {
        let engine = RuntimeEngine(sessionID: "s")
        await engine.markLive()
        await engine.ingest(.turnStarted(turnID: "t1", text: "first"))
        await engine.ingest(.turnFinished(turnID: "t1", text: "first answer", textAnnotations: []))
        await engine.ingest(.turnStarted(turnID: "t2", text: "second"))

        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.turns.count, 2)
        XCTAssertEqual(snapshot.turns.first?.isLive, false, "the finished turn folds")
        XCTAssertEqual(snapshot.turns.last?.isLive, true, "only the running turn stays open")
    }
}
