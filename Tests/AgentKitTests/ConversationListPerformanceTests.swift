import XCTest
import ClientToolProtocol
@testable import AgentKit

final class ConversationListPerformanceTests: XCTestCase {
    @MainActor
    func testMissingRuntimeStaysWaitingAfterRetryWindowAndThenRecovers() async {
        let client = ListPerformanceClient()
        client.runtimeAvailable = false
        let store = WorkspaceStore(client: client, localStateStore: InMemoryConversationLocalStateStore())
        await store.refreshConversationList()
        XCTAssertTrue(store.listViewModel.isWaitingForRuntime)
        XCTAssertFalse(store.listViewModel.hasLoadedConversations)
        XCTAssertNil(store.listViewModel.errorMessage)
        XCTAssertEqual(client.capabilityRequests, 0)
        XCTAssertEqual(client.activityRequests, 0)
        client.runtimeAvailable = true
        await store.refreshConversationList()
        XCTAssertFalse(store.listViewModel.isWaitingForRuntime)
        XCTAssertTrue(store.listViewModel.hasLoadedConversations)
        XCTAssertEqual(client.capabilityRequests, 1)
        store.supervisor.stopActivityMonitoring()
    }

    @MainActor
    func testRealListFailureIsNotHiddenAsStartup() async {
        let client = ListPerformanceClient()
        client.failedOffset = 0
        let list = ConversationListViewModel(client: client)
        await list.refresh()
        XCTAssertFalse(list.isWaitingForRuntime)
        XCTAssertNotNil(list.errorMessage)
        XCTAssertFalse(list.hasLoadedConversations)
    }

    @MainActor
    func testOverlappingForegroundRefreshesShareActivityAndPublishListFirst() async {
        let client = ListPerformanceClient()
        client.blockActivity = true
        let started = expectation(description: "activity started")
        client.onActivity = { started.fulfill() }
        let store = WorkspaceStore(client: client, localStateStore: InMemoryConversationLocalStateStore())
        let first = Task { await store.refreshConversationList() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(store.listViewModel.hasLoadedConversations)
        XCTAssertEqual(store.listViewModel.conversations.count, 100)
        let others = (0..<4).map { _ in Task { await store.refreshConversationList() } }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(client.pageRequests, [0])
        XCTAssertEqual(client.capabilityRequests, 1)
        XCTAssertEqual(client.activityRequests, 1)
        client.resumeActivity()
        await first.value
        for task in others { await task.value }
        store.supervisor.stopActivityMonitoring()
    }

    @MainActor
    func testRemainingMetadataLoadsAll819RowsWithoutCreatingControllers() async {
        let client = ListPerformanceClient()
        let store = WorkspaceStore(client: client, localStateStore: InMemoryConversationLocalStateStore())
        await store.listViewModel.refresh()
        XCTAssertEqual(store.listViewModel.conversations.count, 100)
        await store.listViewModel.loadRemainingConversations()
        XCTAssertEqual(store.listViewModel.conversations.map(\.id), (0..<819).map { "s\($0)" })
        XCTAssertFalse(store.listViewModel.hasMoreConversations)
        XCTAssertTrue(store.supervisor.controllers.isEmpty)
        XCTAssertEqual(client.pageRequests, stride(from: 0, to: 819, by: 100).map { $0 })
    }

    @MainActor
    func testPrefetchStopsOnFailureAndRetriesTheSameCursor() async {
        let client = ListPerformanceClient()
        client.failedOffset = 200
        let list = ConversationListViewModel(client: client)
        await list.refresh()
        await list.loadRemainingConversations()
        XCTAssertEqual(list.conversations.count, 200)
        XCTAssertTrue(list.hasMoreConversations)
        XCTAssertNotNil(list.errorMessage)
        client.failedOffset = nil
        await list.loadRemainingConversations()
        XCTAssertEqual(list.conversations.count, 819)
        XCTAssertEqual(Array(client.pageRequests.prefix(4)), [0, 100, 200, 200])
    }

    @MainActor
    func testCancelledPrefetchDoesNotPublishAnInFlightPage() async {
        let client = ListPerformanceClient()
        client.blockPage = true
        let started = expectation(description: "older page started")
        client.onOlderPage = { started.fulfill() }
        let list = ConversationListViewModel(client: client)
        await list.refresh()
        let prefetch = Task { await list.loadRemainingConversations() }
        await fulfillment(of: [started], timeout: 2)
        prefetch.cancel()
        client.resumePage()
        await prefetch.value
        XCTAssertEqual(list.conversations.count, 100)
        XCTAssertTrue(list.hasMoreConversations)
        client.blockPage = false
        await list.loadRemainingConversations()
        XCTAssertEqual(list.conversations.count, 819)
    }

    @MainActor
    func testHidingListStopsAutomaticPrefetchAndReopeningContinues() async {
        let client = ListPerformanceClient()
        client.blockPage = true
        let started = expectation(description: "automatic page started")
        client.onOlderPage = { started.fulfill() }
        let store = WorkspaceStore(client: client, localStateStore: InMemoryConversationLocalStateStore())
        store.setConversationListVisible(true)
        await fulfillment(of: [started], timeout: 2)
        store.setConversationListVisible(false)
        client.resumePage()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(store.listViewModel.conversations.count, 100)
        client.blockPage = false
        let completed = expectation(description: "last metadata page")
        client.onLastPage = { completed.fulfill() }
        store.setConversationListVisible(true)
        await fulfillment(of: [completed], timeout: 3)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(store.listViewModel.conversations.count, 819)
        store.setConversationListVisible(false)
        store.supervisor.stopActivityMonitoring()
    }

    func testProjectionPreservesServerOrderAndFiltersBothPartitions() {
        let items = [
            ConversationRef(id: "newest", workspacePath: "/tmp/project", name: "Needle newest", turnStatus: "running"),
            ConversationRef(id: "middle", workspacePath: "/tmp/project", name: "Needle middle"),
            ConversationRef(id: "oldest", workspacePath: "", name: "Other"),
        ].map(ConversationListItem.init)
        let archived = [ConversationListItem(ref: ConversationRef(id: "archive", workspacePath: "", name: "Needle"))]
        let projection = ConversationListProjection(items: items, archivedItems: archived, searchText: "  needle\n")
        XCTAssertEqual(projection.recentItems.map(\.id), ["newest", "middle"])
        XCTAssertEqual(projection.archivedConversations.map(\.id), ["archive"])
        XCTAssertEqual(projection.groups.count, 1)
        XCTAssertTrue(projection.groups[0].isRunning)
        XCTAssertEqual(projection.groups[0].conversations.map(\.id), ["newest", "middle"])
        XCTAssertEqual(projection.itemsByID.count, 2)
        XCTAssertEqual(projection.archivedItemsByID.count, 1)
    }
}

@MainActor
private final class ListPerformanceClient: RuntimeClient {
    var runtimeAvailable = true
    var pageRequests: [Int] = []
    var capabilityRequests = 0
    var activityRequests = 0
    var failedOffset: Int?
    var blockActivity = false
    var blockPage = false
    var onActivity: (() -> Void)?
    var onOlderPage: (() -> Void)?
    var onLastPage: (() -> Void)?
    private var activityContinuation: CheckedContinuation<Void, Never>?
    private var pageContinuation: CheckedContinuation<Void, Never>?

