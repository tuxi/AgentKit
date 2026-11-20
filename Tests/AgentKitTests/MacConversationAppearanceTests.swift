#if os(macOS)
import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import AgentKit

@MainActor @Observable
private final class AppearanceRenderModel {
    var snapshot: RuntimeSnapshot = .empty(sessionID: "appearance")
    var submissions: [LocalMessageSubmission] = []
}

@MainActor
private struct AppearanceRenderHost: View {
    let model: AppearanceRenderModel
    let store: WorkspaceStore
    var body: some View {
        ConversationWebWorkbenchView(snapshot: model.snapshot, localSubmissions: model.submissions,
            submissionKey: .session("appearance"), conversationID: "appearance", workspaceRoot: nil,
            previewViewerResolver: nil, previewAssetResolver: nil,
            extensionContributions: [:], timelineExtensions: [], isVisible: true, bottomInset: 0,
            onFatalFailure: { XCTFail("Workbench failed") })
        .environment(store)
    }
}

@MainActor
final class MacConversationAppearanceTests: XCTestCase {
    private var window: NSWindow?
    private let executionStart = Date().addingTimeInterval(-24)

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        try await super.tearDown()
    }

    private func fixture(reply: String = "验证已通过，消息、工具摘要与回复使用同一条内容对齐线。", generation: UInt64 = 1) -> RuntimeSnapshot {
        let tool = ToolNodePayload(callID: "read-file", toolName: "read_file",
            args: .object(["path": .string("Sources/ConversationDetailView.swift")]),
            status: .completed, output: "读取完成")
        let turn = ConversationTurn(id: "appearance-turn",
            userPrompt: .init(role: .user, text: "帮我检查对话详情的显示，让文字更清晰，间距更舒服。"),
            blocks: [
                .text(id: "intro", .init(role: .assistant, text: "我会先检查现有布局，再验证长消息与主题切换。\n\n## 检查结果\n\n- 正文保持清晰的对比度。\n- 工具信息使用次级颜色，减少视觉干扰。")),
                .toolGroup(.init(id: "read-group", tools: [tool])),
                .text(id: "answer", .init(role: .assistant, text: "\(reply)\n\n```swift\nlet contentWidth = min(availableWidth, 728)\n```\n\n长路径也能自然换行：`/Users/example/Documents/work/" + String(repeating: "LongDirectoryName/", count: 8) + "ConversationDetailView.swift`。"))
            ], footer: .init(contextTokens: 12400, totalTokens: 18900, elapsedMs: 12000, invocationCount: 1),
            isLive: false, startedAt: Date(timeIntervalSince1970: 1794899400), finishedAt: Date(timeIntervalSince1970: 1794899412))
        return .init(timeline: [], turns: [turn], generation: generation)
    }

    private func wait(_ script: String, in web: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if (try? await web.evaluateJavaScript(script)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(60))
        }
        XCTFail("Timed out: \(script)")
        throw NSError(domain: "ConversationAppearance", code: 1)
    }

    private func present(_ model: AppearanceRenderModel) async throws -> WKWebView {
        let host = NSHostingView(rootView: AppearanceRenderHost(model: model, store: WorkspaceStore(usesEmbeddedRuntime: false)))
        host.frame = NSRect(x: 0, y: 0, width: 980, height: 960)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.contentView = host
        window.orderFront(nil)
        self.window = window
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap(find).first
        }
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if let web = find(host) {
                window.makeFirstResponder(web)
                try await wait("document.querySelector('.user-message-actions button') !== null", in: web)
                return web
            }
            try await Task.sleep(for: .milliseconds(60))
        }
        throw NSError(domain: "ConversationAppearance", code: 2)
    }

    private func screenshot(_ name: String, web: WKWebView) async throws {
        guard let path = ProcessInfo.processInfo.environment["CONVERSATION_APPEARANCE_SCREENSHOTS"] else { return }
        _ = try await web.evaluateJavaScript("window.scrollTo(0, 0); document.activeElement?.blur()")
        let image = try await web.takeSnapshot(configuration: nil)
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            return XCTFail("Snapshot failed")
        }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: path).appendingPathComponent(name + ".png"))
    }

    func testLocalSubmissionIsVisibleBeforeAcceptanceAndAdoptsRuntimeTurnWithoutDuplicatingDOM() async throws {
        let model = AppearanceRenderModel()
        model.snapshot = .init(timeline: [], turns: [ConversationTurn(id: "older", userPrompt: .init(role: .user, text: "之前的消息"),
            blocks: [.text(id: "answer", .init(role: .assistant, text: "上一轮已经完成。"))], footer: nil, isLive: false)], generation: 1)
        var record = LocalMessageSubmission(id: "request", resourceID: "request", text: "立即显示的新消息",
            displayText: "立即显示的新消息", fileReferences: [], model: nil, reasoningEffort: nil)
        model.submissions = [record]
        let web = try await present(model)
        try await wait("document.querySelector('.submission-delivery')?.textContent.includes('发送中') === true", in: web)
        _ = try await web.evaluateJavaScript("window.pendingMessage = document.querySelector('[data-turn-id=\"submission:request\"]'); true")
        try await screenshot("submission-sending", web: web)
        record.phase = .failed; record.failure = "发送失败，请重试"
        model.submissions = [record]
        try await wait("document.querySelector('.submission-delivery button') !== null", in: web)
        try await screenshot("submission-failed", web: web)
        record.phase = .accepted; record.failure = nil; record.turnID = "real"
        model.submissions = [record]
        try await wait("document.querySelector('.submission-delivery')?.textContent.includes('已接收') === true", in: web)
        try await screenshot("submission-accepted", web: web)
        let realTurn = ConversationTurn(id: "turn_real_user", userPrompt: .init(role: .user, text: record.text),
            blocks: [], footer: nil, isLive: true)
        model.snapshot = .init(timeline: [], turns: model.snapshot.turns + [realTurn], generation: 2)
        try await wait("document.querySelector('[data-turn-id=\"turn_real_user\"]') !== null && !document.querySelector('.submission-delivery')", in: web)
        try await assertJavaScript("document.querySelectorAll('.user-prompt').length", equals: 2, in: web)
        try await assertJavaScript("window.pendingMessage === document.querySelector('[data-turn-id=\"turn_real_user\"]')", equals: true, in: web)
        try await screenshot("submission-started", web: web)
    }

    func testReadingLayoutThemeFocusAndIncrementalDOMRemainStable() async throws {
        let model = AppearanceRenderModel()
        model.snapshot = fixture()
        let web = try await present(model)
        try await wait("getComputedStyle(document.documentElement).backgroundColor === 'rgb(255, 255, 255)'", in: web)
        let overflow = try await web.evaluateJavaScript("document.documentElement.scrollWidth > innerWidth") as? Bool
        XCTAssertEqual(overflow, false, "Long paths must wrap inside the content column")
        let width = try await web.evaluateJavaScript("document.querySelector('.assistant-lane').getBoundingClientRect().width") as? Double
        XCTAssertEqual(try XCTUnwrap(width), 728, accuracy: 1)
        let stableFocus = try await web.evaluateJavaScript("""
        (() => {
          const row = document.querySelector('.user-message-actions');
          const answer = document.querySelector('[data-block-id="answer"]');
          const before = answer.getBoundingClientRect().top;
          row.querySelector('button').focus({preventScroll:true});
          return { opacity: getComputedStyle(row).opacity, focused: document.activeElement === row.querySelector('button'), before, after: answer.getBoundingClientRect().top, within: row.matches(':focus-within'), hasFocus: document.hasFocus() };
        })()
        """) as? [String: Any]
        // SwiftPM's offscreen WK host can move DOM focus without owning the
        // WindowServer keyboard focus. Only assert the visual pseudo-class
        // when that input focus is available; DOM focus and geometry are always
        // verified below. Actual Tab/hover appearance also needs app acceptance.
        if stableFocus?["hasFocus"] as? Bool == true {
            XCTAssertEqual(stableFocus?["opacity"] as? String, "1")
        }
        XCTAssertEqual(stableFocus?["focused"] as? Bool, true)
        XCTAssertEqual(stableFocus?["before"] as? Double, stableFocus?["after"] as? Double, "Actions must not move the reply")
        try await screenshot("conversation-light", web: web)
        _ = try await web.evaluateJavaScript("window.__appearanceIntro = document.querySelector('[data-block-id=\"intro\"]'); true")
        model.snapshot = fixture(reply: "增量更新后的回复。", generation: 2)
        try await wait("document.body.innerText.includes('增量更新后的回复。')", in: web)
        let reused = try await web.evaluateJavaScript("window.__appearanceIntro === document.querySelector('[data-block-id=\"intro\"]')") as? Bool
        XCTAssertEqual(reused, true, "Updating one block must retain unrelated history DOM")
        window?.appearance = NSAppearance(named: .darkAqua)
        try await wait("getComputedStyle(document.documentElement).backgroundColor === 'rgb(31, 32, 35)' && getComputedStyle(document.documentElement).color === 'rgb(232, 233, 237)'", in: web)
        try await screenshot("conversation-dark", web: web)
        window?.setContentSize(NSSize(width: 520, height: 960))
        try await wait("innerWidth <= 520", in: web)
        let narrowOverflow = try await web.evaluateJavaScript("document.documentElement.scrollWidth > innerWidth") as? Bool
        XCTAssertEqual(narrowOverflow, false)
        try await screenshot("conversation-narrow", web: web)
    }

    func testUserCopyActionSurvivesReusedTurnRevision() throws {
        let registry = ConversationWebActionRegistry()
        let snapshot = fixture()
        registry.beginRevision(1)
        let document = ConversationWebDocumentBuilder.build(snapshot: snapshot, conversationID: "appearance", revision: 1,
            registerAction: { registry.register($0) })
        registry.finishRevision(retaining: ConversationWebDocumentBuilder.actionTokens(in: document))
        let token = try XCTUnwrap(document.turns[0].userCopyActionID)
        XCTAssertEqual(registry.resolve(token, revision: 1), .transcript(turnID: "appearance-turn", action: .copyBlock(text: snapshot.turns[0].userPrompt!.text)))
        registry.beginRevision(2)
        registry.finishRevision(retaining: ConversationWebDocumentBuilder.actionTokens(in: document))
        XCTAssertNotNil(registry.resolve(token, revision: 2), "The copy action must survive stable turn reuse")
    }

    private func executionFixture(live: Bool = true, allComplete: Bool = false,
                                  approval: Bool = false, failedPlanUpdate: Bool = false,
                                  generation: UInt64 = 1) -> RuntimeSnapshot {
        let todos: [TodoItem] = [
            .init(content: "检查布局", status: .completed),
            .init(content: "验证构建", activeForm: "正在验证构建", status: allComplete ? .completed : .inProgress)
        ]
        var blocks: [TurnBlock] = [.text(id: "execution-text", .init(role: .assistant,
            text: live ? "正在检查页面显示。版本 \(generation)" : "本轮检查已结束。版本 \(generation)"))]
        if failedPlanUpdate {
            blocks.append(.toolGroup(.init(id: "plan-update", tools: [
                .init(callID: "failed-plan", toolName: "TodoWrite",
                      args: .object(["items": .array([.object(["content": .string("验证构建"), "status": .string("completed")])])]),
                      status: .failed, output: "missing scope", exitCode: 1)
            ])))
        }
        let start = executionStart
        let turn = ConversationTurn(id: "execution-turn", userPrompt: .init(role: .user, text: "检查对话详情的显示"),
            blocks: blocks, todos: todos, footer: nil, isLive: live,
            startedAt: start, finishedAt: live ? nil : start.addingTimeInterval(48))
        let requests: [ApprovalRequest] = approval ? [.init(id: "build-approval", toolName: "exec_command",
            toolArgs: .object(["cmd": .string("swift build")]), deadlineMs: nil, sessionId: "appearance", turnId: turn.id)] : []
        return .init(timeline: [], turns: [turn], pendingApprovals: requests, isLive: live,
                     generation: generation, turnStartedAt: live ? start : nil)
    }

    func testConnectedStreamDoesNotKeepCompletedTurnProcessing() async throws {
        let model = AppearanceRenderModel()
        model.snapshot = executionFixture()
        let web = try await present(model)
        try await wait("document.querySelector('.live-indicator')?.textContent.includes('正在处理') === true", in: web)

        // The session stream remains connected after the turn terminates.
        let completed = executionFixture(live: false, generation: 2)
        model.snapshot = .init(timeline: [], turns: completed.turns, isLive: true, generation: 2)
        try await wait("document.body.innerText.includes('版本 2') && !document.querySelector('.live-indicator')", in: web)
        XCTAssertNil(ConversationWebDocumentBuilder.build(snapshot: model.snapshot,
            conversationID: "connected-idle", revision: 2).live)
        XCTAssertNil(ConversationWebDocumentBuilder.build(snapshot: .init(timeline: [], isLive: true),
            conversationID: "connected-empty", revision: 1).live)

        model.snapshot = executionFixture(generation: 3)
        try await wait("document.body.innerText.includes('版本 3') && document.querySelector('.live-indicator') !== null", in: web)
    }

    func testTasksAndWaitingFollowFactsThroughCompletion() async throws {
        let model = AppearanceRenderModel()
        model.snapshot = executionFixture()
        let web = try await present(model)
        try await wait("document.querySelector('.todo-panel')?.open === true", in: web)
        try await wait("document.querySelector('.turn-live-header') !== null", in: web)
        try await assertJavaScript("document.querySelectorAll('.live-indicator').length", equals: 1, in: web)
        try await screenshot("execution-running", web: web)
        _ = try await web.evaluateJavaScript("document.querySelector('.todo-panel-summary').click()")
        try await wait("document.querySelector('.todo-panel')?.open === false", in: web)
        model.snapshot = executionFixture(generation: 2)
        try await wait("document.body.innerText.includes('版本 2')", in: web)
        try await assertJavaScript("document.querySelector('.todo-panel').open", equals: false, in: web)

        // Waiting changes only snapshot control state, not the turn's content.
        // Runtime snapshots increment generation even if only control state changes.
        model.snapshot = .init(timeline: [], turns: model.snapshot.turns,
            pendingApprovals: executionFixture(approval: true).pendingApprovals,
            isLive: true, generation: 3, turnStartedAt: executionStart)
        try await wait("document.querySelector('.live-indicator')?.textContent.includes('等待你的确认') === true", in: web)
        try await assertJavaScript("document.querySelectorAll('.turn-live-elapsed').length", equals: 0, in: web)
        try await screenshot("execution-waiting", web: web)

        model.snapshot = executionFixture(live: false, failedPlanUpdate: true, generation: 4)
        try await wait("document.body.innerText.includes('版本 4') && !document.querySelector('.live-indicator')", in: web)
        try await assertJavaScript("document.querySelector('.todo-count').textContent", equals: "1/2", in: web)
        try await assertJavaScript("document.querySelector('.todo-panel').open", equals: false, in: web)
        try await assertJavaScript("document.querySelector('.todo-ended-note').textContent", equals: "任务清单仍有未完成项", in: web)
        let errorKept = try await web.evaluateJavaScript("document.querySelector('[data-block-id=\"plan-update\"]') !== null") as? Bool
        XCTAssertEqual(errorKept, true, "A failed plan update must remain inspectable")
        _ = try await web.evaluateJavaScript("document.querySelector('.todo-panel-summary').click()")
        try await wait("document.querySelector('.todo-panel').open === true", in: web)
        try await assertJavaScript("document.querySelector('.todo-row[data-status=\"in_progress\"] .todo-row-text').textContent",
                                   equals: "验证构建", in: web)
        _ = try await web.evaluateJavaScript("document.querySelector('.todo-panel-summary').click()")
        try await screenshot("execution-partial", web: web)

        model.snapshot = executionFixture(live: false, allComplete: true, generation: 5)
        try await wait("document.querySelector('.todo-count')?.textContent === '2/2'", in: web)
        try await assertJavaScript("document.querySelector('.todo-panel').open", equals: false, in: web)
        try await assertJavaScript("document.querySelectorAll('.todo-ended-note').length", equals: 0, in: web)
        try await screenshot("execution-complete", web: web)
        _ = try await web.evaluateJavaScript("document.querySelector('.todo-panel-summary').click()")
        try await wait("document.querySelector('.todo-panel').open === true", in: web)
        model.snapshot = executionFixture(live: false, allComplete: true, generation: 6)
        try await wait("document.body.innerText.includes('版本 6')", in: web)
        try await assertJavaScript("document.querySelector('.todo-panel').open", equals: true, in: web)
    }

    private func assertJavaScript<T: Equatable>(_ script: String, equals expected: T, in web: WKWebView,
                                               file: StaticString = #filePath, line: UInt = #line) async throws {
        let actual = try await web.evaluateJavaScript(script) as? T
        XCTAssertEqual(actual, expected, script, file: file, line: line)
    }

    func testWaitingMetadataDoesNotRequireReplacingStableTurns() throws {
        let old = ConversationWebDocumentBuilder.build(snapshot: executionFixture(), conversationID: "appearance", revision: 1)
        let result = ConversationWebDocumentBuilder.buildWithStableTurns(snapshot: executionFixture(approval: true),
            conversationID: "appearance", revision: 2,
            reusing: .init(snapshot: executionFixture(), document: old, extensionContributions: [:]))
        XCTAssertEqual(result.stableTurnIDs, ["execution-turn"])
        let update = try XCTUnwrap(ConversationWebDocumentDiffer.update(from: old, to: result.document))
        XCTAssertEqual(update.patch?.operations.map(\.kind), [.setLive])
        XCTAssertEqual(result.document.live?.waitingReason, "approval")
    }

    private func scrollFixture(generation: UInt64 = 1) -> RuntimeSnapshot {
        let blocks: [TurnBlock] = (0..<32).map { index in
            .text(id: "scroll-block-\(index)", .init(role: .assistant,
                text: "## 检查项目 \(index)\n\n" + String(repeating: "这一段用于验证长对话的阅读位置与动态布局。\n\n", count: 4)))
        }
        let turn = ConversationTurn(id: "scroll-turn", userPrompt: .init(role: .user, text: "验证长对话滚动"),
            blocks: blocks, todos: [.init(content: "读取文件", status: .completed), .init(content: "验证布局", status: .inProgress)],
            footer: nil, isLive: false)
        return .init(timeline: [], turns: [turn], generation: generation)
    }

    func testAsyncLayoutGrowthKeepsVisibleBlockWithinOneLongTurn() async throws {
        let model = AppearanceRenderModel()
        model.snapshot = scrollFixture()
        let web = try await present(model)
        _ = try await web.evaluateJavaScript("""
        (() => {
          const target = document.querySelector('[data-block-id="scroll-block-16"]');
          window.dispatchEvent(new WheelEvent('wheel', {deltaY:-120}));
          window.scrollTo(0, window.scrollY + target.getBoundingClientRect().top - 80);
        })()
        """)
        try await wait("window.AgentKitWorkbench.viewportDiagnostics().interacting === false", in: web)
        let before = try await web.evaluateJavaScript("document.querySelector('[data-block-id=\"scroll-block-16\"]').getBoundingClientRect().top") as? Double
        // A delayed image/output above the viewport changes height without a document revision.
        _ = try await web.evaluateJavaScript("""
        (() => {
          const above = document.querySelector('[data-block-id="scroll-block-2"]');
          const delayed = document.createElement('div');
          delayed.style.height = '240px'; above.append(delayed);
        })()
        """)
        try await Task.sleep(for: .milliseconds(200))
        let after = try await web.evaluateJavaScript("document.querySelector('[data-block-id=\"scroll-block-16\"]').getBoundingClientRect().top") as? Double
        XCTAssertEqual(try XCTUnwrap(after), try XCTUnwrap(before), accuracy: 1)
        try await assertJavaScript("window.AgentKitWorkbench.viewportDiagnostics().pinned", equals: false, in: web)
        // Native composer/approval height changes must not pull a historical reader to the tail.
        _ = try await web.evaluateJavaScript("window.AgentKitWorkbench.setBottomInset(240)")
        try await Task.sleep(for: .milliseconds(100))
        let afterInset = try await web.evaluateJavaScript("document.querySelector('[data-block-id=\"scroll-block-16\"]').getBoundingClientRect().top") as? Double
        XCTAssertEqual(try XCTUnwrap(afterInset), try XCTUnwrap(before), accuracy: 1)
        _ = try await web.evaluateJavaScript("document.querySelector('.jump-to-latest').click()")
        try await wait("window.AgentKitWorkbench.viewportDiagnostics().pinned === true", in: web)
        _ = try await web.evaluateJavaScript("window.AgentKitWorkbench.setBottomInset(420)")
        try await wait("Math.abs(window.AgentKitWorkbench.viewportDiagnostics().distanceFromBottom) <= 1", in: web)
        print("READING_ANCHOR_PERFORMANCE before=\(before ?? -1) afterGrowth=\(after ?? -1) afterInset=\(afterInset ?? -1)")
    }

    func testJumpToLatestClearsFloatingComposerInset() async throws {
        let model = AppearanceRenderModel()
        model.snapshot = scrollFixture()
        let web = try await present(model)
        // Leave the pinned tail so the jump pill is offered in history.
        _ = try await web.evaluateJavaScript("""
        window.dispatchEvent(new WheelEvent('wheel', {deltaY:-120}));
        window.scrollTo(0, 0);
        """)
        try await wait("window.AgentKitWorkbench.viewportDiagnostics().interacting === false", in: web)
        try await wait("document.querySelector('.jump-to-latest') !== null", in: web)

        _ = try await web.evaluateJavaScript("window.AgentKitWorkbench.setBottomInset(240)")
        let geometry = try await web.evaluateJavaScript("""
        (() => {
          const button = document.querySelector('.jump-to-latest').getBoundingClientRect();
          return { bottom: button.bottom, viewportHeight: window.innerHeight };
        })()
        """) as? [String: Double]
        let bottom = try XCTUnwrap(geometry?["bottom"])
        let viewportHeight = try XCTUnwrap(geometry?["viewportHeight"])
        // The pill must sit above the floating composer, not behind it.
        XCTAssertLessThanOrEqual(bottom, viewportHeight - 240 + 1,
                                 "Jump-to-latest overlaps the composer inset")
    }

    func testTasksExpansionKeepsSummaryAndPausesTailFollowing() async throws {
        let model = AppearanceRenderModel()
        model.snapshot = scrollFixture()
        let web = try await present(model)
        try await wait("document.querySelector('.todo-panel')?.open === false", in: web)
        try await wait("Math.abs(window.AgentKitWorkbench.viewportDiagnostics().distanceFromBottom) <= 1", in: web)
        let before = try await web.evaluateJavaScript("document.querySelector('.todo-panel-summary').getBoundingClientRect().top") as? Double
        _ = try await web.evaluateJavaScript("document.querySelector('.todo-panel-summary').click()")
        try await wait("document.querySelector('.todo-panel')?.open === true", in: web)
        try await Task.sleep(for: .milliseconds(200))
        let after = try await web.evaluateJavaScript("document.querySelector('.todo-panel-summary').getBoundingClientRect().top") as? Double
        XCTAssertEqual(try XCTUnwrap(after), try XCTUnwrap(before), accuracy: 1)
        try await assertJavaScript("window.AgentKitWorkbench.viewportDiagnostics().pinned", equals: false, in: web)
        _ = try await web.evaluateJavaScript("document.querySelector('.jump-to-latest').click()")
        try await wait("window.AgentKitWorkbench.viewportDiagnostics().pinned === true", in: web)
    }

    func testLongUserMessageExpansionDoesNotJumpToItsEnd() async throws {
        let model = AppearanceRenderModel()
        let turn = ConversationTurn(id: "long-user-turn", userPrompt: .init(role: .user,
            text: String(repeating: "逐项检查对话内容和执行状态。\n", count: 60)),
            blocks: [.text(id: "long-user-answer", .init(role: .assistant, text: "我会先检查布局，再验证交互。"))],
            footer: nil, isLive: false)
        model.snapshot = .init(timeline: [], turns: [turn], generation: 1)
        let web = try await present(model)
        try await wait("document.querySelector('.user-prompt-toggle') !== null", in: web)
        let before = try await web.evaluateJavaScript("document.querySelector('.user-message').getBoundingClientRect().top") as? Double
        _ = try await web.evaluateJavaScript("document.querySelector('.user-prompt-toggle').click()")
        try await wait("document.querySelector('.user-prompt-content.is-expanded') !== null", in: web)
        try await Task.sleep(for: .milliseconds(200))
        let after = try await web.evaluateJavaScript("document.querySelector('.user-message').getBoundingClientRect().top") as? Double
        XCTAssertEqual(try XCTUnwrap(after), try XCTUnwrap(before), accuracy: 1)
        try await assertJavaScript("window.AgentKitWorkbench.viewportDiagnostics().pinned", equals: false, in: web)
        // The user explicitly moves to the expanded message's collapse control.
        _ = try await web.evaluateJavaScript("window.dispatchEvent(new WheelEvent('wheel', {deltaY:120})); document.querySelector('.user-prompt-toggle').scrollIntoView({block:'center'})")
        try await wait("window.AgentKitWorkbench.viewportDiagnostics().interacting === false", in: web)
        _ = try await web.evaluateJavaScript("document.querySelector('.user-prompt-toggle').click()")
        try await wait("document.querySelector('.user-prompt-content.is-expanded') === null", in: web)
        try await assertJavaScript("window.AgentKitWorkbench.viewportDiagnostics().pinned", equals: false, in: web)
    }

    func testWindowResizePreservesVisibleBlockInHistoricalReading() async throws {
        let model = AppearanceRenderModel()
        model.snapshot = scrollFixture()
        let web = try await present(model)
        _ = try await web.evaluateJavaScript("window.dispatchEvent(new WheelEvent('wheel', {deltaY:-120})); document.querySelector('[data-block-id=\"scroll-block-16\"]').scrollIntoView({block:'start'})")
        try await wait("window.AgentKitWorkbench.viewportDiagnostics().interacting === false", in: web)
        let before = try await web.evaluateJavaScript("document.querySelector('[data-block-id=\"scroll-block-16\"]').getBoundingClientRect().top") as? Double
        window?.setContentSize(NSSize(width: 520, height: 960))
        try await wait("innerWidth <= 520", in: web)
        try await Task.sleep(for: .milliseconds(160))
        let after = try await web.evaluateJavaScript("document.querySelector('[data-block-id=\"scroll-block-16\"]').getBoundingClientRect().top") as? Double
        XCTAssertEqual(try XCTUnwrap(after), try XCTUnwrap(before), accuracy: 1)
        try await assertJavaScript("window.AgentKitWorkbench.viewportDiagnostics().pinned", equals: false, in: web)
    }

    func testPointerHoldKeepsOwnershipUntilRelease() async throws {
        let model = AppearanceRenderModel()
        model.snapshot = scrollFixture()
        let web = try await present(model)
        _ = try await web.evaluateJavaScript("window.dispatchEvent(new WheelEvent('wheel', {deltaY:-120})); document.querySelector('[data-block-id=\"scroll-block-16\"]').scrollIntoView({block:'start'})")
        try await wait("window.AgentKitWorkbench.viewportDiagnostics().interacting === false", in: web)
        _ = try await web.evaluateJavaScript("window.dispatchEvent(new PointerEvent('pointerdown', {pointerId:42}))")
        try await Task.sleep(for: .milliseconds(240))
        try await assertJavaScript("window.AgentKitWorkbench.viewportDiagnostics().interacting", equals: true, in: web)
        let before = try await web.evaluateJavaScript("window.scrollY") as? Double
        _ = try await web.evaluateJavaScript("document.querySelector('[data-block-id=\"scroll-block-2\"]').style.paddingBottom = '200px'")
        try await Task.sleep(for: .milliseconds(80))
        let during = try await web.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertEqual(try XCTUnwrap(during), try XCTUnwrap(before), accuracy: 1,
                       "An asynchronous resize must not correct scroll underneath a held pointer")
        _ = try await web.evaluateJavaScript("window.dispatchEvent(new PointerEvent('pointerup', {pointerId:42}))")
        try await wait("window.AgentKitWorkbench.viewportDiagnostics().interacting === false", in: web)
        _ = try await web.evaluateJavaScript("window.dispatchEvent(new PointerEvent('pointerdown', {pointerId:43})); window.dispatchEvent(new Event('blur'))")
        try await wait("window.AgentKitWorkbench.viewportDiagnostics().interacting === false", in: web)
        _ = try await web.evaluateJavaScript("document.querySelector('.jump-to-latest').click()")
        try await wait("window.AgentKitWorkbench.viewportDiagnostics().pinned === true", in: web)
    }
}
#endif
