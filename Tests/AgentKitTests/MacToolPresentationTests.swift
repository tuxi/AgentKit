#if os(macOS)
import AppKit
import XCTest
@testable import AgentKit

final class MacToolPresentationTests: XCTestCase {
    func testCountsActualShellCallsAndReadsRatherThanParsedSubcommands() {
        let group = ToolGroup(id: "g", entries: [
            .tool(.init(callID: "a", toolName: "exec_command", args: .object(["cmd": .string("cat A.swift && cat B.swift")]), status: .completed)),
            .tool(.init(callID: "b", toolName: "read_file", args: .object(["path": .string("A.swift")]), status: .completed)),
            .tool(.init(callID: "c", toolName: "read_file", args: .object(["path": .string("A.swift")]), status: .completed)),
        ])
        XCTAssertEqual(MacToolPresentation.countSummary(group, text: .init(locale: "en")), "Ran a command · Read files 2 times")
    }

    func testSummarySeparatesPreviouslyRepeatedOtherBucketsAndPrioritizesCommands() {
        var tools: [ToolGroup.Entry] = []
        for (name, count) in [("list_files", 4), ("git_status", 6), ("exec_command", 67)] {
            for i in 0..<count {
                tools.append(.tool(.init(callID: "\(name)-\(i)", toolName: name, args: nil, status: .completed)))
            }
        }
        let group = ToolGroup(id: "mixed", entries: tools)
        XCTAssertEqual(MacToolPresentation.countSummary(group, text: .init(locale: "zh-Hans")),
                       "执行 67 条命令 · 浏览 4 次目录 · 执行 6 次 Git 操作")
        XCTAssertEqual(MacToolPresentation.expandedSummary(group, text: .init(locale: "en")),
                       MacToolPresentation.currentSummary(group, text: .init(locale: "en")))
    }

    func testUnknownToolsStayUnknownAndOnlyProduceOneFallback() {
        let entries = ["mcp__read_private_state", "web.custom_read", "unknown_read", "client_run"].map {
            ToolGroup.Entry.tool(.init(callID: $0, toolName: $0, args: nil, status: .completed))
        }
        XCTAssertEqual(MacToolPresentation.countSummary(.init(id: "unknown", entries: entries), text: .init(locale: "zh-Hans")), "调用 4 次工具")
        let mixed = ToolGroup(id: "mixed", entries: entries + [.tool(.init(callID: "cmd", toolName: "run_command", args: nil, status: .completed))])
        XCTAssertEqual(MacToolPresentation.countSummary(mixed, text: .init(locale: "zh-Hans")), "执行 1 条命令 · 另有 4 次工具调用")
    }

    func testLiveCollapsedActionChangesWhileExpandedSummaryRemainsAggregate() {
        let command = ToolNodePayload(callID: "cmd", toolName: "exec_command", args: .object([
            "cmd": .string("swift test"), "description": .string("验证工具组")]), status: .running)
        let read = ToolNodePayload(callID: "read", toolName: "read_file", args: .object(["path": .string("Sources/App.swift")]), status: .completed)
        let live = ToolGroup(id: "g", entries: [.tool(command), .tool(read)], isCollecting: true)
        let text = ToolTranscriptText(locale: "zh-Hans")
        XCTAssertTrue(MacToolPresentation.currentSummary(live, text: text).contains("验证工具组"))
        XCTAssertEqual(MacToolPresentation.expandedSummary(live, text: text), "执行 1 条命令 · 读取 App.swift")
        let next = ToolGroup(id: "g", entries: [
            .tool(.init(callID: "cmd", toolName: "exec_command", args: command.args, status: .completed)),
            .tool(.init(callID: "read", toolName: "read_file", args: read.args, status: .running))], isCollecting: true)
        XCTAssertTrue(MacToolPresentation.currentSummary(next, text: text).contains("App.swift"))
        XCTAssertFalse(MacToolPresentation.currentSummary(next, text: text).contains("验证工具组"))
        XCTAssertEqual(MacToolPresentation.expandedSummary(next, text: text), MacToolPresentation.expandedSummary(live, text: text))
    }

