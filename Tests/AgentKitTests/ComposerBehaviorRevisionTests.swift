#if os(macOS)
import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import AgentKit

@MainActor
final class ComposerBehaviorRevisionTests: XCTestCase {
    private func fixture() throws -> (WorkspaceStore, ModelSettingsStore, DraftComposerPanelViewModel, ConversationLocalStateKey) {
        let state = InMemoryConversationLocalStateStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let store = WorkspaceStore(usesEmbeddedRuntime: false, localStateStore: state, recentWorkspaces: RecentWorkspacesStore(defaults: defaults), projects: ProjectsStore(root: nil))
        store.beginDraft()
        let models = ModelSettingsStore(defaults: defaults, localStateStore: state)
        let descriptors = [false, true].map { vision in
            UnifiedModelDescriptor(serverConnectionID: nil, connectionID: "test", providerID: "test", providerDisplayName: "Test", runtimeAlias: vision ? "vision" : "text", wireModelID: vision ? "vision" : "text", displayName: vision ? "Vision" : "A very long text model name", contextWindow: 100000, supportsTools: true, supportsReasoning: false, inputModalities: vision ? [.text, .image] : [.text], billingSource: "test")
        }
        models.applyUnifiedCatalog(descriptors, defaultModelID: "text")
        let vm = DraftComposerPanelViewModel(workspaceStore: store, modelSettings: models, conversationViewModel: nil, isDraft: true, isEnabled: true, onSend: { _, _, _ in false })
        vm.restoreLocalState(persistOutgoingText: false)
        return (store, models, vm, .draft(try XCTUnwrap(store.draft?.id)))
    }

    func testInTurnDeliveryRejectsDraftsWithLocalResources() throws {
        let (_, _, vm, _) = try fixture()
        vm.text = "补充文字"
        XCTAssertTrue(vm.canDeliverPlainText)
        vm.fileReferences = [.init(path: "/project/readme.md", workspacePath: "/project", isDirectory: false)]
        XCTAssertFalse(vm.canDeliverPlainText)
        vm.fileReferences = []
        vm.attachments = [.init(id: "image", displayName: "image.png", resourceURI: "file:///project/image.png")]
        XCTAssertFalse(vm.canDeliverPlainText)
    }

    func testNonVisionImagesUsePathsWithoutChangingOriginalAttachments() async throws {
        let (store, _, vm, key) = try fixture()
        vm.text = "这是测试"
        vm.attachments = [DraftAttachmentReference(id: UUID().uuidString, displayName: "image.png", resourceURI: "file:///outside/image.png")]
        vm.fileReferences = [ComposerFileReference(path: "/outside/readme.md", workspacePath: nil, isDirectory: false)]
        vm.persistCurrentDraft()
        XCTAssertTrue(vm.imagesAsPaths)
        XCTAssertNil(vm.imageInputIssue)
        XCTAssertTrue(vm.canSend)
        XCTAssertEqual(vm.submissionFileReferences.map(\.path), ["/outside/readme.md", "/outside/image.png"])
        let payload = try await store.prepareUserAssets(for: key, workspaceRoot: URL(fileURLWithPath: "/project"))
        XCTAssertTrue(payload.assets.isEmpty)
        XCTAssertTrue(payload.localAssets.isEmpty, "non-vision requests must not carry image content")
        let text = ComposerMessageContent.modelText(text: vm.text, files: vm.submissionFileReferences, tokens: vm.tokens)
        let pending = try store.localStateStore.markSubmissionPending(key: key, input: .text(text, requestID: "r"))
        XCTAssertEqual(pending.attachmentIDs, vm.attachments.map(\.id))
        XCTAssertEqual(pending.presentation?.fileReferences.count, 2)
        try store.localStateStore.rejectSubmission(key: key, requestID: "r")
        vm.selectModel("vision", reasoningEffort: nil)
        XCTAssertFalse(vm.imagesAsPaths)
        XCTAssertEqual(vm.submissionFileReferences.count, 1)
        XCTAssertEqual(vm.attachments.count, 1, "switching model cannot replace or discard the original image")
        let roundTrip = try JSONDecoder().decode(ComposerDraft.self, from: JSONEncoder().encode(try XCTUnwrap(store.localStateStore.state(for: key)?.composerDraft)))
        XCTAssertEqual(roundTrip.attachments.count, 1)
    }