    func runtimeCapabilities() async throws -> RuntimeCapabilitySnapshot {
        capabilityRequests += 1
        return RuntimeCapabilitySnapshot(capabilities: ["activity_snapshot_v1": true])
    }
    func activitySnapshot() async throws -> RuntimeActivitySnapshot {
        activityRequests += 1
        if blockActivity {
            await withCheckedContinuation { activityContinuation = $0; onActivity?() }
        }
        return RuntimeActivitySnapshot(sessions: [])
    }
    func resumeActivity() { activityContinuation?.resume(); activityContinuation = nil }
    func resumePage() { pageContinuation?.resume(); pageContinuation = nil }
    func listConversationPage(archived: Bool, limit: Int, before: String?) async throws -> ConversationListPage {
        guard runtimeAvailable else { throw RuntimeHTTPError.runtimeNotStarted }
        let offset = Int(before ?? "0") ?? 0
        pageRequests.append(offset)
        if offset == failedOffset { throw RuntimeHTTPError.invalidResponse }
        if blockPage, offset > 0 {
            await withCheckedContinuation { pageContinuation = $0; onOlderPage?() }
        }
        let end = min(offset + limit, 819)
        if end == 819 { onLastPage?() }
        return ConversationListPage(
            conversations: (offset..<end).map { ConversationRef(id: "s\($0)", workspacePath: "") },
            nextCursor: end < 819 ? String(end) : nil, hasMore: end < 819, isPaged: true)
    }
    func createConversation(workspacePath: String) async throws -> ConversationRef { throw RuntimeHTTPError.unsupported }
    func listConversations() async throws -> [ConversationRef] { [] }
    func renameConversation(id: String, name: String) async throws -> ConversationRef { throw RuntimeHTTPError.unsupported }
    func deleteConversation(id: String) async throws {}
    func connect(conversationID: String, since: Int) async throws -> AsyncStream<AgentEvent> {
        XCTFail("metadata prefetch must not connect a session")
        return AsyncStream { $0.finish() }
    }
    func send(input: AgentInput) async {}
    func registerTools(_ tools: [ClientToolInfo]) async {}
    func sendApproval(id: String, approved: Bool) async {}
    func sendApproval(id: String, decision: String, scope: String?) async {}
    func sendPlanApproval(id: String, approved: Bool) async {}
    func sendAskUserResponse(id: String, selected: [String], notes: String?) async {}
    func cancelTurn() async {}
    func disconnect() async {}
    func getConversationDetail(id: String) async throws -> ConversationDetail {
        XCTFail("metadata prefetch must not load details")
        throw RuntimeHTTPError.unsupported
    }
    func getMessages(conversationID: String) async throws -> [Message] { [] }
    func getEvents(conversationID: String) async throws -> [AgentEvent] {
        XCTFail("metadata prefetch must not load history")
        return []
    }
}