    func testSummaryIsBoundedToThreePartsAndCountsAllRemainingCallsOnce() {
        let names = ["load_skill", "list_files", "git_status", "read_file", "run_command", "unknown"]
        let group = ToolGroup(id: "g", entries: names.map { .tool(.init(callID: $0, toolName: $0, args: nil, status: .completed)) })
        XCTAssertEqual(MacToolPresentation.countSummary(group, text: .init(locale: "zh-Hans")), "执行 1 条命令 · 读取 1 次文件 · 另有 4 次工具调用")
    }

    func testBackgroundWaitsAreNotCountedAsCommandsAndKnownAuxiliaryToolsHaveNames() {
        let entries = ["exec_command", "job_wait", "job_wait", "job_logs"].enumerated().map { i, name in
            ToolGroup.Entry.tool(.init(callID: "c\(i)", toolName: name, args: nil, status: .completed))
        }
        XCTAssertEqual(MacToolPresentation.countSummary(.init(id: "g", entries: entries), text: .init(locale: "zh-Hans")),
                       "执行 1 条命令 · 管理后台任务 3 次")
        for (name, expected) in [("task", "委派 1 次任务"), ("insert_file", "修改 1 次文件"), ("recall_memory", "操作记忆 1 次")] {
            let group = ToolGroup(id: "g", entries: [.tool(.init(callID: "c", toolName: name, args: nil, status: .completed))])
            XCTAssertEqual(MacToolPresentation.countSummary(group, text: .init(locale: "zh-Hans")), expected)
        }
    }

    func testCommandRowUsesDescriptionOrCompactNameWithoutRepeatingTheInput() {
        let text = ToolTranscriptText(locale: "en")
        func title(_ command: String, description: String? = nil) -> String {
            var args: [String: JSONValue] = ["command": .string(command)]
            if let description { args["description"] = .string(description) }
            return MacToolPresentation.rowTitle(.init(callID: "c", toolName: "run_command", args: .object(args), status: .completed), text: text)
        }
        XCTAssertEqual(title("git -C /Users/example/AgentKit diff --stat"), "Run git diff")
        XCTAssertEqual(title("git -C /Users/example/AgentKit status --short; echo ---; git log --oneline -5"), "Run git")
        XCTAssertEqual(title("swift test --filter LongTestName"), "Run swift test")
        XCTAssertEqual(title("cat A.swift", description: "  Inspected\n  build log\t tail  "), "Inspected build log tail")
        XCTAssertEqual(title("rg 'ToolGroup' Sources", description: "Inspect tool grouping"), "Inspect tool grouping")
        XCTAssertEqual(title("curl --header 'Authorization: Bearer secret' https://example.test"), text.text("run"))
        XCTAssertEqual(title("$(unknown) --flag"), text.text("run"))
        let long = title("printf text", description: String(repeating: "说明", count: 150))
        XCTAssertLessThanOrEqual(long.count, 120)
    }

    func testNativeDesktopToolRowTruncatesInsteadOfWrapping() throws {
        let tool = ToolNodePayload(callID: "cmd", toolName: "exec_command", args: .object([
            "cmd": .string("git diff"), "description": .string(String(repeating: "很长的动作说明 ", count: 40))]), status: .completed)
        let turn = ConversationTurn(id: "t", userPrompt: nil, blocks: [.toolGroup(.init(id: "g", entries: [.tool(tool)]))], footer: nil, isLive: false)
        let document = TurnTranscriptBuilder.build(turn: turn, state: .init(expandedToolIDs: ["group:g"]))
        let label = MacToolPresentation.rowTitle(tool)
        let range = (document.attributedString.string as NSString).range(of: label)
        XCTAssertNotEqual(range.location, NSNotFound)
        let style = try XCTUnwrap(document.attributedString.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.lineBreakMode, .byTruncatingTail)
    }

