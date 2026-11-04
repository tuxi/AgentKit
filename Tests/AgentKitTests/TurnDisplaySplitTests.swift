import XCTest
@testable import AgentKit

/// The iOS renderer now folds a finished turn the way the Web renderer does.
/// Both read this split, so these tests pin the rules that make the fold
/// trustworthy: the answer never disappears, an error never hides, and a live
/// turn is never folded at all.
final class TurnDisplaySplitTests: XCTestCase {
    private func thinking(_ text: String = "weighing options") -> TurnBlock {
        .thinking(id: "think-\(text)", ThinkingNodePayload(text: text))
    }

    private func text(_ value: String, streaming: Bool = false) -> TurnBlock {
        .text(id: "text-\(value)", MessageNodePayload(role: .assistant, text: value, isStreaming: streaming))
    }

    private func group(_ id: String, status: ToolNodeStatus) -> TurnBlock {
        .toolGroup(ToolGroup(id: id, tools: [
            ToolNodePayload(callID: "call-\(id)", toolName: "read_file", args: nil, status: status),
        ]))
    }

    private func errorBlock(_ text: String = "command failed") -> TurnBlock {
        .system(id: "sys-\(text)", SystemNodePayload(kind: .error, text: text))
    }

    private func turn(_ blocks: [TurnBlock], isLive: Bool = false, changes: TurnChanges? = nil,
                      startedAt: Date? = nil, finishedAt: Date? = nil) -> ConversationTurn {
        ConversationTurn(
            id: "turn-1",
            userPrompt: MessageNodePayload(role: .user, text: "do the thing"),
            blocks: blocks,
            footer: nil,
            isLive: isLive,
            startedAt: startedAt,
            finishedAt: finishedAt,
            changes: changes
        )
    }

    // MARK: - Split

    func testLiveTurnIsNeverFolded() {
        let subject = turn([thinking(), text("working on it", streaming: true)], isLive: true)
        let split = subject.displaySplit
        XCTAssertTrue(split.process.isEmpty)
        XCTAssertEqual(split.answer.count, 2, "a running turn shows its work")
    }

    func testCompletedTurnFoldsEverythingBeforeTheAnswer() {
        let subject = turn([thinking(), group("g1", status: .completed), text("done")])
        let split = subject.displaySplit
        XCTAssertEqual(split.process.count, 2)
        XCTAssertEqual(split.answer.count, 1)
        XCTAssertTrue(split.hasProcess)
    }

    func testFailedToolIsPulledOutOfTheFold() {
        let subject = turn([group("bad", status: .failed), thinking(), text("gave up")])
        let split = subject.displaySplit
        XCTAssertEqual(split.process.count, 1, "only the thinking stays folded")
        XCTAssertEqual(split.answer.count, 2)
        XCTAssertEqual(split.answer.first, group("bad", status: .failed))
        XCTAssertEqual(split.answer.last, text("gave up"))
    }

    func testErroredSystemLineIsPulledOutOfTheFold() {
        let subject = turn([errorBlock(), text("retried and finished")])
        let split = subject.displaySplit
        XCTAssertTrue(split.process.isEmpty)
        XCTAssertEqual(split.answer.count, 2)
    }

    /// Step-limit / cancelled turns answer with tools only. Folding everything
    /// would leave an empty bubble, so failures stay outside even here.
    func testToolOnlyTurnKeepsEveryFailureVisible() {
        let subject = turn([group("ok", status: .completed), group("bad", status: .failed)])
        let split = subject.displaySplit
        XCTAssertEqual(split.process.count, 1)
        XCTAssertEqual(split.answer.count, 1)
        XCTAssertEqual(split.answer.first, group("bad", status: .failed))
    }

    func testWhitespaceTextIsNotAnAnswer() {
        let subject = turn([group("g1", status: .completed), text("   ")])
        let split = subject.displaySplit
        XCTAssertEqual(split.process.count, 2)
        XCTAssertTrue(split.answer.isEmpty)
    }

    func testExpandedOrderRestoresProcessThenAnswer() {
        let subject = turn([thinking(), text("done")])
        let split = subject.displaySplit
        XCTAssertEqual(split.allBlocks.map(\.id), ["think-weighing options", "text-done"])
    }

    // MARK: - Header label

    func testSummaryLabelCombinesDurationAndChanges() {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let subject = turn(
            [text("done")],
            changes: TurnChanges(
                files: [TurnChanges.FileChange(path: "a.swift", added: 1, removed: 0, status: .modified)],
                filesChanged: 1, addedLines: 1, removedLines: 0
            ),
            startedAt: started,
            finishedAt: started.addingTimeInterval(1_480)
        )
        XCTAssertEqual(subject.processSummaryLabel, "用时 24分40秒 · 编辑 1 个文件")
    }

