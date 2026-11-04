//
//  TurnWallClockTests.swift
//  AgentKitTests
//
//  L1 turn summary: a finished turn reports its wall-clock duration
//  ("用时 24分40秒"), which only the server-stamped turn boundaries can provide
//  — replayed history arrives in a burst.
//

import XCTest
@testable import AgentKit

final class TurnWallClockTests: XCTestCase {

    // MARK: - Merging

    func testMergingKeepsEarliestStartAndLatestEnd() {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 1_600)

        let live = TurnWallClock(startedAt: start, finishedAt: nil)
        let history = TurnWallClock(
            startedAt: start.addingTimeInterval(2),
            finishedAt: end
        )

        let merged = live.merging(history)
        XCTAssertEqual(merged.startedAt, start)
        XCTAssertEqual(merged.finishedAt, end)

        // Order of observation must not matter.
        XCTAssertEqual(history.merging(live), merged)
    }

    func testMergingFillsMissingBoundaries() {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 1_600)

        XCTAssertEqual(
            TurnWallClock(startedAt: start).merging(TurnWallClock(finishedAt: end)),
            TurnWallClock(startedAt: start, finishedAt: end)
        )
        XCTAssertTrue(TurnWallClock().isEmpty)
        XCTAssertEqual(TurnWallClock().merging(TurnWallClock()), TurnWallClock())
    }

    // MARK: - Formatting

    private func turn(seconds: Int) -> ConversationTurn {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return ConversationTurn(
            id: "t1", userPrompt: nil, blocks: [], footer: nil, isLive: false,
            startedAt: start,
            finishedAt: start.addingTimeInterval(TimeInterval(seconds))
        )
    }

    func testFormattedDurationMatchesCodexWording() {
        XCTAssertEqual(turn(seconds: 48).formattedDuration, "48秒")
        XCTAssertEqual(turn(seconds: 60).formattedDuration, "1分")
        XCTAssertEqual(turn(seconds: 1_480).formattedDuration, "24分40秒")
        XCTAssertEqual(turn(seconds: 3_900).formattedDuration, "1小时5分")
        XCTAssertEqual(turn(seconds: 7_200).formattedDuration, "2小时")
    }

    func testUnfinishedTurnHasNoDuration() {
        let running = ConversationTurn(
            id: "t1", userPrompt: nil, blocks: [], footer: nil, isLive: true,
            startedAt: Date(), finishedAt: nil
        )
        XCTAssertNil(running.elapsedSeconds)
        XCTAssertNil(running.formattedDuration)
        XCTAssertNil(running.finishedAtClock)
    }

    func testFinishedClockUsesLocalDayAndIncludesHistoricalDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3600))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 4, hour: 0, minute: 10
        )))
        func clock(year: Int, month: Int, day: Int, hour: Int, minute: Int) throws -> String? {
            let end = try XCTUnwrap(calendar.date(from: DateComponents(
                year: year, month: month, day: day, hour: hour, minute: minute
            )))
            return ConversationTurn(
                id: "t", userPrompt: nil, blocks: [], footer: nil, isLive: false,
                finishedAt: end
            ).finishedAtClock(relativeTo: now, calendar: calendar)
        }
        XCTAssertEqual(try clock(year: 2026, month: 11, day: 4, hour: 0, minute: 5), "00:05")
        XCTAssertEqual(try clock(year: 2026, month: 11, day: 3, hour: 23, minute: 59), "11月3日 23:59")
        XCTAssertEqual(try clock(year: 2026, month: 10, day: 18, hour: 20, minute: 20), "10月18日 20:20")
        XCTAssertEqual(try clock(year: 2025, month: 10, day: 18, hour: 20, minute: 20), "2025年10月18日 20:20")
    }

    // MARK: - Projection

    private func reduce(_ events: [AgentEvent]) -> ExecutionGraph {
        var reducer = ExecutionReducer()
        var graph = ExecutionGraph()
        for event in events { _ = reducer.reduce(event, into: &graph) }
        return graph
    }

    func testProjectedTurnUsesServerStampInsteadOfIngestTime() {
        let turnID = "t1"
        let graph = reduce([
            .turnStarted(turnID: turnID, text: "go"),
            .tokenDelta(turnID: turnID, text: "done"),
            .turnFinished(turnID: turnID, text: "done", textAnnotations: [])
        ])

        let serverStart = Date(timeIntervalSince1970: 1_700_000_000)
        let serverEnd = serverStart.addingTimeInterval(1_480)
        let projection = TimelineProjection()
        let projected = projection.buildTurn(
            nodes: projection.projectNodes(graph),
            isLive: false,
            wallClock: TurnWallClock(startedAt: serverStart, finishedAt: serverEnd)
        )

        // Ingest timestamps are seconds apart at most; the server stamp must win.
        XCTAssertEqual(projected.startedAt, serverStart)
        XCTAssertEqual(projected.finishedAt, serverEnd)
        XCTAssertEqual(projected.formattedDuration, "24分40秒")
    }

    func testLiveTurnReportsStartWithoutEnd() {
        let turnID = "t1"
        let graph = reduce([
            .turnStarted(turnID: turnID, text: "go"),
            .tokenDelta(turnID: turnID, text: "partial")
        ])

        let projection = TimelineProjection()
        let projected = projection.buildTurn(
            nodes: projection.projectNodes(graph),
            isLive: true,
            wallClock: nil
        )

        XCTAssertNotNil(projected.startedAt)
        XCTAssertNil(projected.finishedAt)
        XCTAssertNil(projected.formattedDuration)
    }

    func testHistoryWithoutServerStampFallsBackToNodeTimestamps() {
        let turnID = "t1"
        let graph = reduce([
            .turnStarted(turnID: turnID, text: "go"),
            .tokenDelta(turnID: turnID, text: "done"),
            .turnFinished(turnID: turnID, text: "done", textAnnotations: [])
        ])

        let projection = TimelineProjection()
        let projected = projection.buildTurn(
            nodes: projection.projectNodes(graph), isLive: false, wallClock: nil
        )

        XCTAssertNotNil(projected.startedAt)
        XCTAssertNotNil(projected.finishedAt)
    }
}