    func testAcceptanceDoesNotResurrectSubmittedFilesOrRemoveNextDraft() async throws {
        let (store, _, vm, key) = try fixture()
        let submitted = ComposerFileReference(path: "/outside/first.md", workspacePath: nil, isDirectory: false)
        let next = ComposerFileReference(path: "/outside/next.md", workspacePath: nil, isDirectory: false)
        vm.text = "第一条"; vm.fileReferences = [submitted]; vm.persistCurrentText()
        let payload = ComposerMessageContent.modelText(text: vm.text, files: vm.fileReferences, tokens: [])
        _ = try store.localStateStore.markSubmissionPending(key: key, input: .text(payload, requestID: "r"))
        vm.restoreLocalState(persistOutgoingText: false)
        // A newer draft must survive acceptance of the immutable first one.
        vm.text = "下一条"; vm.fileReferences.append(next); vm.persistCurrentText()
        try store.localStateStore.acceptSubmission(key: key, requestID: "r", turnID: "t")
        vm.reconcileAcceptedSubmission()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(vm.fileReferences, [next])
        XCTAssertEqual(vm.text, "下一条")
        XCTAssertEqual(try store.localStateStore.state(for: key)?.composerDraft.fileReferences, [next])
        vm.persistCurrentText()
        XCTAssertFalse(try XCTUnwrap(store.localStateStore.state(for: key)).composerDraft.fileReferences.contains(submitted))
    }

    func testAcceptanceClearsEverySubmittedAttachmentFromEditor() async throws {
        let (store, _, vm, key) = try fixture()
        vm.text = "发送五个项目"
        vm.attachments = (0..<2).map { DraftAttachmentReference(id: UUID().uuidString, displayName: "image-\($0).png", resourceURI: "file:///outside/image-\($0).png") }
        vm.fileReferences = (0..<3).map { ComposerFileReference(path: "/outside/file-\($0).md", workspacePath: nil, isDirectory: false) }
        vm.persistCurrentDraft()
        let text = ComposerMessageContent.modelText(text: vm.text, files: vm.submissionFileReferences, tokens: [])
        _ = try store.localStateStore.markSubmissionPending(key: key, input: .text(text, requestID: "r"))
        vm.restoreLocalState(persistOutgoingText: false)
        try store.localStateStore.acceptSubmission(key: key, requestID: "r", turnID: "t")
        vm.reconcileAcceptedSubmission()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(vm.text.isEmpty)
        XCTAssertTrue(vm.attachments.isEmpty)
        XCTAssertTrue(vm.fileReferences.isEmpty)
        let saved = try XCTUnwrap(store.localStateStore.state(for: key))
        XCTAssertTrue(saved.composerDraft.fileReferences.isEmpty)
        XCTAssertTrue(saved.composerDraft.attachments.isEmpty)
        XCTAssertEqual(saved.composerMessages["t"]?.fileReferences.count, 5)
    }