    func testSummaryLabelFallsBackToWhicheverHalfIsKnown() {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            turn([text("done")], startedAt: started, finishedAt: started.addingTimeInterval(48))
                .processSummaryLabel,
            "用时 48秒"
        )
        XCTAssertEqual(
            turn([text("done")], changes: TurnChanges(
                files: [TurnChanges.FileChange(path: "a.swift", added: 3, removed: 1, status: .modified)],
                filesChanged: 1, addedLines: 3, removedLines: 1
            )).processSummaryLabel,
            "编辑 1 个文件"
        )
        XCTAssertNil(turn([text("done")]).processSummaryLabel,
                     "no clock and no changes must not render a stub header")
    }

    /// Old history has no wall clock. The fold still needs a reachable header,
    /// otherwise the turn's work disappears with no way to open it.
    func testHeaderFallsBackToTheGenericLabelWhenThereIsWorkToFold() {
        let subject = turn([thinking(), text("done")])
        XCTAssertEqual(subject.processHeaderLabel(hasProcess: true), "查看执行过程")
        XCTAssertNil(subject.processHeaderLabel(hasProcess: false),
                     "nothing folded and nothing to report means no header at all")
    }

    func testHeaderPrefersFactsOverTheGenericLabel() {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let subject = turn([text("done")], startedAt: started,
                           finishedAt: started.addingTimeInterval(48))
        XCTAssertEqual(subject.processHeaderLabel(hasProcess: true), "用时 48秒")
    }

    // MARK: - Duration text

    func testDurationTextMatchesTheWebFormatter() {
        XCTAssertEqual(TurnDurationText.string(seconds: 48), "48秒")
        XCTAssertEqual(TurnDurationText.string(seconds: 60), "1分")
        XCTAssertEqual(TurnDurationText.string(seconds: 900), "15分")
        XCTAssertEqual(TurnDurationText.string(seconds: 1_480), "24分40秒")
        XCTAssertEqual(TurnDurationText.string(seconds: 3_900), "1小时5分")
        XCTAssertEqual(TurnDurationText.string(seconds: 7_200), "2小时")
        XCTAssertEqual(TurnDurationText.string(seconds: 0), "0秒")
        XCTAssertEqual(TurnDurationText.string(seconds: -5), "0秒")
    }

    // MARK: - Change card math

    private func changes(fileCount: Int, filesChanged: Int? = nil) -> TurnChanges {
        let files = (0..<fileCount).map { index in
            TurnChanges.FileChange(path: "f\(index).swift", added: index, removed: 0, status: .modified)
        }
        return TurnChanges(
            files: files,
            filesChanged: filesChanged ?? fileCount,
            addedLines: files.reduce(0) { $0 + $1.added },
            removedLines: 0
        )
    }

    func testPreviewShowsLargestChangesFirst() {
        let preview = changes(fileCount: 5).preview(limit: 3)
        XCTAssertEqual(preview.rows.map(\.path), ["f4.swift", "f3.swift", "f2.swift"])
        XCTAssertEqual(preview.hiddenCount, 2)
        XCTAssertEqual(preview.withheldCount, 0)
    }

    func testPreviewTieBreaksOnPathSoRowsNeverReshuffle() {
        let even = TurnChanges(
            files: ["b.swift", "a.swift", "c.swift"].map {
                TurnChanges.FileChange(path: $0, added: 5, removed: 0, status: .modified)
            },
            filesChanged: 3, addedLines: 15, removedLines: 0
        )
        XCTAssertEqual(even.preview(limit: 3).rows.map(\.path), ["a.swift", "b.swift", "c.swift"])
    }

    /// Rows + folded + withheld must always equal `filesChanged`, or the card
    /// contradicts its own header (the bug this math replaced).
    func testPreviewCountsAddUpWhenTheRuntimeClippedTheList() {
        let clipped = changes(fileCount: 200, filesChanged: 250)
        let preview = clipped.preview(limit: 3)
        XCTAssertEqual(preview.rows.count, 3)
        XCTAssertEqual(preview.hiddenCount, 197)
        XCTAssertEqual(preview.withheldCount, 50)
        XCTAssertEqual(preview.rows.count + preview.hiddenCount + preview.withheldCount,
                       clipped.filesChanged)
    }

    func testPreviewWithFewerFilesThanTheLimitOffersNothingToFold() {
        let preview = changes(fileCount: 2).preview(limit: 3)
        XCTAssertEqual(preview.rows.count, 2)
        XCTAssertEqual(preview.hiddenCount, 0)
        XCTAssertEqual(preview.withheldCount, 0)
    }
}
