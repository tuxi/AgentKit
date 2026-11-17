import XCTest
@testable import AgentKit
#if os(macOS)
import SwiftUI
import AppKit
#endif

final class MacComposerPersistenceTests: XCTestCase {
    private func item() throws -> ComposerCompletionItem {
        try JSONDecoder().decode(ComposerCompletionItem.self, from: Data(#"{"id":"file:readme","kind":"file","label":"README.md","detail":"README.md","insert_text":"\"README.md\"","action":"insert","relative_path":"README.md"}"#.utf8))
    }

    func testTokensAndFileReferencesSurviveMigrationAndOldDraftsDecode() throws {
        let store = InMemoryConversationLocalStateStore()
        let key = ConversationLocalStateKey.draft(UUID())
        let token = ComposerToken(location: 3, length: 9, item: try item())
        let reference = ComposerFileReference(path: "/project/docs/spec.pdf", workspacePath: "/project", isDirectory: false)
        try store.updateState(for: key) { state in
            state.composerDraft.text = "🙂 README.md"
            state.composerDraft.tokens = [token]
            state.composerDraft.fileReferences = [reference]
        }
        try store.migrateDraft(try XCTUnwrap(key.draftID), to: "new-session")
        let migrated = try XCTUnwrap(store.state(for: .session("new-session")))
        let restored = try JSONDecoder().decode(ComposerDraft.self, from: JSONEncoder().encode(migrated.composerDraft))
        XCTAssertEqual(restored.tokens, [token])
        XCTAssertEqual(restored.fileReferences, [reference])
        XCTAssertEqual(reference.relativePath, "docs/spec.pdf")
        let legacy = try JSONDecoder().decode(ComposerDraft.self, from: Data(#"{"text":"old draft"}"#.utf8))
        XCTAssertTrue(legacy.tokens.isEmpty)
        XCTAssertTrue(legacy.fileReferences.isEmpty)
    }

    func testAcceptedSubmissionRemovesOnlySubmittedFileReferences() throws {
        let store = InMemoryConversationLocalStateStore()
        let key = ConversationLocalStateKey.session("session")
        let first = ComposerFileReference(path: "/project/first.pdf", workspacePath: "/project", isDirectory: false)
        let next = ComposerFileReference(path: "/project/next.zip", workspacePath: "/project", isDirectory: false)
        try store.updateState(for: key) { state in
            state.composerDraft.text = "read"
            state.composerDraft.fileReferences = [first]
        }
        _ = try store.markSubmissionPending(key: key, input: .text("read\n\n引用文件：first.pdf", requestID: "request-1"))
        try store.updateState(for: key) { $0.composerDraft.fileReferences.append(next) }
        try store.acceptSubmission(key: key, requestID: "request-1")
        XCTAssertEqual(try store.state(for: key)?.composerDraft.fileReferences, [next])
        XCTAssertNil(try store.state(for: key)?.composerDraft.pendingSubmission)
        XCTAssertEqual(try store.state(for: key)?.composerDraft.text, "")
    }

    func testUnknownExtensionsAndExternalPathsRemainReferences() {
        let external = ComposerFileReference(path: "/outside/archive.custom", workspacePath: "/project", isDirectory: false)
        XCTAssertNil(external.relativePath)
        XCTAssertEqual(external.typeLabel, "CUSTOM")
        XCTAssertEqual(ComposerFileReference(path: "/project/folder", workspacePath: "/project", isDirectory: true).typeLabel, "FOLDER")
    }
}

#if os(macOS)
@MainActor
final class MacComposerEditorTests: XCTestCase {
    func testLowWindowLayoutKeepsTwoLinesWithoutExceedingInputBudget() {
        for height: CGFloat in [320, 360, 480, 600, 900] {
            for hasIssue in [false, true] {
                let budget = MacComposerLayoutBudget(availableHeight: height, hasAttachments: true, hasIssue: hasIssue)
                XCTAssertGreaterThanOrEqual(budget.editorMaximum, 48)
                XCTAssertLessThanOrEqual(budget.editorMaximum + budget.attachmentHeight + 24 + (hasIssue ? 32 : 0), min(360, height * 0.45))
            }
        }
        XCTAssertTrue(MacComposerLayoutBudget(availableHeight: 320, hasAttachments: true, hasIssue: false).collapseAttachments)
    }

    func testTokenOffsetsUseUTF16WhenEditingBeforeEmojiAndReference() throws {
        let item = try JSONDecoder().decode(ComposerCompletionItem.self, from: Data(#"{"id":"file:1","kind":"file","label":"a.swift","detail":"a.swift","insert_text":"a.swift","action":"insert"}"#.utf8))
        var tokens = [ComposerToken(location: 3, length: 7, item: item)]
        let editor = MacComposerTextView(text: .constant("🙂 a.swift"), height: .constant(24), placeholder: "", isEnabled: true, minHeight: 24, maxHeight: 200, onSend: {}, tokens: Binding(get: { tokens }, set: { tokens = $0 }))
        let coordinator = editor.makeCoordinator()
        let textView = ComposerNSTextView()
        XCTAssertTrue(coordinator.textView(textView, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: "中"))
        XCTAssertEqual(tokens[0].location, 4)
        XCTAssertTrue(coordinator.textView(textView, shouldChangeTextIn: NSRange(location: 6, length: 0), replacementString: "x"))
        XCTAssertTrue(tokens.isEmpty, "Editing inside a reference must remove its identity")
    }

    func testAttachmentRemovalUndoRestoresReferencesWithoutDeletingFiles() throws {
        let states = InMemoryConversationLocalStateStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "composer-undo-" + UUID().uuidString))
        let store = WorkspaceStore(usesEmbeddedRuntime: false, localStateStore: states, recentWorkspaces: RecentWorkspacesStore(defaults: defaults), projects: ProjectsStore(root: nil))
        store.beginDraft()
        let models = ModelSettingsStore(defaults: defaults, localStateStore: states)
        let vm = DraftComposerPanelViewModel(workspaceStore: store, modelSettings: models, conversationViewModel: nil, isDraft: true, isEnabled: true, onSend: { _,_,_ in false })
        vm.restoreLocalState()
        let reference = ComposerFileReference(path: "/project/source.zip", workspacePath: "/project", isDirectory: false)
        vm.fileReferences = [reference]
        let manager = UndoManager()
        manager.beginUndoGrouping()
        vm.removeFileReferenceWithUndo(reference.id, manager: manager)
        manager.endUndoGrouping()
        XCTAssertTrue(vm.fileReferences.isEmpty)
        manager.undo()
        XCTAssertEqual(vm.fileReferences, [reference])
        manager.redo()
        XCTAssertTrue(vm.fileReferences.isEmpty)
        vm.onDisappear()
    }

    func testRestoredPendingSubmissionStaysLockedAndOldCloudDraftBecomesLocal() throws {
        let states = InMemoryConversationLocalStateStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "composer-recovery-" + UUID().uuidString))
        let store = WorkspaceStore(usesEmbeddedRuntime: false, localStateStore: states, recentWorkspaces: RecentWorkspacesStore(defaults: defaults), projects: ProjectsStore(root: nil))
        store.beginDraft()
        let key = ConversationLocalStateKey.draft(try XCTUnwrap(store.draft?.id))
        try states.updateState(for: key) { state in
            state.composerDraft.text = "未发送内容"
            state.composerDraft.attachments = [DraftAttachmentReference(id: UUID().uuidString, displayName: "image.png", resourceURI: "file:///tmp/image.png", delivery: .gateway)]
        }
        let models = ModelSettingsStore(defaults: defaults, localStateStore: states)
        let vm = DraftComposerPanelViewModel(workspaceStore: store, modelSettings: models, conversationViewModel: nil, isDraft: true, isEnabled: true, onSend: { _,_,_ in false })
        vm.restoreLocalState()
        XCTAssertEqual(vm.attachments.first?.delivery, .localOnly)
        XCTAssertTrue(vm.readyAssets.isEmpty)
        XCTAssertFalse(vm.canOfferGatewayUpload(for: try XCTUnwrap(vm.attachments.first)))
        _ = try states.markSubmissionPending(key: key, input: .text("未发送内容", requestID: "pending-input"))
        vm.restoreLocalState(persistOutgoingText: false)
        XCTAssertTrue(vm.hasPendingSubmission)
        XCTAssertTrue(vm.isSubmitting)
        XCTAssertFalse(vm.canSend)
    }

    func testTabAcceptsSuggestionWithoutSendingAndMarkedTextKeepsPriority() throws {
        var text = ""
        var sent = 0
        var dismissed = false
        let editor = MacComposerTextView(text: Binding(get: { text }, set: { text = $0 }), height: .constant(24), placeholder: "普通占位", isEnabled: true, minHeight: 24, maxHeight: 200, onSend: { sent += 1 }, suggestionText: "继续验证输入框", onDismissSuggestion: { dismissed = true })
        let coordinator = editor.makeCoordinator()
        let tv = ComposerNSTextView()
        tv.delegate = coordinator; coordinator.textView = tv
        XCTAssertTrue(coordinator.textView(tv, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(text, "继续验证输入框")
        XCTAssertEqual(sent, 0)
        XCTAssertTrue(dismissed)
        tv.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: 0, length: tv.string.utf16.count))
        XCTAssertTrue(tv.hasMarkedText())
        XCTAssertFalse(coordinator.textView(tv, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(sent, 0)
        tv.unmarkText()
    }

    func testReferenceDeletionAndUndoRestoreItsIdentity() throws {
        let item = try JSONDecoder().decode(ComposerCompletionItem.self, from: Data(#"{"id":"file:1","kind":"file","label":"README.md","detail":"README.md","insert_text":"README.md","action":"insert"}"#.utf8))
        var tokens = [ComposerToken(location: 0, length: 9, item: item)]
        var text = "README.md "
        let editor = MacComposerTextView(text: Binding(get: { text }, set: { text = $0 }), height: .constant(24), placeholder: "", isEnabled: true, minHeight: 24, maxHeight: 200, onSend: {}, tokens: Binding(get: { tokens }, set: { tokens = $0 }))
        let coordinator = editor.makeCoordinator()
        let tv = ComposerNSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        tv.string = text; tv.allowsUndo = true; tv.delegate = coordinator; coordinator.textView = tv
        let window = NSWindow(contentRect: tv.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tv
        window.makeFirstResponder(tv)
        defer { window.close() }
        tv.setSelectedRange(NSRange(location: 9, length: 0))
        tv.deleteBackward(nil)
        XCTAssertEqual(tv.string, " ")
        XCTAssertTrue(tokens.isEmpty)
        let undo = try XCTUnwrap(tv.undoManager)
        undo.undo()
        XCTAssertEqual(tv.string, "README.md ")
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens.first?.item.id, "file:1")
    }

    func testComposerRendersEmptyLongAndFileStatesWithoutExpandingPastBudget() throws {
        let states = InMemoryConversationLocalStateStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "composer-render-" + UUID().uuidString))
        let store = WorkspaceStore(usesEmbeddedRuntime: false, localStateStore: states, recentWorkspaces: RecentWorkspacesStore(defaults: defaults), projects: ProjectsStore(root: nil))
        let models = ModelSettingsStore(defaults: defaults, localStateStore: states)
        for name in ["empty", "long", "files", "draft", "dark"] {
            if name == "draft" {
                store.beginDraft()
                store.selectWorkspace(Workspace(url: URL(fileURLWithPath: "/tmp/chater-composer-work/chater", isDirectory: true)))
            }
            let vm = DraftComposerPanelViewModel(workspaceStore: store, modelSettings: models, conversationViewModel: nil, isDraft: name == "draft", isEnabled: true, onSend: { _,_,_ in false })
            if name == "long" { vm.text = String(repeating: "输入区独立滚动，环境栏保持稳定。\n", count: 30); vm.composerHeight = 336 }
            if name == "files" { vm.fileReferences = [ComposerFileReference(path: "/project/docs/design.pdf", workspacePath: "/project", isDirectory: false)] }
            let content = MacComposerSurface(vm: vm, placeholder: "描述任务，或输入 / 查看命令")
                .environment(store).padding(24).frame(width: 760).background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: content)
            host.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
            let size = host.fittingSize
            XCTAssertLessThanOrEqual(size.height, 460)
            XCTAssertGreaterThan(size.height, 70)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            if let destination = ProcessInfo.processInfo.environment["COMPOSER_SNAPSHOTS"],
               let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                let url = URL(fileURLWithPath: destination).appendingPathComponent("composer-" + name + ".png")
                try rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }
}
#endif