    func testNarrowComposerFooterStaysOneRowWithLongNames() throws {
        let (store, _, vm, _) = try fixture()
        store.selectWorkspace(Workspace(url: URL(fileURLWithPath: "/tmp/A-very-long-workspace-name-for-a-narrow-window", isDirectory: true)))
        for width: CGFloat in [360, 480, 728] {
            vm.contentWidth = width
            let host = NSHostingView(rootView: MacComposerSurface(vm: vm, placeholder: "描述任务").environment(store).frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: .aqua)
            let size = host.fittingSize
            XCTAssertLessThanOrEqual(size.height, 90, "footer must not add a second row at width \(width)")
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            if let target = ProcessInfo.processInfo.environment["COMPOSER_SNAPSHOTS"], let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: target).appendingPathComponent("footer-\(Int(width)).png"))
            }
        }
    }

    func testMixedHistoryAttachmentsShareOneScrollableRow() async throws {
        let ready = expectation(description: "ready")
        let ack = expectation(description: "ack")
        let probe = ComposerRevisionProbe(ready: ready, ack: ack)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(ConversationWebSchemeHandler(), forURLScheme: ConversationWebSchemeHandler.scheme)
        config.userContentController.add(probe, name: "agentkitWorkbench")
        let web = WKWebView(frame: .init(x: 0, y: 0, width: 480, height: 260), configuration: config)
        web.load(URLRequest(url: ConversationWebSchemeHandler.indexURL))
        await fulfillment(of: [ready], timeout: 5)
        let files = (0..<3).map { ComposerFileReference(path: "/outside/file-\($0).md", workspacePath: nil, isDirectory: false) }
        let localImages = (0..<2).map { index in
            LocalUserAssetRef(id: UUID().uuidString, relativePath: ".codeagent/image-\(index).png", filename: "image-\(index).png", mimeType: "image/png", kind: "image", sizeBytes: 42, sha256: String(repeating: "a", count: 64))
        }
        let modelText = ComposerMessageContent.modelText(text: "测试", files: files, tokens: [])
        let turn = ConversationTurn(id: "turn_t_user", userPrompt: .init(role: .user, text: modelText, localAssets: localImages), blocks: [], footer: nil, isLive: false)
        let doc = ConversationWebDocumentBuilder.build(snapshot: .init(timeline: [], turns: [turn]), composerPresentations: ["t": .init(text: "测试", fileReferences: files, modelText: modelText)], conversationID: "s", revision: 1)
        let payload = try JSONEncoder().encode(ConversationWebDocumentDiffer.reset(doc)).base64EncodedString()
        _ = try await web.evaluateJavaScript("window.AgentKitWorkbench.applyUpdateBase64('\(payload)')")
        await fulfillment(of: [ack], timeout: 5)
        let result = try await web.evaluateJavaScript("""
        (() => {
          const rows = document.querySelectorAll('.user-asset-strip');
          const row = rows[0];
          const tops = [...row.children].map(item => item.getBoundingClientRect().top);
          row.scrollLeft = 150;
          return {rows: rows.length, count: row.children.length, sameTop: tops.every(top => Math.abs(top - tops[0]) < 1), scroll: row.scrollLeft, privacyLines: document.querySelectorAll('.local-asset-privacy-label').length};
        })()
        """) as? [String: Any]
        XCTAssertEqual(result?["rows"] as? Int, 1)
        XCTAssertEqual(result?["count"] as? Int, 5)
        XCTAssertEqual(result?["sameTop"] as? Bool, true)
        XCTAssertGreaterThan(result?["scroll"] as? Int ?? 0, 0)
        XCTAssertEqual(result?["privacyLines"] as? Int, 0)
        if let target = ProcessInfo.processInfo.environment["COMPOSER_SNAPSHOTS"] {
            _ = try await web.evaluateJavaScript("document.querySelector('.user-asset-strip').scrollLeft = 0")
            let image = try await web.takeSnapshot(configuration: nil)
            if let data = image.tiffRepresentation, let rep = NSBitmapImageRep(data: data) {
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: target).appendingPathComponent("history-single-row.png"))
            }
        }
        config.userContentController.removeScriptMessageHandler(forName: "agentkitWorkbench")
    }
}

@MainActor
private final class ComposerRevisionProbe: NSObject, WKScriptMessageHandler {
    let ready: XCTestExpectation
    let ack: XCTestExpectation
    init(ready: XCTestExpectation, ack: XCTestExpectation) { self.ready = ready; self.ack = ack }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "ready" { ready.fulfill() }
        if type == "ack", body["revision"] as? Int == 1 { ack.fulfill() }
    }
}
#endif
