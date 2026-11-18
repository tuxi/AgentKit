#if os(macOS)
import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import AgentKit

@MainActor @Observable
private final class ToolGroupRenderModel {
    var snapshot: RuntimeSnapshot = .empty(sessionID: "tool-group-design")
}

@MainActor
private struct ToolGroupRenderHost: View {
    let model: ToolGroupRenderModel
    let store: WorkspaceStore
    var body: some View {
        ConversationWebWorkbenchView(snapshot: model.snapshot, conversationID: "tool-group-design", workspaceRoot: nil,
            previewViewerResolver: nil, previewAssetResolver: nil,
            extensionContributions: [:], timelineExtensions: [], isVisible: true, bottomInset: 0,
            onFatalFailure: { XCTFail("Workbench failed") })
        .environment(store)
    }
}

@MainActor
final class MacToolGroupRenderTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        try await super.tearDown()
    }

    private func snapshot(live: Bool, count: Int = 40, output: String, failed: Bool = false, generation: UInt64 = 1, command: String? = nil, thinking: Bool = false, description: String? = nil, assets: [AgentAssetRef] = []) -> RuntimeSnapshot {
        let tools = (0..<count).map { i in
            ToolNodePayload(callID: "cmd-\(i)", toolName: "exec_command", args: .object(["cmd": .string(command ?? "swift test --filter GroupTests\(i)")] .merging(description.map { ["description": .string($0)] } ?? [:]) { _, new in new }),
                status: i == 0 ? (failed ? .failed : live ? .running : .completed) : .completed,
                output: i == 0 ? output : "", assets: assets, exitCode: i == 0 && failed ? 1 : nil, elapsedMs: live && i == 0 ? nil : 2300)
        }
        var entries = tools.map(ToolGroup.Entry.tool)
        if thinking { entries.insert(.thinking(id: "thought", .init(text: "检查分组和命令输出的呈现规则。", isStreaming: live)), at: 1) }
        let groupStart = Date().addingTimeInterval(-88)
        let group = ToolGroup(id: "group-stable", entries: entries, isCollecting: live,
            startedAt: groupStart, finishedAt: live ? nil : groupStart.addingTimeInterval(88))
        let turn = ConversationTurn(id: "turn-stable", userPrompt: .init(role: .user, text: "检查工具组展示"), blocks: [
            .text(id: "before", .init(role: .assistant, text: "先检查实现，再运行测试。")),
            .toolGroup(group),
            .text(id: "after", .init(role: .assistant, text: live ? "验证执行中。" : "验证已结束。")),
        ], footer: nil, isLive: live)
        return RuntimeSnapshot(timeline: [], turns: [turn], generation: generation)
    }

    private func present(_ model: ToolGroupRenderModel, width: CGFloat = 980) async throws -> WKWebView {
        let host = NSHostingView(rootView: ToolGroupRenderHost(model: model, store: WorkspaceStore(usesEmbeddedRuntime: false)))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 860)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Talkify · macOS 工具组验收"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        self.window = window
        func find(_ view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap(find).first
        }
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if let web = find(host) {
                try await wait("document.querySelector('.tool-group') !== null", in: web)
                return web
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "ToolGroupRender", code: 1)
    }

    private func wait(_ script: String, in web: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if try await web.evaluateJavaScript(script) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(80))
        }
        let body = try? await web.evaluateJavaScript("document.body.innerText")
        XCTFail("Timed out: \(script)\n\(body ?? "")")
        throw NSError(domain: "ToolGroupRender", code: 2)
    }

    private func click(_ selector: String, in web: WKWebView) async throws {
        _ = try await web.evaluateJavaScript("document.querySelector('\(selector)')?.dispatchEvent(new MouseEvent('click', {bubbles:true,cancelable:true}))")
    }

    func testTurnOutcomesStayCompactAndRevealExactDiagnostics() async throws {
        let model = ToolGroupRenderModel()
        let tool = ToolNodePayload(callID: "outcome-cmd", toolName: "exec_command", args: .object(["cmd": .string("swift test")]), status: .completed)
        let group = ToolGroup(id: "outcome-group", tools: [tool])
        let budget = "model api error: status=400 type=invalid_request_error This model's maximum context length is 1048576 tokens. However, you requested 393216 output tokens and your prompt contains at least 655361 input tokens."
        let cancelled = ConversationTurn(id: "cancelled", userPrompt: nil, blocks: [.toolGroup(group), .system(id: "cancelled-state", .init(kind: .modelActivity, text: "已取消 — user_requested", metadata: ["type": "cancelled"]))], footer: nil, isLive: false)
        let failed = ConversationTurn(id: "failed", userPrompt: nil, blocks: [.system(id: "error-state", .init(kind: .error, text: budget))], footer: .init(contextTokens: 0, totalTokens: 0, elapsedMs: 0, invocationCount: 1, hasTokenUsage: false), isLive: false)
        model.snapshot = .init(timeline: [], turns: [cancelled, failed], generation: 1)
        let web = try await present(model, width: 820)
        try await wait("document.querySelector('.turn-outcome') !== null", in: web)
        let opened = try await web.evaluateJavaScript("document.querySelectorAll('.turn-outcome-details[open]').length") as? Int
        XCTAssertEqual(opened, 0)
        let cancelControls = try await web.evaluateJavaScript("document.querySelector('.turn-cancelled').querySelectorAll('details,svg,button').length") as? Int
        XCTAssertEqual(cancelControls, 0)
        let body = try await web.evaluateJavaScript("document.body.innerText") as? String ?? ""
        XCTAssertFalse(body.contains("user_requested"))
        try await click(".turn-outcome-details > summary", in: web)
        try await wait("document.querySelector('.turn-outcome-details[open] dl') !== null", in: web)
        let facts = try await web.evaluateJavaScript("document.querySelector('.turn-outcome-details dl').innerText") as? String ?? ""
        XCTAssertTrue(facts.contains("1,048,577"))
        XCTAssertTrue(facts.contains("1 token"))
        let rawOpened = try await web.evaluateJavaScript("document.querySelectorAll('.turn-outcome-raw[open]').length") as? Int
        XCTAssertEqual(rawOpened, 0)
        try await click(".turn-outcome-raw > summary", in: web)
        try await wait("document.querySelector('.turn-outcome-raw[open]') !== null", in: web)
        if let tiff = try await web.takeSnapshot(configuration: nil).tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
           let path = ProcessInfo.processInfo.environment["TOOL_GROUP_SCREENSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("turn-outcomes-expanded.png"))
        }
    }

    func testLargeCollapsedHistoryExpandsOnlyClickedGroup() async throws {
        let groups: [TurnBlock] = (0..<40).map { g in
            let tools = (0..<120).map { i in
                ToolNodePayload(callID: "perf-\(g)-\(i)", toolName: "exec_command", args: .object(["cmd": .string("swift test --filter Case\(i)")]), status: .completed, output: String(repeating: "output line\n", count: 30))
            }
            return .toolGroup(.init(id: "perf-group-\(g)", entries: tools.map(ToolGroup.Entry.tool)))
        }
        let model = ToolGroupRenderModel()
        model.snapshot = .init(timeline: [], turns: [.init(id: "perf-turn", userPrompt: nil, blocks: groups, footer: nil, isLive: false)], generation: 1)
        let web = try await present(model)
        try await wait("document.querySelectorAll('.tool-group').length === 40", in: web)
        _ = try await web.evaluateJavaScript("""
        (() => {
          const target = document.querySelector('[data-block-id="perf-group-20"] .tool-group-summary');
          target.scrollIntoView({block:'center'});
          window.__perfTarget = target;
          window.__perfTop = target.getBoundingClientRect().top;
          const start = performance.now();
          const observer = new MutationObserver(() => {
            if (document.querySelectorAll('.tool-summary').length === 120) {
              window.__perfReady = performance.now() - start;
              observer.disconnect();
            }
          });
          observer.observe(target.parentElement, {childList:true,subtree:true});
          target.click();
          window.__perfSync = performance.now() - start;
        })()
        """)
        try await wait("window.__perfReady !== undefined", in: web)
        let metrics = try await web.evaluateJavaScript("({sync:window.__perfSync,ready:window.__perfReady,groups:document.querySelectorAll('.tool-group[open]').length,clicked:document.querySelector('[data-block-id=\"perf-group-20\"] .tool-group').open,shift:Math.abs(window.__perfTarget.getBoundingClientRect().top-window.__perfTop),outputs:document.querySelectorAll('.tool-output-frame').length})") as? [String: Any]
        print("DISCLOSURE_PERFORMANCE \(metrics ?? [:])")
        XCTAssertEqual(metrics?["groups"] as? Int, 1)
        XCTAssertEqual(metrics?["clicked"] as? Bool, true)
        XCTAssertEqual(metrics?["outputs"] as? Int, 0)
        XCTAssertLessThan(metrics?["shift"] as? Double ?? 100, 2)
        try await click("[data-block-id=\"perf-group-20\"] .tool-group-summary", in: web)
        try await wait("document.querySelectorAll('.tool-summary').length === 0", in: web)
        try await click("[data-block-id=\"perf-group-19\"] .tool-group-summary", in: web)
        try await wait("document.querySelector('[data-block-id=\"perf-group-19\"] .tool-group').open && !document.querySelector('[data-block-id=\"perf-group-20\"] .tool-group').open", in: web)
    }

    func testExistingTextSelectionDoesNotSwallowDisclosureClick() async throws {
        let model = ToolGroupRenderModel()
        model.snapshot = snapshot(live: false, count: 3, output: "preserve output")
        let web = try await present(model)
        _ = try await web.evaluateJavaScript("""
        (() => {
          const range = document.createRange();
          range.selectNodeContents(document.querySelector('.tool-group-title'));
          window.getSelection().removeAllRanges(); window.getSelection().addRange(range);
          document.querySelector('.tool-group-summary').click();
        })()
        """)
        try await wait("document.querySelector('.tool-group').open", in: web)
        let selected = try await web.evaluateJavaScript("window.getSelection().toString()") as? String
        XCTAssertFalse(selected?.isEmpty ?? true, "disclosure must not destroy an existing selection")
    }

    func testDragSelectionAndRapidDisclosureActivationsRemainIndependent() async throws {
        let model = ToolGroupRenderModel()
        model.snapshot = snapshot(live: false, count: 3, output: "preserve output")
        let web = try await present(model)
        _ = try await web.evaluateJavaScript("""
        (() => {
          const header = document.querySelector('.tool-group-summary');
          window.getSelection().removeAllRanges();
          header.dispatchEvent(new PointerEvent('pointerdown', {bubbles:true,clientX:10,clientY:10}));
          const range = document.createRange(); range.selectNodeContents(header.querySelector('.tool-group-title'));
          window.getSelection().addRange(range);
          header.dispatchEvent(new MouseEvent('click', {bubbles:true,cancelable:true,detail:1,clientX:80,clientY:10}));
        })()
        """)
        let afterDrag = try await web.evaluateJavaScript("document.querySelector('.tool-group').open") as? Bool
        XCTAssertEqual(afterDrag, false, "dragging text must not toggle the group")
        try await click(".tool-group-summary", in: web)
        try await wait("document.querySelector('.tool-group').open", in: web)
        _ = try await web.evaluateJavaScript("document.querySelector('.tool-group-summary').click(); document.querySelector('.tool-group-summary').click()")
        try await wait("document.querySelector('.tool-group').open", in: web)
        let afterDoubleClick = try await web.evaluateJavaScript("document.querySelector('.tool-group').open") as? Bool
        XCTAssertEqual(afterDoubleClick, true, "two activations must toggle twice rather than both using stale state")
    }

    func testPatchDoesNotRestorePreviousGroupFocusOverNewActivation() async throws {
        func value(marker: Bool) -> RuntimeSnapshot {
            var blocks: [TurnBlock] = ["first", "second"].map { id in
                .toolGroup(.init(id: id, entries: [.tool(.init(callID: "focus-\(id)", toolName: "exec_command", args: .object(["cmd": .string("pwd")]), status: .completed))]))
            }
            if marker { blocks.append(.text(id: "patch-marker", .init(role: .assistant, text: "Patch applied"))) }
            return .init(timeline: [], turns: [.init(id: "focus-turn", userPrompt: nil, blocks: blocks, footer: nil, isLive: false)], generation: marker ? 2 : 1)
        }
        let model = ToolGroupRenderModel()
        model.snapshot = value(marker: false)
        let web = try await present(model)
        let first = ConversationWebDocumentBuilder.build(snapshot: value(marker: false), conversationID: "tool-group-design", revision: 10000)
        let second = ConversationWebDocumentBuilder.build(snapshot: value(marker: true), conversationID: "tool-group-design", revision: 10001)
        let reset = try JSONEncoder().encode(ConversationWebDocumentDiffer.reset(first)).base64EncodedString()
        _ = try await web.evaluateJavaScript("window.AgentKitWorkbench.applyUpdateBase64('\(reset)')")
        try await wait("document.querySelectorAll('.tool-group').length === 2", in: web)
        try await Task.sleep(for: .milliseconds(100))
        let patch = try JSONEncoder().encode(XCTUnwrap(ConversationWebDocumentDiffer.update(from: first, to: second))).base64EncodedString()
        _ = try await web.evaluateJavaScript("""
        (() => {
          window.getSelection().removeAllRanges();
          document.querySelector('[data-block-id="first"] .tool-group-summary').focus();
          window.AgentKitWorkbench.applyUpdateBase64('\(patch)');
          const target = document.querySelector('[data-block-id="second"] .tool-group-summary');
          target.focus(); target.click();
        })()
        """)
        try await wait("document.querySelector('[data-block-id=\"patch-marker\"]') !== null && document.querySelector('[data-block-id=\"second\"] .tool-group').open", in: web)
        try await Task.sleep(for: .milliseconds(100))
        let state = try await web.evaluateJavaScript("({correctFocus:document.activeElement === document.querySelector('[data-block-id=\"second\"] .tool-group-summary'),firstOpen:document.querySelector('[data-block-id=\"first\"] .tool-group').open})") as? [String: Any]
        XCTAssertEqual(state?["correctFocus"] as? Bool, true)
        XCTAssertEqual(state?["firstOpen"] as? Bool, false)
    }

    func testCurrentActionStaysWhenOpenedAndFinishingShowsAggregate() async throws {
        func mixedSnapshot(live: Bool, generation: UInt64) -> RuntimeSnapshot {
            let tools: [ToolNodePayload] = [
                .init(callID: "read", toolName: "read_file", args: .object(["path": .string("Sources/App.swift")]), status: .completed),
                .init(callID: "cmd", toolName: "exec_command", args: .object(["cmd": .string("swift test"), "description": .string("验证工具组展示")]), status: live ? .running : .completed),
                .init(callID: "bad", toolName: "git_status", args: nil, status: .failed)]
            let group = ToolGroup(id: "mixed", entries: tools.map(ToolGroup.Entry.tool), isCollecting: live)
            return RuntimeSnapshot(timeline: [], turns: [.init(id: "mixed-turn", userPrompt: nil, blocks: [.toolGroup(group)], footer: nil, isLive: live)], generation: generation)
        }
        let model = ToolGroupRenderModel()
        model.snapshot = mixedSnapshot(live: true, generation: 1)
        let web = try await present(model)
        try await wait("!document.querySelector('.tool-group').open && document.querySelector('.tool-group-title').textContent.includes('验证工具组展示')", in: web)
        let failure = try await web.evaluateJavaScript("document.querySelector('.tool-group-summary').textContent") as? String
        XCTAssertTrue(failure?.contains(ToolTranscriptText().text("desktop.failures", 1)) == true)
        try await click(".tool-group-summary", in: web)
        try await wait("document.querySelector('.tool-group').open && document.querySelector('.tool-group-title').textContent.includes('验证工具组展示')", in: web)
        let title = try await web.evaluateJavaScript("document.querySelector('.tool-group-title').textContent") as? String
        XCTAssertTrue(title?.contains("验证工具组展示") == true)
        model.snapshot = mixedSnapshot(live: false, generation: 2)
        try await wait("document.querySelector('.tool-group').dataset.status !== 'running' && document.querySelector('.tool-group').open", in: web)
        try await click(".tool-group-summary", in: web)
        try await wait("!document.querySelector('.tool-group').open", in: web)
        let completedTitle = try await web.evaluateJavaScript("document.querySelector('.tool-group-title').textContent") as? String
        XCTAssertTrue(completedTitle?.contains("App.swift") == true)
        XCTAssertTrue(completedTitle?.contains("Git") == true)
        XCTAssertNotEqual(completedTitle, title)
        if let tiff = try await web.takeSnapshot(configuration: nil).tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
            let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TOOL_GROUP_SCREENSHOT_DIR"] ?? NSTemporaryDirectory())
            try png.write(to: dir.appendingPathComponent("tool-group-summary.png"))
        }
    }

    func testRunningIndicatorAndSkeletonFollowRealContentAcrossUpdates() async throws {
        func value(_ phase: Int, output: String = "") -> RuntimeSnapshot {
            let tool = ToolNodePayload(callID: "live-cmd", toolName: "exec_command", args: .object(["cmd": .string("codesign -dv Payload/Talkify.app"), "description": .string("检查 IPA 签名")]), status: phase < 2 ? .running : .completed, output: output)
            let group = ToolGroup(id: "live-group", entries: [.tool(tool)], isCollecting: phase < 3)
            return .init(timeline: [], turns: [.init(id: "live-turn", userPrompt: nil, blocks: [.toolGroup(group)], footer: nil, isLive: phase < 3)], generation: UInt64(phase + (output.isEmpty ? 1 : 10)))
        }
        let model = ToolGroupRenderModel()
        model.snapshot = value(0)
        let web = try await present(model, width: 490)
        try await wait("document.querySelectorAll('.tool-group-running > span').length === 4", in: web)
        let initiallyCollapsed = try await web.evaluateJavaScript("document.querySelectorAll('.activity-skeleton').length") as? Int
        XCTAssertEqual(initiallyCollapsed, 0)
        try await click(".tool-group-summary", in: web)
        try await wait("document.querySelector('.tool-group-pending')?.getBoundingClientRect().height > 0", in: web)
        let markFits = try await web.evaluateJavaScript("document.querySelector('.tool-group-running').getBoundingClientRect().left >= 0") as? Bool
        XCTAssertEqual(markFits, true)
        try await click(".tool-summary", in: web)
        try await wait("document.querySelector('.tool-output-skeleton')?.getBoundingClientRect().height > 0 && getComputedStyle(document.querySelector('.tool-group-pending')).display === 'none'", in: web)
        if let tiff = try await web.takeSnapshot(configuration: nil).tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
           let path = ProcessInfo.processInfo.environment["TOOL_GROUP_SCREENSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("tool-group-running-skeleton.png"))
        }
        model.snapshot = value(1, output: "Authority=Apple Development")
        try await wait("document.querySelector('.tool-output-frame')?.textContent.includes('Authority=Apple Development') && document.querySelectorAll('.activity-skeleton').length === 0", in: web)
        model.snapshot = value(2, output: "Authority=Apple Development")
        try await wait("document.querySelector('.tool-group').dataset.active === 'false' && document.querySelector('.tool-group-pending') !== null", in: web)
        let gapTitle = try await web.evaluateJavaScript("document.querySelector('.tool-group-title').textContent") as? String
        XCTAssertFalse(gapTitle?.contains("正在处理") == true)
        XCTAssertFalse(gapTitle?.contains("检查 IPA 签名") == true)
        let gapDuration = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('.tool-group-running')).animationDuration") as? String
        let reducedMotion = try await web.evaluateJavaScript("matchMedia('(prefers-reduced-motion: reduce)').matches") as? Bool
        XCTAssertEqual(gapDuration, reducedMotion == true ? "0s" : "4.2s")
        model.snapshot = value(3, output: "Authority=Apple Development")
        try await wait("document.querySelectorAll('.activity-skeleton,.tool-group-running').length === 0 && document.querySelector('.tool-group').open", in: web)
        let completeTitle = try await web.evaluateJavaScript("document.querySelector('.tool-group-title').textContent") as? String
        XCTAssertEqual(completeTitle, gapTitle)
        let toolRemainsOpen = try await web.evaluateJavaScript("document.querySelector('.tool').open") as? Bool
        XCTAssertEqual(toolRemainsOpen, true)
    }

    func testCommandRowsStaySingleLineAtNarrowWidthsAndKeepFullInputWhenOpened() async throws {
        let command = "git -C /Users/xiaoyuan/Documents/work/git/AgentKit status --short; echo ---; git -C /Users/xiaoyuan/Documents/work/git/AgentKit log --oneline -5"
        let model = ToolGroupRenderModel()
        let description = "检查工具组展示与回归测试日志，确认命令执行和状态切换正确 " + String(repeating: "保留简短动作说明 ", count: 12)
        model.snapshot = snapshot(live: false, count: 2, output: "verified output", command: command, description: description)
        let web = try await present(model, width: 490)
        try await click(".tool-group-summary", in: web)
        try await wait("document.querySelectorAll('.tool-summary').length === 2", in: web)
        for width in [CGFloat(360), 490, 740] {
            window?.setContentSize(NSSize(width: width, height: 860))
            window?.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            let layout = try await web.evaluateJavaScript("""
            (() => {
              const row = document.querySelector('.tool-summary'), title = row.querySelector('.tool-title');
              const arrow = row.querySelector('.disclosure-chevron');
              return { oneLine: title.getBoundingClientRect().height <= parseFloat(getComputedStyle(title).lineHeight) + 1,
                nowrap: getComputedStyle(title).whiteSpace === 'nowrap', clipped: title.scrollWidth > title.clientWidth,
                ellipsis: getComputedStyle(title).textOverflow === 'ellipsis',
                arrowVisible: arrow.getBoundingClientRect().right <= row.getBoundingClientRect().right,
                rawCommand: title.textContent.includes('/Users/'), title: title.textContent };
            })()
            """) as? [String: Any]
            XCTAssertEqual(layout?["oneLine"] as? Bool, true, "width \(width)")
            XCTAssertEqual(layout?["nowrap"] as? Bool, true)
            XCTAssertEqual(layout?["ellipsis"] as? Bool, true)
            XCTAssertEqual(layout?["clipped"] as? Bool, true)
            XCTAssertEqual(layout?["arrowVisible"] as? Bool, true)
            XCTAssertEqual(layout?["rawCommand"] as? Bool, false)
        }
        window?.setContentSize(NSSize(width: 490, height: 860))
        window?.contentView?.layoutSubtreeIfNeeded()
        try await click(".tool-summary", in: web)
        try await wait("document.querySelector('.tool-input-scroll') !== null", in: web)
        let input = try await web.evaluateJavaScript("document.querySelector('.tool-command-text').textContent") as? String
        XCTAssertEqual(input, command)
        // A missing description must also use a short label, including scripts.
        model.snapshot = snapshot(live: false, count: 2, output: "verified output", generation: 2, command: command)
        try await wait("!document.querySelector('.tool-title').textContent.includes('检查工具组')", in: web)
        let fallback = try await web.evaluateJavaScript("document.querySelector('.tool-title').textContent") as? String
        XCTAssertEqual(fallback, ToolTranscriptText().text("desktop.runNamed", "git"))
        try await click(".tool-summary", in: web)
        try await wait("!document.querySelector('.tool').open", in: web)
        try await Task.sleep(for: .milliseconds(80))
        let image = try await web.takeSnapshot(configuration: nil)
        if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]),
           let path = ProcessInfo.processInfo.environment["TOOL_GROUP_SCREENSHOT_DIR"] {
            try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("tool-command-compact-rows.png"))
        }
    }

    func testBackgroundJobsShareOneGroupAndPreserveDisclosureThroughCompletion() async throws {
        func jobSnapshot(status: ChildStreamNodeStatus, generation: UInt64) -> RuntimeSnapshot {
            let job = ChildStreamNodePayload(kind: .job, childID: "background-build", title: "swift test --package-path /Users/example/AgentKit", status: status,
                result: "PRIVATE JOB RESULT", exitCode: status == .failed ? 1 : nil, output: "PRIVATE JOB OUTPUT")
            let group = ToolGroup(id: "job-activity", entries: [
                .tool(.init(callID: "read", toolName: "read_file", args: .object(["path": .string("App.swift")]), status: .completed)),
                .backgroundJob(id: "job-bracket", job),
                .thinking(id: "thought", .init(text: "Inspect while building", isStreaming: false)),
                .tool(.init(callID: "wait", toolName: "job_wait", args: .object(["job_id": .string("background-build")]), status: .completed))])
            let turn = ConversationTurn(id: "job-turn", userPrompt: nil, blocks: [.toolGroup(group)], footer: nil, isLive: false)
            return RuntimeSnapshot(timeline: [], turns: [turn], generation: generation)
        }
        let model = ToolGroupRenderModel()
        model.snapshot = jobSnapshot(status: .running, generation: 1)
        let web = try await present(model, width: 600)
        try await wait("document.querySelectorAll('.tool-group').length === 1 && !document.querySelector('.tool-group').open && document.querySelector('.tool-group').dataset.status === 'running'", in: web)
        try await click(".tool-group-summary", in: web)
        try await wait("document.querySelector('.background-job-row') !== null", in: web)
        let row = try await web.evaluateJavaScript("""
        (() => {
          const row = document.querySelector('.background-job-row'), group = document.querySelector('.tool-group-tools');
          const entries = [...group.children].filter(e => e.matches('.tool,.thinking-block,.background-job-row'));
          return { count: entries.length, inside: row.parentElement === group,
            order: entries.map(e => e.classList.contains('background-job-row') ? 'job' : e.classList.contains('thinking-block') ? 'thought' : 'tool'),
            icons: row.querySelectorAll('.tool-action-icon').length,
            status: row.querySelector('.tool-status').textContent,
            title: row.querySelector('.tool-title').textContent,
            nowrap: getComputedStyle(row.querySelector('.tool-title')).whiteSpace === 'nowrap',
            inset: Math.abs(row.querySelector('.tool-title').getBoundingClientRect().left - group.querySelector('.tool-title').getBoundingClientRect().left),
            separator: getComputedStyle(row).borderTopWidth, radius: getComputedStyle(row).borderRadius,
            leaked: document.body.textContent.includes('PRIVATE JOB'), standalone: document.querySelectorAll('.child-stream').length };
        })()
        """) as? [String: Any]
        XCTAssertEqual(row?["count"] as? Int, 4)
        XCTAssertEqual(row?["inside"] as? Bool, true)
        XCTAssertEqual(row?["order"] as? [String], ["tool", "job", "thought", "tool"])
        XCTAssertEqual(row?["icons"] as? Int, 0)
        XCTAssertEqual(row?["nowrap"] as? Bool, true)
        XCTAssertEqual(row?["leaked"] as? Bool, false)
        XCTAssertEqual(row?["standalone"] as? Int, 0)
        XCTAssertLessThan(row?["inset"] as? Double ?? 100, 1)
        XCTAssertEqual(row?["separator"] as? String, "1px")
        XCTAssertEqual(row?["radius"] as? String, "0px", "separators stay straight within the shared group frame")
        model.snapshot = jobSnapshot(status: .failed, generation: 2)
        try await wait("document.querySelector('.background-job-row').dataset.status === 'failed' && document.querySelector('.tool-group').open && document.querySelector('.tool-group-summary > .tool-status') !== null", in: web)
        let failed = try await web.evaluateJavaScript("document.querySelector('.background-job-row .tool-status').textContent") as? String
        XCTAssertEqual(failed, ToolTranscriptText().text("failed"))
        model.snapshot = jobSnapshot(status: .canceled, generation: 3)
        try await wait("document.querySelector('.background-job-row').dataset.status === 'canceled' && document.querySelector('.tool-group-summary > .tool-status') === null", in: web)
        model.snapshot = jobSnapshot(status: .completed, generation: 4)
        try await wait("document.querySelector('.background-job-row').dataset.status === 'completed' && document.querySelector('.background-job-row .tool-status') === null && document.querySelector('.tool-group').open", in: web)
        if let tiff = try await web.takeSnapshot(configuration: nil).tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]),
           let path = ProcessInfo.processInfo.environment["TOOL_GROUP_SCREENSHOT_DIR"] {
            try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("tool-group-background-jobs.png"))
        }
        try await click(".tool-group-summary", in: web)
        model.snapshot = jobSnapshot(status: .running, generation: 5)
        try await wait("!document.querySelector('.tool-group').open && document.querySelector('.background-job-row') === null", in: web)
    }

    func testPreEditCheckUsesAlignedCollapsedRowInsideActivityAndKeepsManualExpansion() async throws {
        func checkSnapshot(generation: UInt64, appendTool: Bool) -> RuntimeSnapshot {
            let check = ToolGroup.Entry.preMutation(id: "check", .init(kind: .preMutation, text: "Check the edit keeps public interfaces intact."))
            var entries: [ToolGroup.Entry] = [check, .tool(.init(callID: "edit", toolName: "edit_file", args: nil, status: .completed))]
            if appendTool { entries.append(.tool(.init(callID: "read", toolName: "read_file", args: nil, status: .completed))) }
            return .init(timeline: [], turns: [.init(id: "pre-edit-turn", userPrompt: nil,
                blocks: [.toolGroup(.init(id: "pre-edit-activity", entries: entries))], footer: nil, isLive: false)], generation: generation)
        }
        let model = ToolGroupRenderModel()
        model.snapshot = checkSnapshot(generation: 1, appendTool: false)
        let web = try await present(model, width: 600)
        try await wait("!document.querySelector('.tool-group').open && document.querySelector('.thinking-block') === null", in: web)
        try await click(".tool-group-summary", in: web)
        try await wait("document.querySelector('.thinking-label') !== null", in: web)
        let row = try await web.evaluateJavaScript("""
        (() => {
          const row = document.querySelector('.thinking-block');
          const label = row.querySelector('.thinking-label');
          return { label: label.textContent, inside: row.parentElement.classList.contains('tool-group-tools'),
            open: row.open, body: row.querySelector('.thinking-body') !== null,
            icons: row.querySelectorAll('.tool-action-icon').length,
            aligned: Math.abs(label.getBoundingClientRect().left - document.querySelector('.tool-title').getBoundingClientRect().left) < 1 };
        })()
        """) as? [String: Any]
        XCTAssertEqual(row?["label"] as? String, ToolTranscriptText().text("desktop.preMutation"))
        XCTAssertEqual(row?["inside"] as? Bool, true)
        XCTAssertEqual(row?["open"] as? Bool, false)
        XCTAssertEqual(row?["body"] as? Bool, false)
        XCTAssertEqual(row?["icons"] as? Int, 0)
        XCTAssertEqual(row?["aligned"] as? Bool, true)
        try await click(".thinking-summary", in: web)
        try await wait("document.querySelector('.thinking-body')?.textContent.includes('public interfaces') === true", in: web)
        model.snapshot = checkSnapshot(generation: 2, appendTool: true)
        try await wait("document.querySelectorAll('.tool-summary').length === 3 && document.querySelector('.thinking-block').open && document.querySelector('.tool-group').open", in: web)
        if let tiff = try await web.takeSnapshot(configuration: nil).tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]),
           let path = ProcessInfo.processInfo.environment["TOOL_GROUP_SCREENSHOT_DIR"] {
            try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("tool-group-pre-edit-check.png"))
        }
    }

    func testContextMaintenanceUpdatesOneDisclosureAndRetainsExpansion() async throws {
        func snapshot(_ status: String, after: Int? = nil, generation: UInt64) throws -> RuntimeSnapshot {
            let value = ContextMaintenanceFixtures.value(status, after: after, committed: status != "failed", error: status == "failed" ? "Summary service unavailable" : nil)
            let turn = ConversationTurn(id: "context-turn", userPrompt: nil, blocks: [
                .system(id: "context-stable", try ContextMaintenanceFixtures.payload(value)),
                .toolGroup(.init(id: "tools", entries: [.tool(.init(callID: "read", toolName: "read_file", args: nil, status: .completed))]))], footer: nil, isLive: true)
            return .init(timeline: [], turns: [turn], generation: generation)
        }
        let model = ToolGroupRenderModel()
        model.snapshot = try snapshot("running", generation: 1)
        let web = try await present(model, width: 600)
        try await wait("document.querySelectorAll('.context-maintenance').length === 1 && !document.querySelector('.context-maintenance').open && !document.querySelector('.context-chip')", in: web)
        try await click(".context-maintenance-summary", in: web)
        try await wait("document.querySelector('.context-maintenance-body') !== null", in: web)
        model.snapshot = try snapshot("pending", generation: 2)
        try await wait("document.querySelector('.context-maintenance').dataset.status === 'pending' && document.querySelector('.context-maintenance').open", in: web)
        model.snapshot = try snapshot("limited", after: 210000, generation: 3)
        try await wait("document.querySelector('.context-maintenance').dataset.status === 'limited' && document.querySelectorAll('.context-maintenance').length === 1", in: web)
        model.snapshot = try snapshot("failed", generation: 4)
        try await wait("document.querySelector('.context-maintenance-body').textContent.includes('Summary service unavailable')", in: web)
        model.snapshot = try snapshot("completed", after: 32390, generation: 5)
        try await wait("document.querySelector('.context-maintenance').dataset.status === 'completed' && document.querySelector('.context-maintenance').open", in: web)
        let geometry = try await web.evaluateJavaScript("""
        (() => { const row=document.querySelector('.context-maintenance-summary'); return {
          title: row.querySelector('.context-maintenance-title').textContent,
          result: row.querySelector('.context-maintenance-result').textContent,
          aligned: Math.abs(row.getBoundingClientRect().left - document.querySelector('.tool-group-summary').getBoundingClientRect().left) < 1,
          oldIcons: /🧹|✂️|📄/.test(row.textContent), background: getComputedStyle(row).backgroundColor }; })()
        """) as? [String: Any]
        XCTAssertEqual(geometry?["title"] as? String, ToolTranscriptText().text("context.title"))
        XCTAssertEqual(geometry?["result"] as? String, "231.6K → 32.4K tokens")
        XCTAssertEqual(geometry?["aligned"] as? Bool, true)
        XCTAssertEqual(geometry?["oldIcons"] as? Bool, false)
        window?.setContentSize(NSSize(width: 360, height: 860))
        window?.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        let fits = try await web.evaluateJavaScript("document.documentElement.scrollWidth <= window.innerWidth") as? Bool
        XCTAssertEqual(fits, true)
        if let tiff = try await web.takeSnapshot(configuration: nil).tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]),
           let path = ProcessInfo.processInfo.environment["TOOL_GROUP_SCREENSHOT_DIR"] {
            try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("context-maintenance-macos.png"))
        }
    }

    func testCommandHeaderMasksOnlyCredentialValuesAndShowsNormalDevelopmentCommands() async throws {
        let model = ToolGroupRenderModel()
        let secret = "curl -H 'Authorization: Bearer private-value' https://example.test"
        let safe = "curl -H 'Authorization: Bearer ••••••' https://example.test"
        model.snapshot = snapshot(live: false, count: 1, output: "ok", command: secret)
        let web = try await present(model, width: 600)
        try await click(".tool-group-summary", in: web)
        try await wait("document.querySelector('.tool-summary') !== null", in: web)
        try await click(".tool-summary", in: web)
        try await wait("document.querySelector('.tool-command-text') !== null", in: web)
        let header = try await web.evaluateJavaScript("""
        (() => ({ text: document.querySelector('.tool-command-text').textContent,
          note: document.querySelector('.tool-input-preview-label')?.textContent,
          leaks: document.body.innerText.includes('private-value'),
          copy: !!document.querySelector('[data-focus-id="tool-input-copy:cmd-0"]') }))()
        """) as? [String: Any]
        XCTAssertEqual(header?["text"] as? String, safe)
        XCTAssertEqual(header?["note"] as? String, ToolTranscriptText().text("desktop.sensitiveValuesHidden"))
        XCTAssertEqual(header?["leaks"] as? Bool, false)
        XCTAssertEqual(header?["copy"] as? Bool, true)
        if let tiff = try await web.takeSnapshot(configuration: nil).tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]),
           let path = ProcessInfo.processInfo.environment["TOOL_GROUP_SCREENSHOT_DIR"] {
            try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("command-redaction-macos.png"))
        }
        for (index, command) in ["rg \"beforeTokens\" Sources", "CLANG_MODULE_CACHE_PATH=/tmp/module-cache swift test"].enumerated() {
            model.snapshot = snapshot(live: false, count: 1, output: "ok", generation: UInt64(index + 2), command: command)
            try await wait("document.querySelector('.tool-command-text')?.textContent === \(String(data: try JSONEncoder().encode(command), encoding: .utf8)!) && document.querySelector('.tool-input-preview-label') === null", in: web)
        }
        let staysOpen = try await web.evaluateJavaScript("document.querySelector('.tool-group').open && document.querySelector('.tool').open") as? Bool
        XCTAssertEqual(staysOpen, true)
    }

    func testLongGroupAndOutputKeepDisclosureAcrossStreamingAndCompletion() async throws {
        let output = (1...100).map { "Test Case GroupTests.testState\($0) passed." }.joined(separator: "\n")
        let model = ToolGroupRenderModel()
        model.snapshot = snapshot(live: true, output: output)
        let web = try await present(model)
        try await wait("!document.querySelector('.tool-group').open && document.querySelector('.turn-process') === null", in: web)
        try await click(".tool-group-summary", in: web)
        try await wait("document.querySelectorAll('.tool-summary').length === 40 && document.querySelector('.tool[open]') === null", in: web)
        try await click(".tool-summary", in: web)
        try await wait("document.querySelector('.tool-output-frame') !== null", in: web)
        let layout = try await web.evaluateJavaScript("""
        (() => {
          const group = document.querySelector('.tool-group-tools');
          const output = document.querySelector('.tool-output-frame');
          const command = document.querySelector('.tool-command-text');
          return { groupScrolls: group.scrollHeight > group.clientHeight + 2,
            outputScrolls: output.scrollHeight > output.clientHeight,
            separate: !output.contains(command), height: output.clientHeight,
            icons: group.querySelectorAll('.tool-action-icon').length,
            copyInput: !!document.querySelector('[data-focus-id="tool-input-copy:cmd-0"]') };
        })()
        """) as? [String: Any]
        XCTAssertEqual(layout?["groupScrolls"] as? Bool, false)
        XCTAssertEqual(layout?["outputScrolls"] as? Bool, true)
        XCTAssertEqual(layout?["separate"] as? Bool, true)
        XCTAssertEqual(layout?["height"] as? Int, 280, "desktop long output uses the configured readable viewport")
        XCTAssertEqual(layout?["icons"] as? Int, 0)
        XCTAssertEqual(layout?["copyInput"] as? Bool, true)
        _ = try await web.evaluateJavaScript("document.querySelector('.tool-output-frame').scrollTop = 120")
        model.snapshot = snapshot(live: true, count: 41, output: output + "\nAnother line", generation: 2)
        try await wait("document.querySelectorAll('.tool-summary').length === 41", in: web)
        model.snapshot = snapshot(live: false, count: 41, output: output + "\nFinished", generation: 3)
        try await wait("document.querySelector('.tool-group').dataset.status === 'completed'", in: web)
        try await wait("document.querySelector('.tool-group').open && document.querySelector('.tool').open && document.querySelector('.tool-output-frame').scrollTop === 120 && !document.querySelector('.turn-process')", in: web)

        // Capture the real bundled WebKit view for visual acceptance.
        _ = try await web.evaluateJavaScript("document.querySelector('.tool-group-summary').scrollIntoView({block:'start'});document.querySelector('.tool-output-frame').scrollTop = 0")
        let config = WKSnapshotConfiguration()
        config.rect = web.bounds
        let image = try await web.takeSnapshot(configuration: config)
        if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
            let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TOOL_GROUP_SCREENSHOT_DIR"] ?? NSTemporaryDirectory())
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: dir.appendingPathComponent("tool-group-macos.png"))
        }
    }

    func testEmptyOutputTransitionsWithoutReopeningAndFailureIsVisible() async throws {
        let model = ToolGroupRenderModel()
        model.snapshot = snapshot(live: true, count: 1, output: "")
        let web = try await present(model)
        try await click(".tool-group-summary", in: web)
        try await wait("document.querySelector('.tool-summary') !== null", in: web)
        try await click(".tool-summary", in: web)
        try await wait("document.querySelector('.tool').open", in: web)
        let hasNoEmptyFrame = try await web.evaluateJavaScript("document.querySelector('.tool-output-frame') === null && document.querySelector('.tool-empty-output') === null") as? Bool
        XCTAssertEqual(hasNoEmptyFrame, true)
        model.snapshot = snapshot(live: false, count: 1, output: "", generation: 2)
        try await wait("document.querySelector('.tool-empty-output') !== null && document.querySelector('.tool').open", in: web)
        try await click(".tool-group-summary", in: web)
        try await wait("!document.querySelector('.tool-group').open", in: web)
        model.snapshot = snapshot(live: false, count: 1, output: "", failed: true, generation: 3)
        try await wait("document.querySelector('.tool-group').dataset.status === 'failed' && !document.querySelector('.tool-group').open && document.querySelector('.tool-group-summary [data-tone=failed]') !== null", in: web)
        try await click(".tool-group-summary", in: web)
        try await wait("document.querySelector('.tool').open && document.querySelector('.tool-empty-output') !== null", in: web)
    }
    func testThinkingMatchesToolRowsAndLongCommandScrollsWithoutRawDetails() async throws {
        let command = (1...400).map { "printf 'command line \($0)\\n'" }.joined(separator: "\n")
        let output = (1...60).map { "output \($0)" }.joined(separator: "\n")
        let model = ToolGroupRenderModel()
        model.snapshot = snapshot(live: true, count: 2, output: output, command: command, thinking: true)
        let web = try await present(model)
        let groupInset = try await web.evaluateJavaScript("""
        (() => {
          const header = document.querySelector('.tool-group-summary');
          header.querySelector('.tool-group-running').style.animation = 'none';
          return [getComputedStyle(header).paddingLeft, getComputedStyle(header).paddingRight,
            header.querySelector('.tool-group-running').getBoundingClientRect().left - header.getBoundingClientRect().left,
            header.querySelector('.tool-group-running').getBoundingClientRect().right - header.querySelector('.tool-group-title').getBoundingClientRect().left];
        })()
        """) as? [Any]
        XCTAssertEqual(groupInset?[0] as? String, "0px")
        XCTAssertEqual(groupInset?[1] as? String, "0px")
        XCTAssertEqual(groupInset?[2] as? Double ?? -1, 0, accuracy: 0.5)
        XCTAssertEqual(groupInset?[3] as? Double ?? 999, -6, accuracy: 0.5, "running indicator occupies inline space before the title")
        try await click(".tool-group-summary", in: web)
        try await wait("document.querySelector('.thinking-summary') !== null", in: web)
        let row = try await web.evaluateJavaScript("""
        (() => {
          const thought = document.querySelector('.thinking-summary');
          const label = thought.querySelector('.thinking-label');
          const toolLabel = document.querySelector('.tool-title');
          return { icons: thought.querySelectorAll('.tool-action-icon').length,
            aligned: Math.abs(label.getBoundingClientRect().left - toolLabel.getBoundingClientRect().left) < .5,
            gap: thought.querySelector('.disclosure-chevron').getBoundingClientRect().left - label.getBoundingClientRect().right,
            open: thought.parentElement.open };
        })()
        """) as? [String: Any]
        XCTAssertEqual(row?["icons"] as? Int, 0)
        XCTAssertEqual(row?["aligned"] as? Bool, true)
        XCTAssertLessThan(row?["gap"] as? Double ?? 999, 10)
        XCTAssertEqual(row?["open"] as? Bool, false)
        try await click(".thinking-summary", in: web)
        try await click("[data-tool-id=\"cmd-0\"] > summary", in: web)
        try await wait("document.querySelector('.tool-input-scroll') !== null && document.querySelector('.thinking-block').open", in: web)
        let header = try await web.evaluateJavaScript("""
        (() => {
          const input = document.querySelector('.tool-input-scroll');
          const output = document.querySelector('.tool-output-frame');
          const before = window.scrollY;
          input.scrollTop = 100;
          return { height: input.clientHeight, scrolls: input.scrollHeight > input.clientHeight,
            command: input.querySelector('pre').textContent,
            independent: !input.contains(output) && !output.contains(input),
            copiedOutside: !input.contains(document.querySelector('[data-focus-id="tool-input-copy:cmd-0"]')),
            scrollTop: input.scrollTop, pageUnchanged: window.scrollY === before,
            raw: document.querySelectorAll('.tool-raw-details').length };
        })()
        """) as? [String: Any]
        XCTAssertEqual(header?["height"] as? Int, 160)
        XCTAssertEqual(header?["scrolls"] as? Bool, true)
        XCTAssertEqual(header?["command"] as? String, command)
        XCTAssertEqual(header?["independent"] as? Bool, true)
        XCTAssertEqual(header?["copiedOutside"] as? Bool, true)
        XCTAssertEqual(header?["scrollTop"] as? Int, 100)
        XCTAssertEqual(header?["pageUnchanged"] as? Bool, true)
        XCTAssertEqual(header?["raw"] as? Int, 0)
        try await wait("document.querySelector('.thinking-body')?.textContent.includes('呈现规则') === true", in: web)
        _ = try await web.evaluateJavaScript("document.querySelector('.tool-group-summary').scrollIntoView({block:'start'})")
        let image = try await web.takeSnapshot(configuration: nil)
        if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]),
           let path = ProcessInfo.processInfo.environment["TOOL_GROUP_SCREENSHOT_DIR"] {
            try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("tool-group-macos-review2.png"))
        }
        model.snapshot = snapshot(live: false, count: 2, output: output, generation: 2, command: "pwd", thinking: true)
        try await wait("document.querySelector('.tool-command-text')?.textContent === 'pwd'", in: web)
        let short = try await web.evaluateJavaScript("(() => { const input = document.querySelector('.tool-input-scroll'); return input.clientHeight < 160 && input.scrollHeight <= input.clientHeight + 1; })()") as? Bool
        XCTAssertEqual(short, true, "short headers keep their natural height")
    }

    func testWrappedChinesePathCommandStaysInsideHeaderBackground() async throws {
        let command = #"find "ipa/苹果iOS2.2.ipa/Payload" -maxdepth 3 | head -30; du -sh "ipa/苹果iOS2.2.ipa""#
        let model = ToolGroupRenderModel()
        model.snapshot = snapshot(live: false, count: 1, output: "", command: command, assets: [.init(id: "ipa-folder", kind: "directory", displayName: "ipa", workspaceRelativePath: "ipa/")])
        let web = try await present(model, width: 490)
        try await click(".tool-group-summary", in: web)
        try await wait("document.querySelector('.tool-summary') !== null", in: web)
        try await click(".tool-summary", in: web)
        try await wait("document.querySelector('.tool-input-scroll') !== null", in: web)
        let geometry = try await web.evaluateJavaScript("""
        (() => {
          const panel = document.querySelector('.tool-input-panel');
          const scroll = panel.querySelector('.tool-input-scroll');
          const pre = panel.querySelector('pre');
          const code = pre.querySelector('code');
          const range = document.createRange(); range.selectNodeContents(code);
          const ink = range.getBoundingClientRect();
          return { text: code.textContent, links: code.querySelectorAll('a').length,
            inkTop: ink.top, inkBottom: ink.bottom, panelTop: panel.getBoundingClientRect().top,
            panelBottom: panel.getBoundingClientRect().bottom, preBottom: pre.getBoundingClientRect().bottom,
            height: scroll.clientHeight, scrollHeight: scroll.scrollHeight, lineHeight: parseFloat(getComputedStyle(pre).lineHeight),
            preHeight: pre.getBoundingClientRect().height };
        })()
        """) as? [String: Any]
        XCTAssertEqual(geometry?["text"] as? String, command)
        XCTAssertGreaterThan(geometry?["links"] as? Int ?? 0, 0)
        XCTAssertGreaterThan(geometry?["preHeight"] as? Double ?? 0, (geometry?["lineHeight"] as? Double ?? 1) * 2.5)
        XCTAssertLessThanOrEqual(geometry?["inkBottom"] as? Double ?? 9999, (geometry?["preBottom"] as? Double ?? 0) + 1)
        XCTAssertLessThan(geometry?["inkBottom"] as? Double ?? 9999, (geometry?["panelBottom"] as? Double ?? 0) - 5)
        XCTAssertEqual(geometry?["height"] as? Int, geometry?["scrollHeight"] as? Int, "three wrapped lines fit naturally without a scroller")
        for fontSize in [13, 15, 17] {
            _ = try await web.evaluateJavaScript("document.documentElement.style.setProperty('--font-code', '\(fontSize)px')")
            for width in [CGFloat(720), 440, 600, 490] {
                window?.setContentSize(NSSize(width: width, height: 860))
                window?.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(80))
                let bounds = try await web.evaluateJavaScript("""
                (() => {
                  const panel = document.querySelector('.tool-input-panel');
                  const input = panel.querySelector('.tool-input-scroll');
                  input.scrollTop = input.scrollHeight;
                  const code = input.querySelector('code');
                  const walker = document.createTreeWalker(code, NodeFilter.SHOW_TEXT);
                  let last, node; while ((node = walker.nextNode())) last = node;
                  const tail = document.createRange();
                  tail.setStart(last, Math.max(0, last.length - 10)); tail.setEnd(last, last.length);
                  return { tailBottom: tail.getBoundingClientRect().bottom,
                    viewportBottom: input.getBoundingClientRect().bottom,
                    panelBottom: panel.getBoundingClientRect().bottom,
                    capped: input.scrollHeight > input.clientHeight + 1,
                    height: input.clientHeight, preHeight: input.querySelector('pre').getBoundingClientRect().height };
                })()
                """) as? [String: Any]
                XCTAssertLessThanOrEqual(bounds?["tailBottom"] as? Double ?? 9999, (bounds?["viewportBottom"] as? Double ?? 0) + 1, "last line is visible at width \(width), font \(fontSize)")
                XCTAssertLessThan(bounds?["tailBottom"] as? Double ?? 9999, (bounds?["panelBottom"] as? Double ?? 0) - 5)
                if bounds?["capped"] as? Bool == false {
                    XCTAssertEqual(bounds?["height"] as? Double ?? -1, bounds?["preHeight"] as? Double ?? -99, accuracy: 1)
                }
            }
        }
        _ = try await web.evaluateJavaScript("document.documentElement.style.setProperty('--font-code', '13px'); document.querySelector('.tool-input-scroll').scrollTop = 0")
        try await Task.sleep(for: .milliseconds(80))
        let image = try await web.takeSnapshot(configuration: nil)
        if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]),
           let path = ProcessInfo.processInfo.environment["TOOL_GROUP_SCREENSHOT_DIR"] {
            try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("tool-command-wrap.png"))
        }

    }

}
#endif
