import XCTest
@testable import AgentKit

final class BackgroundJobPresentationTests: XCTestCase {
    private func wait(_ id: String, job: String? = "job-1", name: String = "job_wait") -> ToolNodePayload {
        .init(callID: id, toolName: name,
              args: job.map { .object(["job_id": .string($0)]) }, status: .completed,
              output: "still running", elapsedMs: 1_000)
    }

    func testJobOperationsAreLocalizedWithoutGuessingUnknownTools() {
        let titles = ["job_wait": "等待后台任务", "job_status": "查看后台任务状态",
                      "job_logs": "查看后台任务日志", "job_cancel": "请求停止后台任务"]
        for (name, title) in titles {
            let tool = wait(name, name: name)
            XCTAssertEqual(ToolTranscriptPresenter.presentation(for: tool, locale: "zh-Hans").title, title)
        }
        XCTAssertNil(BackgroundJobPresentation.operation("mcp_job_wait"))
        XCTAssertEqual(ToolTranscriptPresenter.presentation(for: wait("w"), locale: "en").title, "Wait for background task")
    }

    func testScriptPreviewRetainsNoBodyAndDoesNotInventPurpose() {
        let text = ToolTranscriptText(locale: "zh-Hans")
        let script = "python3 - <<'PY'\np = 'sh/build.sh'\nprint(p)\nPY"
        XCTAssertEqual(BackgroundJobPresentation.summary(script, text: text), "Python 脚本")
        XCTAssertEqual(BackgroundJobPresentation.summary("/usr/bin/python3.12 -c 'print(1)'", text: text), "Python 脚本")
        XCTAssertEqual(BackgroundJobPresentation.summary("sh <<'EOF'\nmake\nEOF", text: text), "脚本")
        XCTAssertEqual(BackgroundJobPresentation.summary("npm test", text: text), "npm test")
        XCTAssertEqual(BackgroundJobPresentation.summary("curl --token secret-value example.com", text: text), text.text("hidden"))
    }

    func testWaitRunsRequireAdjacentCallsAndAnExplicitMatchingJobID() {
        let entries: [ToolGroup.Entry] = [.tool(wait("a")), .tool(wait("b")),
            .thinking(id: "thought", .init(text: "check")), .tool(wait("c")),
            .tool(wait("d", job: "job-2")), .tool(wait("e", job: nil)), .tool(wait("f", job: nil))]
        XCTAssertEqual(BackgroundJobPresentation.waitRuns(in: entries).map(\.count), [2, 1, 1, 1, 1, 1])
        let group = ToolGroup(id: "g", entries: [.tool(wait("a")), .tool(wait("b")), .tool(wait("c"))])
        XCTAssertEqual(ToolTranscriptPresenter.groupPresentation(for: group, locale: "zh-Hans").summary,
                       "等待后台任务 · 3 次")
    }

    @MainActor
    func testWaitReturnKeepsJobRunningAndLinksAcrossActivityBoundaries() throws {
        var reducer = ExecutionReducer()
        var graph = ExecutionGraph()
        let script = "python3 - <<'PY'\nprint('building')\nPY"
        let events: [AgentEvent] = [
            .turnStarted(turnID: "t1", text: "build"),
            .toolStarted(turnID: "t1", callID: "launch", tool: .init(callID: "launch", toolName: "run_command", toolArgs: .object(["background": .bool(true)]))),
            .jobStarted(turnID: "t1", jobID: "job-1", callID: "launch", command: script),
            .jobOutput(turnID: "t1", jobID: "job-1", chunk: "log line\n"),
            .toolStarted(turnID: "t1", callID: "w1", tool: .init(callID: "w1", toolName: "job_wait", toolArgs: .object(["job_id": .string("job-1")]))),
            .toolFinished(turnID: "t1", callID: "w1", result: .init(callID: "w1", toolName: "job_wait", observation: "still running", error: nil)),
            .assistantText(turnID: "t1", text: "Check another thing"),
            .toolStarted(turnID: "t1", callID: "w2", tool: .init(callID: "w2", toolName: "job_wait", toolArgs: .object(["job_id": .string("job-1")])))]
        for event in events { _ = reducer.reduce(event, into: &graph) }
        func turn() throws -> ConversationTurn { try XCTUnwrap(TimelineProjection().projectTurns(graph, isLive: true).first) }
        let current = try turn()
        let jobs = current.blocks.compactMap { block -> ChildStreamNodePayload? in
            if case .childStream(_, let payload) = block { return payload }; return nil
        }
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.status, .running, "a returned wait is not a terminal job event")
        XCTAssertEqual(jobs.first?.output, "log line\n")
        let tools = current.blocks.flatMap { block -> [ToolNodePayload] in
            if case .toolGroup(let group) = block { return group.tools }; return []
        }
        XCTAssertEqual(tools.map(\.callID), ["w1", "w2"], "the launcher must not duplicate the job entry")
        XCTAssertTrue(tools.allSatisfy { $0.backgroundJobCommand == script })
        XCTAssertEqual(ToolTranscriptPresenter.presentation(for: tools[0], locale: "zh-Hans").detail, "Python 脚本")
        let document = ConversationWebDocumentBuilder.build(snapshot: .init(timeline: [], turns: [current]), conversationID: "job")
        let webJob = try XCTUnwrap(document.turns[0].blocks.first { $0.childStreamKind == "job" })
        XCTAssertEqual(webJob.title, ToolTranscriptText().text("job.run", ToolTranscriptText().text("job.python")))
        XCTAssertNil(webJob.elapsed)
        _ = reducer.reduce(.jobFinished(turnID: "t1", jobID: "job-1", exitCode: nil, err: nil, elapsedMs: 35_000, text: "exited"), into: &graph)
        let finished = try turn()
        let finalDoc = ConversationWebDocumentBuilder.build(snapshot: .init(timeline: [], turns: [finished]), conversationID: "job")
        let finalJob = try XCTUnwrap(finalDoc.turns[0].blocks.first { $0.childStreamKind == "job" })
        XCTAssertEqual(finalJob.status, "completed")
        XCTAssertEqual(finalJob.elapsed, ToolTranscriptText().text("job.elapsed", "35.0s"))
    }
}