    @MainActor
    func testBackgroundJobsJoinActivityAtLaunchPositionAndKeepStableGroupIdentity() throws {
        func node(_ id: String, _ kind: ExecutionNodeKind) -> ExecutionNode {
            .init(id: id, kind: kind, timestamp: 1, turnID: "turn")
        }
        let launch = node("launcher", .tool(.init(callID: "call", toolName: "run_command", args: .object(["command": .string("swift test")]), status: .running)))
        let job = ChildStreamNodePayload(kind: .job, childID: "j1", title: "swift test", status: .failed,
                                        originCallID: "call", result: "PRIVATE RESULT", exitCode: 1, output: "PRIVATE OUTPUT")
        let before = TimelineProjection().buildTurn(nodes: [launch], isLive: true)
        let nodes = [launch,
            node("thought", .thinking(.init(text: "Inspect results", isStreaming: false))),
            node("bracket", .childStream(job)),
            node("wait", .tool(.init(callID: "wait", toolName: "job_wait", args: .object(["job_id": .string("j1")]), status: .completed))),
            node("read", .tool(.init(callID: "read", toolName: "read_file", args: .object(["path": .string("App.swift")]), status: .completed)))]
        let turn = TimelineProjection().buildTurn(nodes: nodes, isLive: false)
        XCTAssertEqual(turn.blocks.count, 1, "job brackets must not split activity")
        guard case .toolGroup(let group) = try XCTUnwrap(turn.blocks.first) else { return XCTFail("missing activity") }
        XCTAssertEqual(group.id, before.blocks.first?.id, "launcher replacement preserves disclosure identity")
        XCTAssertEqual(group.entries.map(\.id), ["job:j1", "thinking:thought", "tool:wait", "tool:read"])
        XCTAssertEqual(group.tools.map(\.callID), ["wait", "read"], "launcher and job are one visible operation")
        XCTAssertEqual(group.backgroundJobs, [job])
        XCTAssertEqual(MacToolPresentation.failureCount(group), 1)
        XCTAssertEqual(MacToolPresentation.countSummary(group, text: .init(locale: "zh-Hans")), "执行 1 条命令 · 读取 App.swift · 管理后台任务 1 次")
        let registry = ConversationWebActionRegistry()
        registry.beginRevision()
        let document = ConversationWebDocumentBuilder.build(snapshot: .init(timeline: nodes, turns: [turn]), conversationID: "c", registerAction: registry.register)
        registry.finishRevision()
        let block = try XCTUnwrap(document.turns.first?.blocks.first)
        let webJob = try XCTUnwrap(block.activityJobs?.first)
        XCTAssertEqual(block.failureText, ToolTranscriptText().text("desktop.failures", 1))
        XCTAssertEqual(block.status, "failed")
        XCTAssertEqual(webJob.statusText, ToolTranscriptText().text("failed"))
        guard case .transcript(let turnID, let action)? = registry.resolve(try XCTUnwrap(webJob.actionID)),
              case .openChildStream(let id) = action else { return XCTFail("job detail action missing") }
        XCTAssertEqual(turnID, turn.id)
        XCTAssertEqual(id, "j1")
        let token = try XCTUnwrap(webJob.actionID)
        XCTAssertTrue(ConversationWebDocumentBuilder.actionTokens(in: document).contains(token))
        registry.beginRevision(1)
        registry.finishRevision(retaining: ConversationWebDocumentBuilder.actionTokens(in: document))
        registry.retainRevisions([1])
        XCTAssertNotNil(registry.resolve(token), "unchanged groups retain the Inspector action after revision reuse")
        XCTAssertNil(webJob.text, "job output and result stay in the existing Inspector")
        let native = TurnTranscriptBuilder.build(turn: turn, state: .init(expandedToolIDs: ["group:" + group.id]))
        XCTAssertTrue(native.actions.values.contains(.openChildStream(childID: "j1")))
        XCTAssertFalse(native.attributedString.string.contains("PRIVATE OUTPUT"))
        XCTAssertFalse(native.attributedString.string.contains("PRIVATE RESULT"))
    }

    func testBackgroundJobsRespectNarrationBoundariesAndKeepIndependentStatus() throws {
        func node(_ id: String, _ kind: ExecutionNodeKind) -> ExecutionNode {
            .init(id: id, kind: kind, timestamp: 1, turnID: "turn")
        }
        let running = ChildStreamNodePayload(kind: .job, childID: "running", title: "swift test", status: .running)
        let canceled = ChildStreamNodePayload(kind: .job, childID: "canceled", title: "npm test", status: .canceled, exitCode: 137)
        let nodes = [node("job", .childStream(running)), node("canceled", .childStream(canceled)),
                     node("text", .message(.init(role: .assistant, text: "While it runs, inspect files."))),
                     node("read", .tool(.init(callID: "r", toolName: "read_file", args: nil, status: .completed)))]
        let turn = TimelineProjection().buildTurn(nodes: nodes, isLive: false)
        XCTAssertEqual(turn.blocks.count, 3, "actual narration remains visible between groups")
        guard case .toolGroup(let group) = turn.blocks[0] else { return XCTFail("job-only activity missing") }
        XCTAssertTrue(MacToolPresentation.isRunning(group), "a job can outlive the model turn")
        XCTAssertEqual(MacToolPresentation.failureCount(group), 0, "cancellation is not failure")
        XCTAssertTrue(MacToolPresentation.currentSummary(group, text: .init(locale: "en")).contains("swift test"))
        XCTAssertEqual(MacToolPresentation.countSummary(group, text: .init(locale: "zh-Hans")), "执行 2 条命令")
        XCTAssertEqual(MacToolPresentation.backgroundJobStatus(canceled, text: .init(locale: "zh-Hans")), "已取消")
        XCTAssertNil(group.startedAt, "history without real timing must not invent a clock")
    }

