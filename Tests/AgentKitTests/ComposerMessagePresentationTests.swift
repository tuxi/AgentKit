import XCTest
@testable import AgentKit
#if os(macOS)
import WebKit
#endif

@MainActor
final class ComposerMessagePresentationTests: XCTestCase {
    private func files() -> [ComposerFileReference] {
        [ComposerFileReference(path: "/outside/ui-evidence", workspacePath: nil, isDirectory: true),
         ComposerFileReference(path: "/outside/ui-evidence/资料 \"a\"\n.json", workspacePath: nil, isDirectory: false)]
    }

    func testModelPathsHaveTypesAndRoundTripWithoutEscapedSlashes() throws {
        let refs = files()
        let text = ComposerMessageContent.modelText(text: "你好啊", files: refs, tokens: [])
        XCTAssertTrue(text.hasPrefix("你好啊\n\n引用的本地路径（按需读取）：\n- 目录："))
        XCTAssertFalse(text.contains("\\/"))
        XCTAssertFalse(text.contains("\\-"))
        let lines = text.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertEqual(lines.count, 2, "a newline in a path cannot inject another reference entry")
        for (line, file) in zip(lines, refs) {
            let quoted = try XCTUnwrap(line.components(separatedBy: "：").last)
            XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(quoted.utf8)), file.path)
        }
        XCTAssertTrue(ComposerMessageContent.modelText(text: "", files: refs, tokens: []).hasPrefix("引用的本地路径"))
    }

    func testAcceptedPresentationSurvivesPendingAndSQLiteReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.sqlite")
        let store = SQLiteConversationLocalStateStore(databaseURL: url)
        let key = ConversationLocalStateKey.session("s")
        let refs = files()
        try store.updateState(for: key) { $0.composerDraft = ComposerDraft(text: "你好啊"); $0.composerDraft.fileReferences = refs }
        let payload = ComposerMessageContent.modelText(text: "你好啊", files: refs, tokens: [])
        _ = try store.markSubmissionPending(key: key, input: .text(payload, requestID: "r1"))
        let reopened = SQLiteConversationLocalStateStore(databaseURL: url)
        XCTAssertEqual(try reopened.state(for: key)?.composerDraft.pendingSubmission?.presentation?.fileReferences, refs)
        XCTAssertEqual(try reopened.state(for: key)?.composerMessages, [:])
        try reopened.acceptSubmission(key: key, requestID: "wrong", turnID: "unrelated")
        XCTAssertEqual(try reopened.state(for: key)?.composerMessages, [:])
        try reopened.acceptSubmission(key: key, requestID: "r1", turnID: "t1")
        let final = SQLiteConversationLocalStateStore(databaseURL: url)
        let presentation = try XCTUnwrap(final.state(for: key)?.composerMessages["t1"])
        XCTAssertEqual(presentation.text, "你好啊")
        XCTAssertEqual(presentation.fileReferences, refs)
        XCTAssertTrue(presentation.matches(payload))
        XCTAssertNil(try final.state(for: key)?.composerDraft.pendingSubmission)
    }

    func testRejectedOrUnrelatedInputCannotCreateHistoryPresentation() throws {
        let store = InMemoryConversationLocalStateStore()
        let key = ConversationLocalStateKey.session("s")
        let refs = files()
        try store.updateState(for: key) { $0.composerDraft.fileReferences = refs; $0.composerDraft.text = "你好" }
        _ = try store.markSubmissionPending(key: key, input: .text("programmatic input", requestID: "r"))
        XCTAssertNil(try store.state(for: key)?.composerDraft.pendingSubmission?.presentation)
        try store.rejectSubmission(key: key, requestID: "r")
        XCTAssertEqual(try store.state(for: key)?.composerMessages, [:])
        XCTAssertEqual(try store.state(for: key)?.composerDraft.fileReferences, refs)
        XCTAssertEqual(try JSONDecoder().decode(ConversationLocalState.self, from: Data("{}".utf8)).composerMessages, [:])
    }

    func testHistoryUsesBodyAndCardsOnlyForMatchingAcceptedTurnAndPayload() throws {
        let refs = files()
        let payload = ComposerMessageContent.modelText(text: "你好啊", files: refs, tokens: [])
        let presentation = ComposerMessagePresentation(text: "你好啊", fileReferences: refs, modelText: payload)
        let turn = ConversationTurn(id: "turn_t1_user", userPrompt: .init(role: .user, text: payload), blocks: [], footer: nil, isLive: false, contentVersion: 1)
        let snapshot = RuntimeSnapshot(timeline: [], turns: [turn])
        let raw = ConversationWebDocumentBuilder.build(snapshot: snapshot, conversationID: "s", revision: 1)
        let result = ConversationWebDocumentBuilder.buildWithStableTurns(snapshot: snapshot, composerPresentations: ["t1": presentation], conversationID: "s", revision: 2, reusing: .init(snapshot: snapshot, document: raw, extensionContributions: [:]))
        XCTAssertEqual(result.document.turns[0].userPrompt, "你好啊")
        XCTAssertEqual(result.document.turns[0].fileReferences, refs)
        XCTAssertTrue(result.stableTurnIDs.isEmpty, "late acceptance metadata must invalidate the raw user message")
        XCTAssertNotNil(ConversationWebDocumentDiffer.update(from: raw, to: result.document, stableTurnIDs: result.stableTurnIDs))
        let stable = ConversationWebDocumentBuilder.buildWithStableTurns(snapshot: snapshot, composerPresentations: ["t1": presentation], conversationID: "s", revision: 3, reusing: .init(snapshot: snapshot, document: result.document, extensionContributions: [:]))
        XCTAssertEqual(stable.stableTurnIDs, [turn.id])
        XCTAssertEqual(snapshot.turns[0].userPrompt?.text, payload, "provider/history input remains intact")
        let wrongTurn = ConversationWebDocumentBuilder.build(snapshot: snapshot, composerPresentations: ["different": presentation], conversationID: "s")
        XCTAssertEqual(wrongTurn.turns[0].userPrompt, payload)
        let mismatch = ComposerMessagePresentation(text: "你好啊", fileReferences: refs, modelText: "different payload")
        let wrongPayload = ConversationWebDocumentBuilder.build(snapshot: snapshot, composerPresentations: ["t1": mismatch], conversationID: "s", reusing: .init(snapshot: snapshot, document: result.document, extensionContributions: [:]))
        XCTAssertEqual(wrongPayload.turns[0].userPrompt, payload)
        XCTAssertNil(wrongPayload.turns[0].fileReferences)
    }

