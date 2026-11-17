#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import AgentKit

@MainActor
final class MacConversationToolbarTests: XCTestCase {
    func testRenameValidationFailureAndRetryKeepOriginalTargetAndText() async {
        let editor = MacConversationTitleEditor()
        let original = ConversationRef(id: "one", workspacePath: "/tmp", name: "原名称")
        editor.begin(original)
        editor.text = " \n "
        var calls: [(String, String)] = []
        await editor.save(rename: { ref, name in calls.append((ref.id, name)); return ref }, failure: { "offline" })
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(editor.errorMessage, "名称不能为空。")
        editor.dismissError()
        editor.text = "新名称🙂"
        await editor.save(rename: { ref, name in calls.append((ref.id, name)); return nil }, failure: { "offline" })
        XCTAssertEqual(editor.text, "新名称🙂")
        XCTAssertEqual(editor.target?.id, "one")
        XCTAssertEqual(editor.errorMessage, "offline")
        editor.dismissError()
        await editor.save(rename: { ref, name in calls.append((ref.id, name)); return ref }, failure: { "" })
        XCTAssertNil(editor.target)
        XCTAssertEqual(calls.map(\.0), ["one", "one"])
        XCTAssertEqual(calls.map(\.1), ["新名称🙂", "新名称🙂"])
    }

    func testEscapeAndUnchangedNameNeverSendAndDuplicateSubmitIsSuppressed() async throws {
        let editor = MacConversationTitleEditor()
        let original = ConversationRef(id: "one", workspacePath: "/tmp", name: "same")
        editor.begin(original)
        editor.text = "discard me"
        editor.cancel()
        var count = 0
        await editor.save(rename: { ref, _ in count += 1; return ref }, failure: { "" })
        editor.begin(original)
        await editor.save(rename: { ref, _ in count += 1; return ref }, failure: { "" })
        XCTAssertEqual(count, 0)
        XCTAssertNil(editor.target)
        editor.begin(original)
        editor.text = "  renamed  "
        let save = Task {
            await editor.save(rename: { ref, name in
                count += 1
                XCTAssertEqual(name, "renamed")
                try? await Task.sleep(for: .milliseconds(30))
                return ref
            }, failure: { "" })
        }
        await Task.yield()
        XCTAssertTrue(editor.isSaving)
        await editor.save(rename: { ref, _ in count += 1; return ref }, failure: { "" })
        await save.value
        XCTAssertEqual(count, 1)
    }

    func testNativeFieldSelectsAllHonorsIMEAndEscapeDoesNotCommit() async throws {
        var name = "中文🙂 original"
        var commits = 0, cancels = 0
        let content = MacConversationNameField(text: Binding(get: { name }, set: { name = $0 }),
            isSaving: false, focusRevision: 1,
            onCommit: { commits += 1 }, onCancel: { cancels += 1 })
            .frame(width: 260, height: 28).padding(12).background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: content)
        host.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 300, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        func findField(_ view: NSView) -> MacConversationNameField.NameField? {
            if let field = view as? MacConversationNameField.NameField { return field }
            for child in view.subviews { if let field = findField(child) { return field } }
            return nil
        }
        let field = try XCTUnwrap(findField(host))
        XCTAssertTrue(field.isBezeled)
        XCTAssertEqual(field.bezelStyle, .roundedBezel)
        let textView = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: name.utf16.count))
        if let destination = ProcessInfo.processInfo.environment["COMPOSER_SNAPSHOTS"],
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to:
                URL(fileURLWithPath: destination).appendingPathComponent("toolbar-editing.png"))
        }
        let delegate = try XCTUnwrap(field.delegate as? MacConversationNameField.Coordinator)
        textView.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0), replacementRange: textView.selectedRange())
        XCTAssertFalse(delegate.control(field, textView: textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(commits, 0)
        textView.unmarkText()
        XCTAssertTrue(delegate.control(field, textView: textView, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        delegate.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(commits, 0)
    }

    func testTitleRendersInWideNarrowAndDarkHeaders() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "toolbar-" + UUID().uuidString))
        let store = WorkspaceStore(usesEmbeddedRuntime: false, localStateStore: InMemoryConversationLocalStateStore(),
            recentWorkspaces: RecentWorkspacesStore(defaults: defaults), projects: ProjectsStore(root: nil))
        let ref = ConversationRef(id: "session", workspacePath: "/project/.codeagent/worktrees/test", name: "ui_preview matrix UI 展示 · 一个很长的会话名称")
        for (name, width) in [("normal", 680.0), ("narrow", 240), ("dark", 680)] {
            let host = NSHostingView(rootView: HStack(spacing: 8) {
                Image(systemName: "sidebar.left").frame(width: 28)
                MacConversationToolbarTitle(conversation: ref, allowsFinderReveal: true)
                Image(systemName: "terminal").frame(width: 28)
                Image(systemName: "folder").frame(width: 28)
            }.padding(.horizontal, 12).frame(width: width, height: 46)
                .background(Color(nsColor: .windowBackgroundColor)).environment(store))
            host.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
            host.frame = NSRect(x: 0, y: 0, width: width, height: 46)
            host.layoutSubtreeIfNeeded()
            if let destination = ProcessInfo.processInfo.environment["COMPOSER_SNAPSHOTS"],
               let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: destination).appendingPathComponent("toolbar-\(name).png"))
            }
            XCTAssertEqual(host.bounds.height, 46)
        }
    }
}
#endif