    func testPreEditCheckJoinsToolsAndRetainsItsContentInNativeDisclosure() throws {
        func node(_ id: String, _ kind: ExecutionNodeKind) -> ExecutionNode { .init(id: id, kind: kind, timestamp: 1, turnID: "t") }
        let check = node("check", .system(.init(kind: .preMutation, text: "Verify the edit preserves public interfaces.")))
        let edit = node("edit", .tool(.init(callID: "edit", toolName: "edit_file", args: nil, status: .completed)))
        let projection = TimelineProjection()
        let before = projection.buildTurn(nodes: [check], isLive: true)
        let turn = projection.buildTurn(nodes: [check, edit], isLive: false)
        XCTAssertEqual(turn.blocks.count, 1)
        guard case .toolGroup(let group) = turn.blocks[0] else { return XCTFail("missing activity") }
        XCTAssertEqual(group.id, before.blocks.first?.id)
        XCTAssertEqual(group.entries.map(\.id), ["preMutation:check", "tool:edit"])
        XCTAssertEqual(group.tools.count, 1, "self-check is not a synthetic command")
        XCTAssertEqual(MacToolPresentation.countSummary(group, text: .init(locale: "zh-Hans")), "修改 1 次文件 · 编辑前自检 1 次")
        let closed = TurnTranscriptBuilder.build(turn: turn, state: .init(expandedToolIDs: ["group:" + group.id]))
        XCTAssertTrue(closed.attributedString.string.contains(ToolTranscriptText().text("desktop.preMutation")))
        XCTAssertFalse(closed.attributedString.string.contains("Verify the edit"))
        let open = TurnTranscriptBuilder.build(turn: turn, state: .init(expandedToolIDs: ["group:" + group.id], expandedThinkingIDs: ["check"]))
        XCTAssertTrue(open.attributedString.string.contains("Verify the edit preserves public interfaces."))
        XCTAssertTrue(open.actions.values.contains(.toggleThinking(id: "check")))
        let bounded = projection.buildTurn(nodes: [check, node("body", .message(.init(role: .assistant, text: "Proceed with the edit."))), edit], isLive: false)
        XCTAssertEqual(bounded.blocks.count, 3, "visible narration still separates activity")
    }

    func testFailureDoesNotHideOtherRunningToolsOrThinkingBetweenCalls() {
        let failed = ToolNodePayload(callID: "bad", toolName: "exec_command", args: nil, status: .completed, exitCode: 1)
        let active = ToolNodePayload(callID: "run", toolName: "exec_command", args: nil, status: .running)
        let group = ToolGroup(id: "g", entries: [.tool(failed), .tool(active)])
        XCTAssertTrue(MacToolPresentation.isFailed(failed))
        XCTAssertTrue(MacToolPresentation.isRunning(group))
        XCTAssertFalse(MacToolPresentation.currentSummary(group, text: .init(locale: "en")).isEmpty)
        let collecting = ToolGroup(id: "g", entries: [.tool(failed)], isCollecting: true)
        XCTAssertEqual(MacToolPresentation.currentSummary(collecting, text: .init(locale: "en")), ToolTranscriptText(locale: "en").text("active.processing"))
    }