#if os(macOS)
    func testBundledRendererShowsFileCardsAndOnlyOriginalBody() async throws {
        let ready = expectation(description: "ready")
        let applied = expectation(description: "applied")
        let probe = ComposerMessageWebProbe(ready: ready, applied: applied)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(ConversationWebSchemeHandler(), forURLScheme: ConversationWebSchemeHandler.scheme)
        config.userContentController.add(probe, name: "agentkitWorkbench")
        let web = WKWebView(frame: .init(x: 0, y: 0, width: 760, height: 500), configuration: config)
        web.load(URLRequest(url: ConversationWebSchemeHandler.indexURL))
        await fulfillment(of: [ready], timeout: 5)
        let refs = files()
        let payload = ComposerMessageContent.modelText(text: "你好啊", files: refs, tokens: [])
        let turn = ConversationTurn(id: "turn_t1_user", userPrompt: .init(role: .user, text: payload), blocks: [], footer: nil, isLive: false)
        let doc = ConversationWebDocumentBuilder.build(snapshot: .init(timeline: [], turns: [turn]), composerPresentations: ["t1": .init(text: "你好啊", fileReferences: refs, modelText: payload)], conversationID: "s", revision: 1)
        let encoded = try JSONEncoder().encode(ConversationWebDocumentDiffer.reset(doc)).base64EncodedString()
        _ = try await web.evaluateJavaScript("window.AgentKitWorkbench.applyUpdateBase64('\(encoded)')")
        await fulfillment(of: [applied], timeout: 5)
        let data = try await web.evaluateJavaScript("({body: document.querySelector('.user-prompt')?.textContent, cards: document.querySelectorAll('.user-file-reference').length, type: document.querySelector('.user-file-reference-kind')?.textContent, title: document.querySelector('.user-file-reference')?.title})") as? [String: Any]
        XCTAssertEqual(data?["body"] as? String, "你好啊")
        XCTAssertEqual(data?["cards"] as? Int, 2)
        XCTAssertEqual(data?["type"] as? String, "目录")
        XCTAssertEqual(data?["title"] as? String, refs[0].path)
        if let target = ProcessInfo.processInfo.environment["COMPOSER_SNAPSHOTS"] {
            let image = try await web.takeSnapshot(configuration: nil)
            if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) {
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: target).appendingPathComponent("composer-history.png"))
            }
        }
        config.userContentController.removeScriptMessageHandler(forName: "agentkitWorkbench")
    }
#endif
}

#if os(macOS)
@MainActor
private final class ComposerMessageWebProbe: NSObject, WKScriptMessageHandler {
    let ready: XCTestExpectation
    let applied: XCTestExpectation
    init(ready: XCTestExpectation, applied: XCTestExpectation) { self.ready = ready; self.applied = applied }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "ready" { ready.fulfill() }
        if type == "ack" || type == "applied" { applied.fulfill() }
    }
}
#endif
