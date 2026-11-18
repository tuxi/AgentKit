#if os(macOS)
import Foundation
import XCTest
@testable import AgentKit

private actor SubmissionDelay {
    var enabled = false
    var entered = false
    var inputs: [AgentInput] = []
    func record(_ input: AgentInput) { inputs.append(input) }
    private var continuation: CheckedContinuation<Void, Never>?
    func enable() { enabled = true }
    func wait() async {
        guard enabled else { return }
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { enabled = false; continuation?.resume(); continuation = nil }
}

private final class SubmissionDelayClient: RuntimeClient, @unchecked Sendable {
    let delay = SubmissionDelay()
    let events = AsyncStream<AgentEvent>.makeStream()
    func runtimeCapabilities() async throws -> RuntimeCapabilitySnapshot { await delay.wait(); throw RuntimeHTTPError.unsupported }
    func createConversation(workspacePath: String) async throws -> ConversationRef { await delay.wait(); throw RuntimeHTTPError.unsupported }
    func listConversations() async throws -> [ConversationRef] { [] }
    func renameConversation(id: String, name: String) async throws -> ConversationRef { throw RuntimeHTTPError.unsupported }
    func deleteConversation(id: String) async throws {}
    func connect(conversationID: String, since: Int) async throws -> AsyncStream<AgentEvent> { events.stream }
    func send(input: AgentInput) async { await delay.record(input) }
    func registerTools(_ tools: [ClientToolInfo]) async {}
    func sendApproval(id: String, approved: Bool) async {}
    func sendApproval(id: String, decision: String, scope: String?) async {}
    func sendPlanApproval(id: String, approved: Bool) async {}
    func sendAskUserResponse(id: String, selected: [String], notes: String?) async {}
    func cancelTurn() async {}
    func disconnect() async { events.continuation.finish() }
    func getConversationDetail(id: String) async throws -> ConversationDetail { throw RuntimeHTTPError.unsupported }
    func getMessages(conversationID: String) async throws -> [Message] { [] }
    func getEvents(conversationID: String) async throws -> [AgentEvent] { [] }
}

@MainActor
final class LocalMessageSubmissionTests: XCTestCase {
    private func store(client: any RuntimeClient = SubmissionDelayClient(), states: any ConversationLocalStateStore = InMemoryConversationLocalStateStore()) -> WorkspaceStore {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        return WorkspaceStore(client: client, usesEmbeddedRuntime: false, localStateStore: states,
            recentWorkspaces: RecentWorkspacesStore(defaults: defaults), projects: ProjectsStore(root: nil))
    }

    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out waiting for submission boundary")
        throw NSError(domain: "SubmissionBoundary", code: 1)
    }

    func testDetachmentAndAcceptancePreserveEvenIdenticalNextDraft() throws {
        let store = store()
        let key = ConversationLocalStateKey.session("same-text")
        let file = ComposerFileReference(path: "/tmp/a.md", workspacePath: nil, isDirectory: false)
        try store.localStateStore.updateState(for: key) { $0.composerDraft.text = "hello"; $0.composerDraft.fileReferences = [file] }
        let record = try store.beginLocalSubmission(key: key, text: "hello", model: "model", effort: .high)
        XCTAssertEqual(try store.localStateStore.state(for: key)?.composerDraft.text, "")
        XCTAssertEqual(try store.localStateStore.state(for: .submission(record.resourceID))?.composerDraft.fileReferences, [file])
        // The next draft can have exactly the same text and files as the old one.
        try store.localStateStore.updateState(for: key) { $0.composerDraft.text = "hello"; $0.composerDraft.fileReferences = [file] }
        _ = try store.localStateStore.markSubmissionPending(key: key, input: record.input)
        try store.localStateStore.acceptSubmission(key: key, requestID: record.id, turnID: "turn")
        XCTAssertEqual(try store.localStateStore.state(for: key)?.composerDraft.text, "hello")
        XCTAssertEqual(try store.localStateStore.state(for: key)?.composerDraft.fileReferences, [file])
        XCTAssertEqual(record.input.reasoningEffort, .high)
    }

    func testRuntimeOwnedMessageOutsideHistoryPageDoesNotReappearAsPending() {
        var record = LocalMessageSubmission(id: "old-request", resourceID: "old-request", text: "old",
            displayText: "old", fileReferences: [], model: nil, reasoningEffort: nil)
        record.phase = .accepted; record.turnID = "old-turn"; record.wasPresentedByRuntime = true
        let snapshot = RuntimeSnapshot(timeline: [])
        var document = ConversationWebDocumentBuilder.build(snapshot: snapshot, conversationID: "s", revision: 1)
        ConversationSubmissionProjection.apply(to: &document, snapshot: snapshot, submissions: [record],
            key: .session("s"), registerAction: { _ in "action" })
        XCTAssertTrue(document.turns.isEmpty)
        record.wasPresentedByRuntime = false; record.phase = .failed; record.failure = "preparation failed"
        ConversationSubmissionProjection.apply(to: &document, snapshot: snapshot, submissions: [record],
            key: .session("s"), registerAction: { _ in "retry-action" })
        XCTAssertEqual(document.turns.count, 1)
        XCTAssertEqual(document.turns.first?.retrySubmissionActionID, "retry-action")
    }

    func testResourceStateIsNotRestoredAsANewConversationDraft() throws {
        let store = store()
        _ = try store.beginLocalSubmission(key: .session("s"), text: "hello", model: nil, effort: nil)
        XCTAssertNil(try store.localStateStore.latestDraft())
    }

    func testSubmissionSurvivesMigrationAndSQLiteReopen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let states = SQLiteConversationLocalStateStore(databaseURL: url)
        let store = store(states: states)
        let draftID = UUID()
        let record = try store.beginLocalSubmission(key: .draft(draftID), text: "persist me", model: nil, effort: nil)
        try states.migrateDraft(draftID, to: "s")
        try states.flush()
        let reopened = SQLiteConversationLocalStateStore(databaseURL: url)
        XCTAssertEqual(try reopened.state(for: .session("s"))?.localSubmissions, [record])
        XCTAssertNotNil(try reopened.state(for: .submission(record.resourceID)))
    }

    func testExistingConversationShowsSubmissionBeforeCapabilitiesReturn() async throws {
        let client = SubmissionDelayClient()
        let store = store(client: client)
        let ref = ConversationRef(id: "existing", workspacePath: "/tmp")
        let vm = store.supervisor.controller(for: ref)
        await vm.connect(to: ref)
        try store.localStateStore.updateState(for: .session(ref.id)) { $0.composerDraft.text = "first" }
        await client.delay.enable()
        let sending = Task { await store.sendUserMessage("first", model: "model", reasoningEffort: .high, through: vm) }
        try await wait { await client.delay.entered }
        let record = try XCTUnwrap(vm.localSubmissions.first)
        XCTAssertEqual(record.displayText, "first")
        XCTAssertTrue(vm.snapshot.turns.isEmpty, "local delivery never manufactures execution")
        XCTAssertEqual(try store.localStateStore.state(for: .session(ref.id))?.composerDraft.text, "")
        try store.localStateStore.updateState(for: .session(ref.id)) { $0.composerDraft.text = "next" }
        await client.delay.release()
        let sent = await sending.value
        XCTAssertTrue(sent)
        client.events.continuation.yield(.turnAccepted(turnID: "t", requestID: record.id, text: nil))
        try await wait { vm.localSubmissions.first?.phase == .accepted }
        XCTAssertEqual(try store.localStateStore.state(for: .session(ref.id))?.composerDraft.text, "next")
        client.events.continuation.yield(.turnStarted(turnID: "t", text: "first", userAssets: [], localAssets: []))
        try await wait { !vm.snapshot.turns.isEmpty }
        XCTAssertEqual(vm.snapshot.turns.count, 1)
        await vm.disconnect()
    }

    func testRejectedSubmissionRetriesSameRequestAndLateAcceptanceDoesNotUndoQueue() async throws {
        let client = SubmissionDelayClient()
        let store = store(client: client)
        let ref = ConversationRef(id: "retry", workspacePath: "/tmp")
        let vm = store.supervisor.controller(for: ref)
        await vm.connect(to: ref)
        try store.localStateStore.updateState(for: .session(ref.id)) { $0.composerDraft.text = "retry payload" }
        let sent = await store.sendUserMessage("retry payload", model: "chosen", reasoningEffort: .high, through: vm)
        XCTAssertTrue(sent)
        let record = try XCTUnwrap(vm.localSubmissions.first)
        try await wait { await client.delay.inputs.count == 1 }
        client.events.continuation.yield(.agentInputRejected(requestID: record.id,
            rejection: .init(code: "temporary", message: "临时失败")))
        try await wait { vm.localSubmissions.first?.phase == .failed }
        try store.localStateStore.updateState(for: .session(ref.id)) { $0.composerDraft.text = "next" }
        await store.retryLocalSubmission(key: .session(ref.id), id: record.id)
        try await wait { await client.delay.inputs.count == 2 }
        let inputs = await client.delay.inputs
        XCTAssertEqual(inputs.count, 2)
        XCTAssertEqual(inputs[0].requestID, inputs[1].requestID)
        XCTAssertEqual(inputs[1].text, "retry payload")
        XCTAssertEqual(inputs[1].reasoningEffort, .high)
        XCTAssertEqual(try store.localStateStore.state(for: .session(ref.id))?.composerDraft.text, "next")
        client.events.continuation.yield(.turnAccepted(turnID: "t", requestID: record.id, text: nil))
        client.events.continuation.yield(.turnQueued(turnID: "t", reason: "capacity", position: 1))
        try await wait { vm.localSubmissions.first?.phase == .queued }
        client.events.continuation.yield(.turnAccepted(turnID: "t", requestID: record.id, text: nil))
        // A following event is the barrier proving the duplicate ack was consumed.
        client.events.continuation.yield(.turnQueued(turnID: "t", reason: "capacity", position: 2))
        try await wait { vm.queuePosition == 2 }
        XCTAssertEqual(vm.localSubmissions.first?.phase, .queued)
        await vm.disconnect()
    }

    func testPreparationFailureKeepsVisibleSubmissionAndResources() async throws {
        let client = SubmissionDelayClient()
        let store = store(client: client)
        let ref = ConversationRef(id: "resource-failure", workspacePath: "/tmp")
        let vm = store.supervisor.controller(for: ref)
        await vm.connect(to: ref)
        let attachment = DraftAttachmentReference(id: UUID().uuidString, displayName: "photo.png", resourceURI: "file:///tmp/missing-photo.png")
        try store.localStateStore.updateState(for: .session(ref.id)) {
            $0.composerDraft.text = "image"; $0.composerDraft.attachments = [attachment]
        }
        let handedOff = await store.sendUserMessage("image", model: nil, reasoningEffort: nil, through: vm)
        XCTAssertTrue(handedOff, "failure belongs to the visible submission, not the next editor")
        let record = try XCTUnwrap(vm.localSubmissions.first)
        XCTAssertEqual(record.phase, .failed)
        XCTAssertNotNil(record.failure)
        XCTAssertEqual(try store.localStateStore.state(for: .submission(record.resourceID))?.composerDraft.attachments.count, 1)
        let inputs = await client.delay.inputs
        XCTAssertTrue(inputs.isEmpty)
        await vm.disconnect()
    }

    func testLateCreationFailureDoesNotOverwriteAnotherSelectedConversation() async throws {
        let client = SubmissionDelayClient()
        let store = store(client: client)
        store.beginDraft()
        store.selectWorkspace(Workspace(url: URL(fileURLWithPath: "/tmp")))
        await client.delay.enable()
        let sending = Task { await store.commitDraft(firstMessage: "old draft", model: nil) }
        try await wait { await client.delay.entered }
        let other = ConversationRef(id: "other", workspacePath: "/tmp")
        store.selectItem = .conversationDetail(conversation: other)
        await client.delay.release()
        await sending.value
        XCTAssertEqual(store.selectedConversation?.id, other.id)
        XCTAssertNil(store.draft)
    }

    func testNewConversationIsVisibleWhileCreationWaitsAndFailureKeepsNextDraft() async throws {
        let client = SubmissionDelayClient()
        let store = store(client: client)
        store.beginDraft()
        store.selectWorkspace(Workspace(url: URL(fileURLWithPath: "/tmp")))
        let id = try XCTUnwrap(store.draft?.id)
        try store.localStateStore.updateState(for: .draft(id)) { $0.composerDraft.text = "new task" }
        await client.delay.enable()
        let sending = Task { await store.commitDraft(firstMessage: "new task", model: nil) }
        try await wait { await client.delay.entered }
        XCTAssertEqual(store.localSubmissions(for: .draft(id)).first?.displayText, "new task")
        try store.localStateStore.updateState(for: .draft(id)) { $0.composerDraft.text = "next draft" }
        await client.delay.release()
        await sending.value
        XCTAssertEqual(store.localSubmissions(for: .draft(id)).first?.phase, .failed)
        XCTAssertEqual(try store.localStateStore.state(for: .draft(id))?.composerDraft.text, "next draft")
    }
}
#endif