    func testLiveTimingUsesWallClockIntervalAndHistoryRemainsUnknown() throws {
        let start = Date(timeIntervalSince1970: 100)
        let end = Date(timeIntervalSince1970: 110)
        func node(_ id: String, at date: Date) -> ExecutionNode {
            .init(id: id, kind: .tool(.init(callID: id, toolName: "exec_command", args: nil, status: .completed, elapsedMs: 10_000)), timestamp: 999,
                  turnID: "t", firstObservedAt: start, lastObservedAt: date)
        }
        let turn = TimelineProjection().buildTurn(nodes: [node("a", at: end), node("b", at: end)], isLive: false,
                                                  wallClock: .init(startedAt: start, finishedAt: end))
        guard case .toolGroup(let group) = try XCTUnwrap(turn.blocks.first) else { return XCTFail("missing group") }
        XCTAssertEqual(group.startedAt, start)
        XCTAssertEqual(group.finishedAt, end)
        XCTAssertEqual(group.finishedAt!.timeIntervalSince(group.startedAt!), 10, "parallel calls are not added together")
        let historical = ExecutionNode(id: "old", kind: .tool(.init(callID: "old", toolName: "exec_command", args: nil, status: .completed, elapsedMs: 10_000)), timestamp: 999, turnID: "old")
        guard case .toolGroup(let replayed) = TimelineProjection().buildTurn(nodes: [historical], isLive: false).blocks.first else { return XCTFail("missing history group") }
        XCTAssertNil(replayed.startedAt)
        XCTAssertNil(replayed.finishedAt)
    }

