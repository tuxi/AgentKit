import XCTest
@testable import AgentKit

/// The Runtime reports what a turn wrote on its terminal event
/// (`turn_finished` / `turn_failed` / `turn_cancelled`). These tests pin the
/// contract edges that are easy to get wrong: absence means *unknown*, the file
/// list may be truncated while the totals stay full, and the summary must reach
/// the folded header even when no node changed.
final class TurnChangesTests: XCTestCase {
    private func frame(_ json: String) throws -> WireFrame {
        try JSONDecoder().decode(WireFrame.self, from: Data(json.utf8))
    }

    private func finished(_ changes: TurnChanges?, text: String = "done") -> AgentEvent {
        .turnFinished(turnID: "t1", text: text, textAnnotations: [], changes: changes)
    }

    private func sampleChanges(paths: [String] = ["a.swift"]) -> TurnChanges {
        TurnChanges(
            files: paths.map {
                TurnChanges.FileChange(path: $0, added: 12, removed: 3, status: .modified)
            },
            filesChanged: paths.count,
            addedLines: 12 * paths.count,
            removedLines: 3 * paths.count
        )
    }

    // MARK: - Wire decoding

    func testDecodesDiffStatOnTurnFinished() throws {
        let wire = try frame("""
        {"kind":"turn_finished","turn_id":"t1","text":"done","diffstat":{
          "files":[{"path":"a.swift","added":12,"removed":3,"status":"modified"},
                   {"path":"b.swift","added":8,"removed":0,"status":"added"}],
          "files_changed":2,"added_lines":20,"removed_lines":3}}
        """)

        guard case .turnFinished(_, _, _, let changes) = AgentEvent.from(wire: wire) else {
            return XCTFail("expected turn_finished")
        }
        let decoded = try XCTUnwrap(changes)
        XCTAssertEqual(decoded.filesChanged, 2)
        XCTAssertEqual(decoded.addedLines, 20)
        XCTAssertEqual(decoded.removedLines, 3)
        XCTAssertEqual(decoded.files.map(\.path), ["a.swift", "b.swift"])
        XCTAssertEqual(decoded.files.last?.status, .added)
        XCTAssertEqual(decoded.summaryLabel, "编辑 2 个文件")
    }

    func testAbsentDiffStatMeansUnknownNotZero() throws {
        let wire = try frame("""
        {"kind":"turn_finished","turn_id":"t1","text":"done"}
        """)
        guard case .turnFinished(_, _, _, let changes) = AgentEvent.from(wire: wire) else {
            return XCTFail("expected turn_finished")
        }
        XCTAssertNil(changes, "a turn that reports nothing must not render '编辑 0 个文件'")
    }

    func testTruncatedFileListKeepsFullTotals() throws {
        // The Runtime caps `files` at 200 but keeps the totals complete, so the
        // count must come from files_changed, never from files.count.
        let wire = try frame("""
        {"kind":"turn_finished","turn_id":"t1","text":"done","diffstat":{
          "files":[{"path":"a.swift","added":1,"removed":0,"status":"modified"}],
          "files_changed":300,"added_lines":900,"removed_lines":40}}
        """)
        guard case .turnFinished(_, _, _, let changes) = AgentEvent.from(wire: wire) else {
            return XCTFail("expected turn_finished")
        }
        let decoded = try XCTUnwrap(changes)
        XCTAssertEqual(decoded.files.count, 1)
        XCTAssertEqual(decoded.filesChanged, 300)
        XCTAssertEqual(decoded.summaryLabel, "编辑 300 个文件")
    }

    func testUnknownStatusDoesNotFailDecoding() throws {
        let wire = try frame("""
        {"kind":"turn_finished","turn_id":"t1","text":"done","diffstat":{
          "files":[{"path":"a.swift","added":1,"removed":1,"status":"renamed"}],
          "files_changed":1,"added_lines":1,"removed_lines":1}}
        """)
        guard case .turnFinished(_, _, _, let changes) = AgentEvent.from(wire: wire) else {
            return XCTFail("expected turn_finished")
        }
        XCTAssertEqual(try XCTUnwrap(changes).files.first?.status, .unknown)
    }

