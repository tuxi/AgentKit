#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import AgentKit

@MainActor
final class MacDraftLandingTests: XCTestCase {
    private func workspace(_ path: String) -> Workspace {
        Workspace(url: URL(fileURLWithPath: path), branch: "main")
    }

    func testSidebarDraftSelectsDestinationBeforeResolvingCheckout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ref: refs/heads/feature\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "draft-switch-" + UUID().uuidString))
        let states = InMemoryConversationLocalStateStore()
        let store = WorkspaceStore(usesEmbeddedRuntime: false, localStateStore: states,
                                   recentWorkspaces: RecentWorkspacesStore(defaults: defaults), projects: ProjectsStore(root: nil))

        store.beginDraft(at: root)

        XCTAssertEqual(store.draft?.workspace?.url, root)
        XCTAssertEqual(store.selectItem, .draft)
        XCTAssertTrue(store.isResolvingDraftWorkspace)
        XCTAssertNil(store.draft?.workspace?.branch)
        try await waitFor { !store.isResolvingDraftWorkspace }
        XCTAssertEqual(store.draft?.workspace?.branch, "feature")
        let draftID = try XCTUnwrap(store.draft?.id)
        XCTAssertEqual(try states.state(for: .draft(draftID))?.composerDraft.workspaceBranch, "feature")

        store.beginDraft(at: root)
        let other = workspace("/another/project")
        store.selectWorkspace(other)
        XCTAssertFalse(store.isResolvingDraftWorkspace)
        XCTAssertEqual(store.draft?.workspace, other)
    }

    func testRecentBookmarksPersistLatestOrderAfterBackgroundCreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = ["One", "Two"].map { root.appendingPathComponent($0, isDirectory: true) }
        for url in urls { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "recent-switch-" + UUID().uuidString))
        let recent = RecentWorkspacesStore(defaults: defaults)
        let first = Workspace(url: urls[0], branch: "main")
        let second = Workspace(url: urls[1], branch: "main")

        recent.touch(first)
        recent.touch(second)
        recent.touch(first)

        XCTAssertEqual(recent.workspaces, [first, second])
        try await waitFor { (defaults.array(forKey: "code_agent.recent_workspaces.bookmarks")?.count ?? 0) == 2 }
        XCTAssertEqual(RecentWorkspacesStore(defaults: defaults).workspaces.map(\.name), ["One", "Two"])
        recent.touch(second)
        XCTAssertEqual(RecentWorkspacesStore(defaults: defaults).workspaces.map(\.name), ["Two", "One"])
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }

    func testChoicesIncludeSelectionAndDoNotReorderOnClick() {
        let recent = [workspace("/a/one"), workspace("/b/two"), workspace("/c/three"), workspace("/d/four")]
        var choices = MacDraftWorkspaceChoices()
        choices.refresh(recent: recent, selected: recent[3], preserveOrder: false)
        XCTAssertEqual(choices.workspaces.map(\.id), [recent[3], recent[0], recent[1]].map(\.id))
        let before = choices.workspaces
        choices.refresh(recent: [recent[0]] + recent, selected: recent[0], preserveOrder: true)
        XCTAssertEqual(choices.workspaces, before)
        choices.refresh(recent: [], selected: nil, preserveOrder: false)
        XCTAssertTrue(choices.workspaces.isEmpty)
    }

    func testDuplicateNamesExposeDifferentParentPaths() {
        let first = workspace("/team-one/app"), second = workspace("/team-two/app")
        var choices = MacDraftWorkspaceChoices()
        choices.refresh(recent: [first, second, workspace("/docs")], selected: first, preserveOrder: false)
        XCTAssertEqual(choices.subtitle(for: first), "/team-one")
        XCTAssertEqual(choices.subtitle(for: second), "/team-two")
        XCTAssertNil(choices.subtitle(for: workspace("/docs")))
    }

    func testConnectionDiagnosticsDoNotExposeCredentialsOrInventOfflineState() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://user:password@example.com:8443/?token=secret#private"))
        func snapshot(_ status: RuntimeServerConnectionStatus, checkedAt: Date) -> RuntimeServerDiagnosticSnapshot {
            .init(connectionID: "server", status: status, endpoint: endpoint, runtimeProfile: nil,
                  lastCheckedAt: checkedAt, lastConnectedAt: nil, lastErrorDescription: "Authorization: Bearer private-token")
        }
        let first = try XCTUnwrap(ComposerDiagnostic.runtime(snapshot(.offline, checkedAt: .distantPast), name: "Remote"))
        XCTAssertTrue(first.details.contains("https://example.com:8443/"))
        for secret in ["user:", "password", "secret", "private-token", "#private"] {
            XCTAssertFalse(first.details.contains(secret))
        }
        let next = try XCTUnwrap(ComposerDiagnostic.runtime(snapshot(.offline, checkedAt: .now), name: "Remote"))
        XCTAssertEqual(first.id, next.id, "Polling the same failure must not reopen a dismissed banner")
        XCTAssertNil(ComposerDiagnostic.runtime(snapshot(.checking, checkedAt: .now), name: "Remote"))
        XCTAssertNil(ComposerDiagnostic.runtime(snapshot(.connected, checkedAt: .now), name: "Remote"))
        XCTAssertEqual(ComposerDiagnostic.runtime(snapshot(.authenticationFailed, checkedAt: .now), name: "Remote")?.title, "执行环境认证失败")
    }

    func testLandingRendersInRemainingColumnAndPreservesDraft() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "draft-landing-" + UUID().uuidString))
        let states = InMemoryConversationLocalStateStore()
        let recent = RecentWorkspacesStore(defaults: defaults)
        let entries = [workspace("/project/chater"), workspace("/project/AgentKit"), workspace("/project/code-agent")]
        entries.reversed().forEach { recent.touch($0) }
        let store = WorkspaceStore(usesEmbeddedRuntime: false, localStateStore: states,
                                   recentWorkspaces: recent, projects: ProjectsStore(root: nil))
        store.beginDraft()
        let draftID = try XCTUnwrap(store.draft?.id)
        try states.updateState(for: .draft(draftID)) { $0.composerDraft.text = "保留我的草稿\n" }
        let issue = ComposerDiagnostic(id: "offline", title: "无法连接执行环境", message: "请检查连接后重试。",
                                       details: "状态：offline", destination: .environment)
        for (name, width, height) in [("normal", 900.0, 600.0), ("inspector", 390, 600),
                                      ("low", 600, 180), ("offline", 728, 280), ("dark", 600, 420)] {
            let host = NSHostingView(rootView: MacDraftLandingView()
                .environment(store)
                .environment(\.composerEnvironmentName, "这台电脑")
                .environment(\.composerDiagnostic, name == "offline" ? issue : nil)
                .frame(width: width, height: height)
                .background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: width, height: height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(store.draft?.id, draftID)
            XCTAssertEqual(try states.state(for: .draft(draftID))?.composerDraft.text, "保留我的草稿\n")
            XCTAssertEqual(store.draft?.workspace?.id, entries[0].id)
            if let destination = ProcessInfo.processInfo.environment["COMPOSER_SNAPSHOTS"],
               let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: destination).appendingPathComponent("draft-\(name).png"))
            }
        }
    }
    func testFullDraftKeepsComposerPinnedInWideNarrowAndLowWindows() async throws {
        var bottomOffsets: [CGFloat] = []
        for (name, width, height) in [("full", 1000.0, 700.0), ("full-narrow", 390, 500),
                                      ("full-low", 700, 260), ("first-use", 700, 500)] {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "draft-full-" + UUID().uuidString))
            let states = InMemoryConversationLocalStateStore()
            let recent = RecentWorkspacesStore(defaults: defaults)
            if name != "first-use" {
                ["/project/code-agent", "/project/AgentKit", "/project/chater"].forEach { recent.touch(workspace($0)) }
            }
            let store = WorkspaceStore(usesEmbeddedRuntime: false, localStateStore: states,
                                       recentWorkspaces: recent, projects: ProjectsStore(root: nil))
            store.beginDraft()
            let models = ModelSettingsStore(defaults: defaults, localStateStore: states)
            let host = NSHostingView(rootView: ConversationDetailView()
                .environment(store).environment(models).environment(AgentRouter())
                .environment(\.composerEnvironmentName, "这台电脑")
                .frame(width: width, height: height))
            host.appearance = NSAppearance(named: .aqua)
            let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: width, height: height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            for _ in 0..<8 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            func findEditor(_ view: NSView) -> ComposerNSTextView? {
                if let editor = view as? ComposerNSTextView { return editor }
                for child in view.subviews { if let editor = findEditor(child) { return editor } }
                return nil
            }
            let editor = try XCTUnwrap(findEditor(host))
            let scroll = try XCTUnwrap(editor.enclosingScrollView)
            let rect = host.convert(scroll.bounds, from: scroll)
            XCTAssertTrue(host.bounds.contains(rect), name)
            let bottom = host.isFlipped ? host.bounds.maxY - rect.maxY : rect.minY
            XCTAssertGreaterThan(bottom, 35, name)
            XCTAssertLessThan(bottom, 90, name)
            bottomOffsets.append(bottom)
            XCTAssertNotNil(store.draft)
            XCTAssertTrue(store.listViewModel.conversations.isEmpty)
            if name == "first-use" { XCTAssertNil(store.draft?.workspace) }
            if let destination = ProcessInfo.processInfo.environment["COMPOSER_SNAPSHOTS"],
               let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: destination).appendingPathComponent("draft-\(name).png"))
            }
        }
        for offset in bottomOffsets { XCTAssertEqual(offset, bottomOffsets[0], accuracy: 1) }
    }

}
#endif
