import XCTest
@testable import AgentKit

final class ActivityProjectionTests: XCTestCase {
    private func node(_ id: String, _ kind: ExecutionNodeKind, invocation: String = "inv1") -> ExecutionNode {
        ExecutionNode(id: id, kind: kind, timestamp: 1, turnID: "turn", invocationID: invocation)
    }

    private func tool(_ id: String, _ name: String, status: ToolNodeStatus = .completed) -> ToolNodePayload {
        ToolNodePayload(callID: id, toolName: name, args: nil, status: status, output: "output:\(id)")
    }

    func testMixedActivityPreservesOrderAcrossInvocationsAndEmptyNarration() throws {
        let nodes = [
            node("u", .message(.init(role: .user, text: "help"))),
            node("before", .message(.init(role: .assistant, text: "Checking"))),
            node("r", .tool(tool("read", "read_file"))),
            node("thought", .thinking(.init(text: "Look for references", isStreaming: false)), invocation: "inv2"),
            node("empty", .message(.init(role: .assistant, text: " \n"))),
            node("s", .tool(tool("search", "grep")), invocation: "inv2"),
            node("e", .tool(tool("edit", "apply_patch")), invocation: "inv3"),
            node("after", .message(.init(role: .assistant, text: "Done"))),
        ]
        let turn = try XCTUnwrap(TimelineProjection().projectTurns(nodes: nodes).first)
        XCTAssertEqual(turn.blocks.count, 3)
        XCTAssertTrue(turn.displaySplit.hasProcess, "activity and intermediate narration fold at completion")
        XCTAssertEqual(turn.displaySplit.process, Array(turn.blocks.prefix(2)))
        XCTAssertEqual(turn.displaySplit.answer, [turn.blocks[2]])
        guard case .toolGroup(let group) = turn.blocks[1] else { return XCTFail("expected activity") }
        XCTAssertEqual(group.entries.map(\.id), ["tool:read", "thinking:thought", "tool:search", "tool:edit"])
        XCTAssertEqual(group.tools.map(\.output), ["output:read", "output:search", "output:edit"])
        XCTAssertEqual(group.summary, "读取文件、搜索代码、修改文件 · 3 次调用")
    }

    func testFailedActivityFoldsWithVisibleFailureCount() {
        let activity = TurnBlock.toolGroup(ToolGroup(id: "a", entries: [.tool(tool("bad", "grep", status: .failed))]))
        let answer = TurnBlock.text(id: "answer", .init(role: .assistant, text: "Final answer"))
        let start = Date(timeIntervalSince1970: 100)
        let turn = ConversationTurn(id: "t", userPrompt: nil, blocks: [activity, answer], footer: nil,
                                    isLive: false, startedAt: start, finishedAt: start.addingTimeInterval(48))
        XCTAssertEqual(turn.displaySplit.process, [activity])
        XCTAssertEqual(turn.displaySplit.answer, [answer])
        XCTAssertEqual(turn.processHeaderLabel(hasProcess: true), "用时 48秒 · 1 次失败")
    }

    func testFirstEntryIdentitySurvivesGrowthCompletionAndTurnIsolation() throws {
        let projection = TimelineProjection()
        let prefix = [node("u", .message(.init(role: .user, text: "help"))),
                      node("r", .tool(tool("read", "read_file", status: .running)))]
        let initial = try XCTUnwrap(projection.projectTurns(nodes: prefix, isLive: true).first?.blocks.first)
        let completed = [prefix[0], node("r", .tool(tool("read", "read_file"))),
                         node("t", .thinking(.init(text: "next", isStreaming: false))),
                         node("s", .tool(tool("search", "grep")), invocation: "inv2")]
        let final = try XCTUnwrap(projection.projectTurns(nodes: completed).first?.blocks.first)
        XCTAssertEqual(initial.id, final.id)
        var state = TranscriptDocumentState()
        state.toggleTool(callID: "group:\(initial.id)")
        XCTAssertTrue(state.expandedToolIDs.contains("group:\(final.id)"))
        let turns = projection.projectTurns(nodes: completed + [
            node("u2", .message(.init(role: .user, text: "another turn"))),
            node("r2", .tool(tool("read", "read_file")))])
        XCTAssertEqual(turns.count, 2)
        XCTAssertNotEqual(turns[0].blocks.first?.id, turns[1].blocks.first?.id)
    }

    func testPartialHistoryCannotGroupToolsAcrossServerTurnsWithoutPrompts() {
        let first = node("first", .tool(tool("call", "read_file")))
        let next = ExecutionNode(id: "next", kind: .tool(tool("call", "grep")),
                                 timestamp: 2, turnID: "different-turn", invocationID: "inv2")
        let turn = TimelineProjection().buildTurn(nodes: [first, next], isLive: false)
        XCTAssertEqual(turn.blocks.count, 2)
        XCTAssertNotEqual(turn.blocks.first?.id, turn.blocks.last?.id)
    }

    func testThinkingOnlyIsRetainedAndEntryCardsBreakActivity() {
        let projection = TimelineProjection()
        let thought = node("t", .thinking(.init(text: "reasoning", isStreaming: false)))
        let turn = projection.buildTurn(nodes: [thought], isLive: false)
        XCTAssertEqual(turn.blocks, [.thinking(id: "t", .init(text: "reasoning", isStreaming: false))])
        let child = ChildStreamNodePayload(kind: .task, childID: "child", title: "Delegate", status: .running,
                                           originCallID: "delegate")
        let mixed = projection.buildTurn(nodes: [
            node("r", .tool(tool("read", "read_file"))),
            node("delegate", .tool(tool("delegate", "task"))),
            node("child", .childStream(child)),
            node("s", .tool(tool("search", "grep")))], isLive: true)
        XCTAssertEqual(mixed.blocks.count, 3)
        guard case .toolGroup(let first) = mixed.blocks[0], case .childStream = mixed.blocks[1],
              case .toolGroup(let last) = mixed.blocks[2] else { return XCTFail("entry must stay separate") }
        XCTAssertEqual(first.tools.map(\.callID), ["read"])
        XCTAssertEqual(last.tools.map(\.callID), ["search"])
    }

