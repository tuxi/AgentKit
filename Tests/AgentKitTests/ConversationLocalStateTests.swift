import XCTest
@testable import AgentKit

final class ConversationLocalStateTests: XCTestCase {
    func testSQLitePersistsComposerModelAndAttentionAcrossReopen() throws {
        let databaseURL = temporaryDatabaseURL()
        let draftID = UUID()
        let first = SQLiteConversationLocalStateStore(databaseURL: databaseURL)

        try first.updateState(for: .draft(draftID)) { state in
            state.composerDraft.text = "unfinished prompt"
            state.composerDraft.workspacePath = "/tmp/project"
            state.composerDraft.wantsManagedWorktree = true
            state.selectedModelID = "provider/model-a"
            state.recentModelIDs = ["provider/model-a", "provider/model-b"]
        }
        try first.updateState(for: .session("session-a")) { state in
            state.lastReadSequence = 40
            state.lastSeenTerminalSequence = 41
            state.lastNotifiedTerminalSequence = 42
            state.lastNotifiedApprovalSequence = 43
        }
        try first.establishAttentionBaseline()
        try first.flush()

        let reopened = SQLiteConversationLocalStateStore(databaseURL: databaseURL)
        let draft = try XCTUnwrap(reopened.state(for: .draft(draftID)))
        XCTAssertEqual(draft.composerDraft.text, "unfinished prompt")
        XCTAssertEqual(draft.composerDraft.workspacePath, "/tmp/project")
        XCTAssertTrue(draft.composerDraft.wantsManagedWorktree)
        XCTAssertEqual(draft.selectedModelID, "provider/model-a")
        XCTAssertEqual(draft.recentModelIDs, ["provider/model-a", "provider/model-b"])

        let session = try XCTUnwrap(reopened.state(for: .session("session-a")))
        XCTAssertEqual(session.lastReadSequence, 40)
        XCTAssertEqual(session.lastSeenTerminalSequence, 41)
        XCTAssertEqual(session.lastNotifiedTerminalSequence, 42)
        XCTAssertEqual(session.lastNotifiedApprovalSequence, 43)
        XCTAssertTrue(reopened.hasEstablishedAttentionBaseline)
    }

    func testDraftMigrationIsAtomicAndLateDraftSaveCannotResurrectIt() throws {
        let store = SQLiteConversationLocalStateStore(databaseURL: temporaryDatabaseURL())
        let draftID = UUID()
        try store.updateState(for: .draft(draftID)) { state in
            state.composerDraft.text = "send me"
            state.composerDraft.clientRequestID = "create-1"
            state.selectedModelID = "model-a"
        }

        try store.migrateDraft(draftID, to: "session-1")
        try store.updateState(for: .draft(draftID)) { state in
            state.composerDraft.text = "late disappearing view write"
        }

        XCTAssertNil(try store.state(for: .draft(draftID)))
        let session = try XCTUnwrap(store.state(for: .session("session-1")))
        XCTAssertEqual(session.composerDraft.text, "send me")
        XCTAssertEqual(session.selectedModelID, "model-a")
        XCTAssertNil(try store.latestDraft())
    }

    func testLatestDraftUsesStableIDAndUpdatedOrdering() throws {
        let store = InMemoryConversationLocalStateStore()
        let firstID = UUID()
        let secondID = UUID()
        try store.save(
            ConversationLocalState(
                composerDraft: ComposerDraft(text: "first"),
                updatedAt: Date(timeIntervalSince1970: 1)
            ),
            for: .draft(firstID)
        )
        try store.save(
            ConversationLocalState(
                composerDraft: ComposerDraft(text: "second"),
                updatedAt: Date(timeIntervalSince1970: 2)
            ),
            for: .draft(secondID)
        )

        let latest = try XCTUnwrap(store.latestDraft())
        XCTAssertEqual(latest.id, secondID)
        XCTAssertEqual(latest.state.composerDraft.text, "second")
    }

    func testAttentionAdapterPersistsCursorsInUnifiedState() throws {
        let store = InMemoryConversationLocalStateStore()
        let attention = ConversationLocalStateAttentionReadStore(
            localStateStore: store,
            legacyStore: nil
        )

        XCTAssertFalse(attention.hasEstablishedBaseline)
        attention.establishBaseline()
        attention.setLastSeenTerminalSequence(20, for: "session-a")
        attention.setLastNotifiedTerminalSequence(21, for: "session-a")
        attention.setLastNotifiedApprovalSequence(22, for: "session-a")

        XCTAssertTrue(attention.hasEstablishedBaseline)
        XCTAssertEqual(attention.lastSeenTerminalSequence(for: "session-a"), 20)
        XCTAssertEqual(attention.lastNotifiedTerminalSequence(for: "session-a"), 21)
        XCTAssertEqual(attention.lastNotifiedApprovalSequence(for: "session-a"), 22)
        let state = try XCTUnwrap(store.state(for: .session("session-a")))
        XCTAssertEqual(state.lastReadSequence, 20)
    }

    @MainActor
    func testModelSettingsMigratesLegacyPerConversationSelection() throws {
        let suite = "ConversationLocalStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("model-last", forKey: "code_agent.model.last_selected")
        defaults.set(["session-a": "model-a"], forKey: "code_agent.model.used_models")
        let store = InMemoryConversationLocalStateStore()

        let settings = ModelSettingsStore(defaults: defaults, localStateStore: store)
        XCTAssertEqual(settings.lastSelectedModel, "model-last")
        XCTAssertEqual(settings.getModel(with: "session-a"), "model-a")
        XCTAssertNil(defaults.dictionary(forKey: "code_agent.model.used_models"))
        XCTAssertEqual(try store.state(for: .session("session-a"))?.selectedModelID, "model-a")

        settings.didUseModel("model-b", conversation: "session-a")
        XCTAssertEqual(settings.getModel(with: "session-a"), "model-b")
        XCTAssertEqual(settings.recentModels(for: "session-a").first, "model-b")
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentKitLocalStateTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.sqlite")
    }
}
