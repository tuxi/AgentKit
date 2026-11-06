import XCTest
@testable import AgentKit

final class BackgroundContinuationTests: XCTestCase {
    func testSnapshotCannotReverseResumeOrReviveTerminal() throws {
        var tracker = BackgroundContinuationTracker()
        tracker.reduce(.turnStarted(turnID: "work", text: "start"))
        XCTAssertTrue(tracker.reduce(.backgroundContinuation(.init(turnID: "work", state: "waiting", revision: 1))))
        XCTAssertTrue(tracker.reduce(.backgroundContinuation(.init(turnID: "work", state: "resuming", revision: 1))))
        XCTAssertFalse(tracker.reduce(.backgroundContinuation(.init(turnID: "work", state: "ready", revision: 1))))
        XCTAssertEqual(tracker.current?.state, "resuming")
        XCTAssertTrue(tracker.reduce(.backgroundContinuation(.init(turnID: "work", state: "waiting", revision: 2))))
        tracker.reduce(.turnFinished(turnID: "work", text: "done", textAnnotations: []))
        XCTAssertFalse(tracker.reduce(.backgroundContinuation(.init(turnID: "work", state: "waiting", revision: 2))))
        XCTAssertNil(tracker.current)
    }

    func testNewInputRetiresOlderWaitAndLateSignals() {
        var tracker = BackgroundContinuationTracker()
        tracker.reduce(.turnStarted(turnID: "old", text: "old"))
        tracker.reduce(.backgroundContinuation(.init(turnID: "old", state: "waiting", revision: 1)))
        tracker.reduce(.turnAccepted(turnID: "new", requestID: "request", text: nil))
        XCTAssertFalse(tracker.reduce(.backgroundContinuation(.init(turnID: "old", state: "resuming", revision: 2))))
        XCTAssertEqual(tracker.activeTurnID, "new")
        XCTAssertNil(tracker.current)
    }

    func testWireAndControlSnapshotShareTypedProjection() throws {
        for header in [#""kind":"turn_waiting_background""#, #""type":"background_continuation_ready","enabled":true"#] {
            let json = "{" + header + #","turn_id":"work","background":{"turn_id":"work","state":"waiting","revision":3,"job_ids":["job_x"]}}"#
            let frame = try JSONDecoder().decode(WireFrame.self, from: Data(json.utf8))
            guard case .backgroundContinuation(let info) = AgentEvent.from(wire: frame) else { return XCTFail("background state was dropped") }
            XCTAssertEqual(info.turnID, "work"); XCTAssertEqual(info.revision, 3); XCTAssertEqual(info.jobIDs, ["job_x"])
        }
    }

    func testHistoryAndLiveHaveSameWaitingProjection() async {
        let events: [AgentEvent] = [
            .turnStarted(turnID: "work", text: "start"),
            .modelFinished(turnID: "work", promptTokens: 8, completionTokens: 2, totalTokens: 10, billingUnits: 4, elapsedMs: 1, invocationID: "one", err: nil),
            .backgroundContinuation(.init(turnID: "work", state: "waiting", revision: 1)),
            .backgroundContinuation(.init(turnID: "work", state: "resuming", revision: 1)),
            .backgroundContinuation(.init(turnID: "work", state: "waiting", revision: 2)),
        ]
        let live = RuntimeEngine(sessionID: "session")
        for event in events { await live.ingest(event) }
        let history = RuntimeEngine(sessionID: "session")
        await history.importHistory(events)
        let a = await live.currentSnapshot()
        let b = await history.currentSnapshot()
        XCTAssertEqual(a.backgroundContinuation, b.backgroundContinuation)
        XCTAssertEqual(a.turns.count, b.turns.count)
        XCTAssertEqual(a.modelStats?.totalTokens, b.modelStats?.totalTokens)
        XCTAssertNil(b.turnStartedAt)
    }

    func testTargetedCancelPayloadNeverDropsIdentity() throws {
        let data = try JSONEncoder().encode(OutgoingCancelTurn(turnID: "work"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(object["turn_id"], "work")
        XCTAssertEqual(object["type"], "cancel_turn")
    }

    func testEngineWaitAndResumeKeepOneTurnAndUsage() async {
        let engine = RuntimeEngine(sessionID: "session")
        await engine.ingest(.turnStarted(turnID: "work", text: "start"))
        await engine.ingest(.modelFinished(turnID: "work", promptTokens: 8, completionTokens: 2, totalTokens: 10, billingUnits: 4, elapsedMs: 1, invocationID: "one", err: nil))
        await engine.ingest(.backgroundContinuation(.init(turnID: "work", state: "waiting", revision: 1)))
        let waiting = await engine.currentSnapshot()
        XCTAssertNil(waiting.turnStartedAt)
        XCTAssertEqual(waiting.backgroundContinuation?.state, "waiting")
        await engine.ingest(.backgroundContinuation(.init(turnID: "work", state: "resuming", revision: 1)))
        await engine.ingest(.modelFinished(turnID: "work", promptTokens: 16, completionTokens: 4, totalTokens: 20, billingUnits: 6, elapsedMs: 2, invocationID: "two", err: nil))
        let resumed = await engine.currentSnapshot()
        XCTAssertEqual(resumed.turns.count, 1)
        XCTAssertEqual(resumed.modelStats?.totalTokens, 30)
        await engine.ingest(.turnFinished(turnID: "work", text: "done", textAnnotations: []))
        let done = await engine.currentSnapshot()
        XCTAssertNil(done.backgroundContinuation)
        XCTAssertEqual(done.turns.count, 1)
    }
}