    func testFailureAndRunningCountsAndUnknownCommandsAreFactual() {
        let group = ToolGroup(id: "a", entries: [
            .tool(tool("run", "run_command", status: .running)),
            .tool(tool("fail", "run_command", status: .failed)),
            .tool(tool("unknown", "custom_tool"))])
        XCTAssertEqual(group.summary, "运行命令、custom_tool · 3 次调用 · 1 运行中 · 1 失败")
        XCTAssertEqual(ToolTranscriptPresenter.groupPresentation(for: group).statusTone, .failed)
    }

    func testThinkingAfterCompletedToolStillExposesLiveActivity() {
        let group = ToolGroup(id: "a", entries: [.tool(tool("read", "read_file")),
            .thinking(id: "t", .init(text: "next", isStreaming: true))])
        XCTAssertTrue(group.isThinking)
        XCTAssertTrue(group.summary.contains("思考中"))
        XCTAssertEqual(ToolTranscriptPresenter.groupPresentation(for: group).statusTone, .running)
    }

    func testAutoApprovalCannotMaskRunningOrFailedExecution() throws {
        for status in [NodeStatus.running, .failed] {
            let payload = ToolExecPayload(callID: "auto", toolName: "run_command", args: nil,
                                          output: "error", isAutoApproved: true)
            let graphNode = GraphNode(id: "auto", kind: .toolCall, payload: .toolCall(payload),
                                      status: status, timestamp: 1, turnID: "turn")
            let projected = try XCTUnwrap(TimelineProjection().projectNode(graphNode))
            guard case .tool(let tool) = projected.kind else { return XCTFail("expected tool") }
            XCTAssertEqual(tool.status, status == .failed ? .failed : .running)
            XCTAssertEqual(ToolTranscriptPresenter.presentation(for: tool).statusTone,
                           status == .failed ? .failed : .running)
        }
    }

    func testNativeActivityRetainsThinkingAndToolOrderWithoutEagerOutput() {
        let group = ToolGroup(id: "a", entries: [.tool(tool("read", "read_file")),
            .thinking(id: "thought", .init(text: "reasoning in between", isStreaming: false)),
            .tool(tool("search", "grep"))])
        let turn = ConversationTurn(id: "turn", userPrompt: nil, blocks: [.toolGroup(group)], footer: nil, isLive: true)
        let collapsed = TurnTranscriptBuilder.build(turn: turn, state: .init())
        XCTAssertFalse(collapsed.attributedString.string.contains("reasoning in between"))
        XCTAssertFalse(collapsed.attributedString.string.contains("output:read"))
        let expanded = TurnTranscriptBuilder.build(turn: turn,
            state: TranscriptDocumentState(expandedToolIDs: ["group:a"], expandedThinkingIDs: ["thought"]))
        let text = expanded.attributedString.string
        let read = text.range(of: "Read")
        let thought = text.range(of: "reasoning in between")
        let search = text.range(of: "Search")
        XCTAssertNotNil(read)
        XCTAssertNotNil(thought)
        XCTAssertNotNil(search)
        if let read, let thought, let search {
            XCTAssertLessThan(read.lowerBound, thought.lowerBound)
            XCTAssertLessThan(thought.lowerBound, search.lowerBound)
        }
        XCTAssertFalse(text.contains("output:read"), "per-tool output remains collapsed")
    }

    func testIncrementalAndReplayProjectionConverge() {
        var graph = ExecutionGraph()
        var reducer = ExecutionReducer()
        var cache = TurnProjectionCache()
        let events: [AgentEvent] = [
            .turnStarted(turnID: "turn", text: "help"),
            .modelStarted(turnID: "turn", invocationID: "inv1"),
            .toolStarted(turnID: "turn", callID: "r", tool: .init(callID: "r", toolName: "read_file", toolArgs: nil)),
            .toolFinished(turnID: "turn", callID: "r", result: .init(callID: "r", toolName: "read_file", observation: "file", error: nil)),
            .modelStarted(turnID: "turn", invocationID: "inv2"),
            .thinking(turnID: "turn", text: "Search next"),
            .toolStarted(turnID: "turn", callID: "s", tool: .init(callID: "s", toolName: "grep", toolArgs: nil)),
            .toolFinished(turnID: "turn", callID: "s", result: .init(callID: "s", toolName: "grep", observation: "matches", error: nil)),
            .turnFinished(turnID: "turn", text: "Done", textAnnotations: [])]
        for event in events {
            _ = reducer.reduce(event, into: &graph)
            let incremental = cache.project(graph: &graph, isLive: true)
            let replay = TimelineProjection().projectTurns(graph, isLive: true)
            XCTAssertEqual(incremental.turns.map(\.blocks), replay.map(\.blocks))
        }
        let live = cache.project(graph: &graph, isLive: false)
        cache.reset() // reconnect / full reseed from the same persisted graph
        let replay = cache.project(graph: &graph, isLive: false)
        XCTAssertEqual(live.turns.map(\.blocks), replay.turns.map(\.blocks))
    }
}
