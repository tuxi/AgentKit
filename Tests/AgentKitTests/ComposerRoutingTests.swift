import XCTest
@testable import AgentKit

@MainActor
final class ComposerRoutingTests: XCTestCase {
    func testDefaultDisplayModelIsFrozenIntoSendWithoutPinningPreference() async throws {
        let state = InMemoryConversationLocalStateStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let store = WorkspaceStore(usesEmbeddedRuntime: false, localStateStore: state, recentWorkspaces: RecentWorkspacesStore(defaults: defaults), projects: ProjectsStore(root: nil))
        store.beginDraft()
        let settings = ModelSettingsStore(defaults: defaults, localStateStore: state)
        let first = UnifiedModelDescriptor(serverConnectionID: "daemon", connectionID: "opencode-go", providerID: "opencode-go", providerDisplayName: "Go", runtimeAlias: "deepseek-flash", wireModelID: "deepseek-flash", displayName: "deepseek-flash", contextWindow: 100000, supportsTools: true, supportsReasoning: true, inputModalities: [.text, .image], billingSource: "test")
        let second = UnifiedModelDescriptor(serverConnectionID: "daemon", connectionID: "openrouter", providerID: "openrouter", providerDisplayName: "OpenRouter", runtimeAlias: "free", wireModelID: "free", displayName: "free", contextWindow: 100000, supportsTools: true, supportsReasoning: false, inputModalities: [.text], billingSource: "test")
        settings.applyUnifiedCatalog([first, second], defaultModelID: first.id)
        let sent = expectation(description: "submitted")
        var captured: UnifiedModel?
        let vm = DraftComposerPanelViewModel(workspaceStore: store, modelSettings: settings, conversationViewModel: nil, isDraft: true, isEnabled: true, onSend: { _, model, _ in captured = model; sent.fulfill(); return false })
        vm.restoreLocalState()
        vm.text = "检查附件"
        XCTAssertEqual(vm.selectionMode, .followDefault)
        XCTAssertFalse(vm.imagesAsPaths)
        XCTAssertEqual(vm.submissionModel?.model, "opencode-go/deepseek-flash")
        vm.send()
        // A directory refresh after clicking Send cannot change this request.
        settings.applyUnifiedCatalog([first, second], defaultModelID: second.id)
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(captured?.model, "opencode-go/deepseek-flash")
        XCTAssertEqual(vm.selectionMode, .followDefault)
        XCTAssertTrue(vm.imagesAsPaths)
        XCTAssertEqual(vm.submissionModel?.model, "openrouter/free")
        let saved = try XCTUnwrap(state.state(for: .draft(try XCTUnwrap(store.draft?.id))))
        XCTAssertEqual(saved.modelSelectionMode, .followDefault)
        XCTAssertNil(saved.selectedModelID)
    }

    func testSelectedFileAuthorizationDoesNotGrantSiblingsOrSymlinkEscapes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let selected = root.appendingPathComponent("selected", isDirectory: true)
        let outside = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let allowedFile = selected.appendingPathComponent("movie.m4v")
        let otherFile = outside.appendingPathComponent("other.m4v")
        try Data().write(to: allowedFile); try Data().write(to: otherFile)
        let fileRef = ComposerFileReference(path: allowedFile.path, workspacePath: nil, isDirectory: false)
        XCTAssertTrue(ComposerReferencedFileAccess.allowsRead(allowedFile, workspaceRoot: root, references: [fileRef]))
        XCTAssertFalse(ComposerReferencedFileAccess.allowsRead(otherFile, workspaceRoot: root, references: [fileRef]))
        let directoryRef = ComposerFileReference(path: selected.path, workspacePath: nil, isDirectory: true)
        XCTAssertTrue(ComposerReferencedFileAccess.allowsRead(allowedFile, workspaceRoot: root, references: [directoryRef]))
        let link = selected.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertFalse(ComposerReferencedFileAccess.allowsRead(link.appendingPathComponent("other.m4v"), workspaceRoot: root, references: [directoryRef]))
        XCTAssertFalse(ComposerReferencedFileAccess.allowsRead(allowedFile, workspaceRoot: root, references: []))
    }
}
