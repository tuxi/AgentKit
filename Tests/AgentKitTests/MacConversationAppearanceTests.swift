#if os(macOS)
import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import AgentKit

@MainActor @Observable
private final class AppearanceRenderModel {
    var snapshot: RuntimeSnapshot = .empty(sessionID: "appearance")
}

@MainActor
private struct AppearanceRenderHost: View {
    let model: AppearanceRenderModel
    let store: WorkspaceStore
    var body: some View {
        ConversationWebWorkbenchView(snapshot: model.snapshot, conversationID: "appearance", workspaceRoot: nil,
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
        try await assertJavaScript("document.querySelector('.todo-ended-note').textContent", equals: "仍有未完成项", in: web)
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
}
#endif