    func testExpandedNativeGroupIsUserControlledAndOutputHasIndependentSlot() throws {
        let output = (0..<100).map { "output line \($0)" }.joined(separator: "\n")
        let tool = ToolNodePayload(callID: "cmd", toolName: "exec_command", args: .object(["cmd": .string("swift test")]), status: .running, output: output)
        let group = ToolGroup(id: "g", entries: [.tool(tool)], isCollecting: true)
        let turn = ConversationTurn(id: "t", userPrompt: nil, blocks: [.toolGroup(group)], footer: nil, isLive: true)
        let collapsed = TurnTranscriptBuilder.build(turn: turn, state: .init())
        XCTAssertTrue(collapsed.attributedString.string.contains("swift test"), "collapsed live header identifies the current command")
        XCTAssertFalse(collapsed.attributedString.string.contains("output line 0"))
        var state = TranscriptDocumentState()
        state.toggleTool(callID: "group:g")
        state.toggleTool(callID: "cmd")
        let expanded = TurnTranscriptBuilder.build(turn: turn, state: state)
        XCTAssertTrue(expanded.attributedString.string.contains("swift test"))
        var outputs: [NativeToolOutputValue] = []
        expanded.attributedString.enumerateAttribute(.desktopToolOutput, in: NSRange(location: 0, length: expanded.attributedString.length)) { value, _, _ in
            if let value = value as? NativeToolOutputValue { outputs.append(value) }
        }
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs.first?.output, output)
        XCTAssertEqual(outputs.first?.height, 280)
        XCTAssertTrue(expanded.actions.values.contains(.openToolResult(callID: "cmd")))
    }

    func testSemanticInputDoesNotRequireOpeningRawJSON() {
        let read = ToolNodePayload(callID: "r", toolName: "read_file", args: .object(["path": .string("Sources/A.swift")]), status: .completed)
        XCTAssertEqual(MacToolPresentation.input(for: read), "Sources/A.swift")
        let search = ToolNodePayload(callID: "s", toolName: "grep", args: .object(["pattern": .string("ToolGroup"), "path": .string("Sources")]), status: .completed)
        XCTAssertEqual(MacToolPresentation.input(for: search), "ToolGroup\nSources")
    }

    func testWebWaitLabelKeepsItsCountPlaceholder() {
        for locale in ["en", "zh-Hans"] {
            XCTAssertTrue(MacToolPresentation.labels(text: .init(locale: locale))["waitingChecks"]?.contains("{count}") == true)
        }
    }

    func testExpandedLongCommandsAreNotTruncatedAndLateSensitiveArgumentsAreDetected() {
        let command = String(repeating: "printf 'build output'\n", count: 500)
        XCTAssertGreaterThan(command.utf8.count, 8192)
        XCTAssertFalse(MacToolPresentation.shouldRedactCommand(command))
        XCTAssertTrue(MacToolPresentation.shouldRedactCommand(command + "curl --header 'Authorization: Bearer example'"))
    }

    func testFullOutputIdentityDoesNotResolveToAnOlderReusedCallID() {
        let tool = ToolNodePayload(callID: "reused", toolName: "exec_command", args: nil, status: .completed)
        let timeline: [ExecutionNode] = [
            .init(id: "user-1", kind: .message(.init(role: .user, text: "first")), timestamp: 1, turnID: "1"),
            .init(id: "reused", kind: .tool(tool), timestamp: 2, turnID: "1"),
            .init(id: "user-2", kind: .message(.init(role: .user, text: "second")), timestamp: 3, turnID: "2"),
            .init(id: "reused_v2", kind: .tool(tool), timestamp: 4, turnID: "2"),
        ]
        let turn = ConversationTurn(id: "user-2", userPrompt: nil, blocks: [.toolGroup(.init(id: "g", entries: [.tool(tool)]))], footer: nil, isLive: false)
        XCTAssertEqual(MacToolPresentation.inspectorNodeID(callID: "reused", turn: turn, timeline: timeline), "reused_v2")
    }

    @MainActor
    func testNativeOutputScrollViewOccupiesBoundedSlotAndKeepsCommandOutside() {
        let tool = ToolNodePayload(callID: "cmd", toolName: "exec_command", args: .object(["cmd": .string("swift test")]), status: .running,
            output: (0..<80).map { "Test output \($0)" }.joined(separator: "\n"))
        let turn = ConversationTurn(id: "native", userPrompt: nil, blocks: [.toolGroup(.init(id: "g", entries: [.tool(tool)]))], footer: nil, isLive: true)
        let transcript = TurnTranscriptBuilder.build(turn: turn, state: .init(expandedToolIDs: ["group:g", "cmd"]))
        let view = NativeTranscriptTextView(onAction: { _ in })
        view.apply(attributedText: transcript.attributedString, actions: transcript.actions, onAction: { _ in })
        let size = view.sizeThatFits(width: 700) ?? .zero
        view.frame = NSRect(origin: .zero, size: size)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        let outputViews = view.subviews.compactMap { $0 as? NativeToolOutputScrollView }
        XCTAssertEqual(outputViews.count, 1)
        XCTAssertEqual(outputViews.first?.frame.height, 280)
        XCTAssertGreaterThan(outputViews.first?.documentView?.frame.height ?? 0, 280)
        XCTAssertFalse((outputViews.first?.documentView as? NSTextView)?.string.contains("swift test") ?? true)
    }

    @MainActor
    func testNativeLongInputAndOutputUseSeparateScrollersWithoutRawDetailsOrThinkingIcon() {
        let command = (1...20).map { "printf 'line \($0)'" }.joined(separator: "\n")
        let output = (1...60).map { "result \($0)" }.joined(separator: "\n")
        let tool = ToolNodePayload(callID: "cmd", toolName: "exec_command", args: .object(["cmd": .string(command)]), status: .completed, output: output)
        let group = ToolGroup(id: "g", entries: [.thinking(id: "thought", .init(text: "Inspecting", isStreaming: false)), .tool(tool)])
        let turn = ConversationTurn(id: "native", userPrompt: nil, blocks: [.toolGroup(group)], footer: nil, isLive: false)
        let transcript = TurnTranscriptBuilder.build(turn: turn, state: .init(expandedToolIDs: ["group:g", "cmd"]))
        XCTAssertFalse(transcript.attributedString.string.contains("◉"))
        XCTAssertFalse(transcript.attributedString.string.contains(ToolTranscriptText().text("raw.details")))
        var slots: [NativeToolOutputValue] = []
        transcript.attributedString.enumerateAttribute(.desktopToolOutput, in: NSRange(location: 0, length: transcript.attributedString.length)) { value, _, _ in
            if let value = value as? NativeToolOutputValue { slots.append(value) }
        }
        XCTAssertEqual(slots.first(where: \.isInput)?.output, command)
        XCTAssertEqual(slots.first(where: \.isInput)?.height, 160)
        XCTAssertEqual(slots.first(where: { !$0.isInput })?.output, output)
        XCTAssertEqual(slots.first(where: { !$0.isInput })?.height, 280)
        let view = NativeTranscriptTextView(onAction: { _ in })
        view.apply(attributedText: transcript.attributedString, actions: transcript.actions, onAction: { _ in })
        view.frame = NSRect(origin: .zero, size: view.sizeThatFits(width: 700) ?? .zero)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.subviews.compactMap { $0 as? NativeToolOutputScrollView }.count, 2)
    }
}
#endif