    func testMalformedDiffStatDoesNotDropTheAnswer() throws {
        // A bad diffstat must not fail the whole frame: the answer matters more.
        let wire = try frame("""
        {"kind":"turn_finished","turn_id":"t1","text":"the answer","diffstat":{"files":"nope"}}
        """)
        guard case .turnFinished(_, let text, _, let changes) = AgentEvent.from(wire: wire) else {
            return XCTFail("expected turn_finished")
        }
        XCTAssertEqual(text, "the answer")
        XCTAssertEqual(changes?.filesChanged, 0)
    }

    func testFailedTurnCarriesChanges() throws {
        let wire = try frame("""
        {"kind":"turn_failed","turn_id":"t1","error":{"code":"boom","message":"died"},
         "diffstat":{"files":[{"path":"a.swift","added":3,"removed":1,"status":"modified"}],
                     "files_changed":1,"added_lines":3,"removed_lines":1}}
        """)
        guard case .turnFailed(_, _, _, _, let changes) = AgentEvent.from(wire: wire) else {
            return XCTFail("expected turn_failed")
        }
        XCTAssertEqual(changes?.filesChanged, 1)
    }

    // MARK: - Projection

    func testReplayedTurnCarriesChanges() async {
        let engine = RuntimeEngine(sessionID: "s")
        let changes = sampleChanges()
        await engine.importHistory([
            .turnStarted(turnID: "t1", text: "hi"),
            .tokenDelta(turnID: "t1", text: "done"),
            finished(changes),
        ])

        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.turns.last?.changes, changes)
    }

    func testChangesArrivingWithoutNodeChangeStillReachTheTurn() async {
        // Empty final text and nothing streaming: the terminal event touches no
        // node, so only the turn-changes revision can dirty the projection.
        let engine = RuntimeEngine(sessionID: "s")
        await engine.markLive()
        await engine.ingest(.turnStarted(turnID: "t1", text: "hi"))

        var snapshot = await engine.currentSnapshot()
        XCTAssertNil(snapshot.turns.last?.changes)

        let changes = sampleChanges()
        await engine.ingest(finished(changes, text: ""))

        snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.turns.last?.changes, changes,
                       "diffstat must not depend on a node revision")
    }

    func testFailedTurnKeepsChanges() async {
        let engine = RuntimeEngine(sessionID: "s")
        await engine.markLive()
        await engine.ingest(.turnStarted(turnID: "t1", text: "hi"))
        let changes = sampleChanges()
        await engine.ingest(.turnFailed(turnID: "t1", text: nil, err: "boom",
                                        errorCode: nil, changes: changes))

        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.turns.last?.changes, changes,
                       "writes that landed before the failure still count")
    }

    func testTurnWithoutChangesKeepsNil() async {
        let engine = RuntimeEngine(sessionID: "s")
        await engine.importHistory([
            .turnStarted(turnID: "t1", text: "hi"),
            finished(nil),
        ])
        let snapshot = await engine.currentSnapshot()
        XCTAssertNil(snapshot.turns.last?.changes)
    }

    // MARK: - Web document

    func testWebDocumentCarriesSummaryAndFiles() throws {
        let changes = sampleChanges(paths: ["a.swift", "b.swift"])
        let web = try XCTUnwrap(ConversationWebDocument.WebTurnChanges(changes))
        XCTAssertEqual(web.summary, "编辑 2 个文件")
        XCTAssertEqual(web.filesChanged, 2)
        XCTAssertEqual(web.files.map(\.path), ["a.swift", "b.swift"])
        XCTAssertEqual(web.files.first?.status, "modified")
    }

    func testWebDocumentOmitsEmptyChanges() {
        XCTAssertNil(ConversationWebDocument.WebTurnChanges(nil))
        XCTAssertNil(ConversationWebDocument.WebTurnChanges(
            TurnChanges(files: [], filesChanged: 0, addedLines: 0, removedLines: 0)
        ))
    }
}
