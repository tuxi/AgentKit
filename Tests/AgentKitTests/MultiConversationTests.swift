import XCTest
@testable import AgentKit

final class MultiConversationTests: XCTestCase {
    @MainActor
    func testSelectionSwitchRetainsIndependentControllersAndChannels() async throws {
        let client = MultiSessionRuntimeClient()
        let store = WorkspaceStore(client: client)
        let a = ConversationRef(id: "a", workspacePath: "/tmp/a", name: "A")
        let b = ConversationRef(id: "b", workspacePath: "/tmp/b", name: "B")

        store.selectedConversation = a
        try await Task.sleep(for: .milliseconds(30))
        let controllerA = try XCTUnwrap(store.activeConversationViewModel)

        store.selectedConversation = b
        try await Task.sleep(for: .milliseconds(30))
        let controllerB = try XCTUnwrap(store.activeConversationViewModel)

        XCTAssertFalse(controllerA === controllerB)
        XCTAssertEqual(store.supervisor.controllers.count, 2)
        XCTAssertEqual(client.channel(for: "a").disconnectCount, 0)
        XCTAssertEqual(client.channel(for: "b").disconnectCount, 0)

        store.selectedConversation = a
        XCTAssertTrue(store.activeConversationViewModel === controllerA)
    }

    @MainActor
    func testSlowOldConnectionCannotOverrideNewSelection() async throws {
        let client = MultiSessionRuntimeClient(connectDelays: ["a": .milliseconds(180)])
        let store = WorkspaceStore(client: client)
        let a = ConversationRef(id: "a", workspacePath: "", name: "A")
        let b = ConversationRef(id: "b", workspacePath: "", name: "B")

        store.selectedConversation = a
        store.selectedConversation = b
        try await Task.sleep(for: .milliseconds(260))

        XCTAssertEqual(store.selectedConversation?.id, "b")
        XCTAssertEqual(store.activeConversationViewModel?.conversation?.id, "b")
        XCTAssertNotNil(store.supervisor.controller(sessionID: "a"))
    }

    @MainActor
    func testCancelIsRoutedToControllerSession() async throws {
        let client = MultiSessionRuntimeClient()
        let store = WorkspaceStore(client: client)
        let a = ConversationRef(id: "a", workspacePath: "")
        let b = ConversationRef(id: "b", workspacePath: "")

        store.selectedConversation = a
        try await Task.sleep(for: .milliseconds(20))
        let controllerA = try XCTUnwrap(store.activeConversationViewModel)
        store.selectedConversation = b
        try await Task.sleep(for: .milliseconds(20))

        await controllerA.cancelTurn()

        XCTAssertEqual(client.channel(for: "a").cancelCount, 1)
        XCTAssertEqual(client.channel(for: "b").cancelCount, 0)
    }

    func testLegacyRuntimeTurnsAreFIFOAcrossSessions() async {
        let coordinator = ConversationTurnCoordinator()
        let a = await coordinator.enqueue(sessionID: "a")
        let b = await coordinator.enqueue(sessionID: "b")

        let acquiredA = await coordinator.tryAcquire(
            ticket: a,
            sessionID: "a",
            allowsConcurrentSessions: false
        )
        let blockedB = await coordinator.tryAcquire(
            ticket: b,
            sessionID: "b",
            allowsConcurrentSessions: false
        )
        XCTAssertTrue(acquiredA)
        XCTAssertFalse(blockedB)

        await coordinator.release(sessionID: "a")
        let acquiredB = await coordinator.tryAcquire(
            ticket: b,
            sessionID: "b",
            allowsConcurrentSessions: false
        )
        XCTAssertTrue(acquiredB)
    }

    func testCapableRuntimeAllowsDifferentSessionsToAcquire() async {
        let coordinator = ConversationTurnCoordinator()
        let a = await coordinator.enqueue(sessionID: "a")
        let b = await coordinator.enqueue(sessionID: "b")

        let acquiredA = await coordinator.tryAcquire(
            ticket: a,
            sessionID: "a",
            allowsConcurrentSessions: true
        )
        let acquiredB = await coordinator.tryAcquire(
            ticket: b,
            sessionID: "b",
            allowsConcurrentSessions: true
        )
        XCTAssertTrue(acquiredA)
        XCTAssertTrue(acquiredB)
    }

    func testCapableRuntimeStillSerializesTurnsWithinOneSession() async {
        let coordinator = ConversationTurnCoordinator()
        let first = await coordinator.enqueue(sessionID: "a")
        let second = await coordinator.enqueue(sessionID: "a")

        let acquiredFirst = await coordinator.tryAcquire(
            ticket: first,
            sessionID: "a",
            allowsConcurrentSessions: true
        )
        let acquiredSecondEarly = await coordinator.tryAcquire(
            ticket: second,
            sessionID: "a",
            allowsConcurrentSessions: true
        )
        await coordinator.release(sessionID: "a")
        let acquiredSecondAfterTerminal = await coordinator.tryAcquire(
            ticket: second,
            sessionID: "a",
            allowsConcurrentSessions: true
        )

        XCTAssertTrue(acquiredFirst)
        XCTAssertFalse(acquiredSecondEarly)
        XCTAssertTrue(acquiredSecondAfterTerminal)
    }

    @MainActor
    func testActivitySnapshotReattachesBackgroundRunningSession() async {
        let capabilities = RuntimeCapabilitySnapshot(capabilities: [
            "multi_session_execution_v1": true,
            "session_scoped_client_tools_v1": true,
            "activity_snapshot_v1": true,
            "workspace_execution_policy_v1": true,
        ])
        let client = MultiSessionRuntimeClient(
            capabilitySnapshot: capabilities,
            activity: RuntimeActivitySnapshot(sessions: [
                RuntimeSessionActivity(sessionID: "b", turnID: "t1", state: "running")
            ])
        )
        let store = WorkspaceStore(client: client)
        let a = ConversationRef(id: "a", workspacePath: "")
        let b = ConversationRef(id: "b", workspacePath: "")

        store.selectedConversation = a
        await store.supervisor.refreshRuntimeState(conversations: [a, b])

        XCTAssertEqual(store.selectedConversation?.id, "a")
        XCTAssertTrue(client.channel(for: "b").isConnected)
        XCTAssertEqual(store.supervisor.activity(for: "b"), .running)
        XCTAssertTrue(store.supervisor.runtimeCapabilities.allowsMultiSessionExecution)
    }

    @MainActor
    func testConservativeRuntimeStillRestoresMinimalActivitySnapshot() async {
        let capabilities = RuntimeCapabilitySnapshot(capabilities: [
            "multi_session_execution_v1": false,
            "session_scoped_client_tools_v1": false,
            "activity_snapshot_v1": false,
            "workspace_execution_policy_v1": false,
        ])
        let client = MultiSessionRuntimeClient(
            capabilitySnapshot: capabilities,
            activity: RuntimeActivitySnapshot(sessions: [
                RuntimeSessionActivity(sessionID: "running", state: "running"),
                RuntimeSessionActivity(sessionID: "resuming", state: "resuming"),
                RuntimeSessionActivity(sessionID: "paused", state: "paused"),
                RuntimeSessionActivity(sessionID: "done", state: "done"),
            ])
        )
        let store = WorkspaceStore(client: client)
        let conversations = ["running", "resuming", "paused", "done"].map {
            ConversationRef(id: $0, workspacePath: "")
        }

        await store.supervisor.refreshRuntimeState(conversations: conversations)

        XCTAssertEqual(client.activitySnapshotRequestCount, 1)
        XCTAssertTrue(client.channel(for: "running").isConnected)
        XCTAssertTrue(client.channel(for: "resuming").isConnected)
        XCTAssertTrue(client.channel(for: "paused").isConnected)
        XCTAssertFalse(client.channel(for: "done").isConnected)
        XCTAssertFalse(store.supervisor.runtimeCapabilities.allowsMultiSessionExecution)
    }
}

private final class MultiSessionChannelDouble: RuntimeSessionChannel, @unchecked Sendable {
    let sessionID: String
    let connectDelay: Duration
    var isConnected = false
    var disconnectCount = 0
    var cancelCount = 0
    var capabilitiesValue: AgentCapabilityFlags = .default
    private var continuation: AsyncStream<AgentEvent>.Continuation?

    init(sessionID: String, connectDelay: Duration = .zero) {
        self.sessionID = sessionID
        self.connectDelay = connectDelay
    }

    func connect(since: Int) async throws -> AsyncStream<AgentEvent> {
        if connectDelay > .zero {
            try await Task.sleep(for: connectDelay)
        }
        isConnected = true
        return AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func send(input: AgentInput) async {}
    func registerTools(_ tools: [ClientToolInfo]) async {}
    func sendApproval(id: String, approved: Bool) async {}
    func sendApproval(id: String, decision: String, scope: String?) async {}
    func sendPlanApproval(id: String, approved: Bool) async {}
    func cancelTurn() async { cancelCount += 1 }
    func disconnect() async {
        disconnectCount += 1
        isConnected = false
        continuation?.finish()
    }
    func capabilities() async -> AgentCapabilityFlags { capabilitiesValue }
}

private final class MultiSessionRuntimeClient: RuntimeClient, @unchecked Sendable {
    private var channels: [String: MultiSessionChannelDouble] = [:]
    private let connectDelays: [String: Duration]
    private let capabilitySnapshot: RuntimeCapabilitySnapshot?
    private let activity: RuntimeActivitySnapshot?
    private(set) var activitySnapshotRequestCount = 0

    init(
        connectDelays: [String: Duration] = [:],
        capabilitySnapshot: RuntimeCapabilitySnapshot? = nil,
        activity: RuntimeActivitySnapshot? = nil
    ) {
        self.connectDelays = connectDelays
        self.capabilitySnapshot = capabilitySnapshot
        self.activity = activity
    }

    func channel(for id: String) -> MultiSessionChannelDouble {
        if let channel = channels[id] { return channel }
        let channel = MultiSessionChannelDouble(
            sessionID: id,
            connectDelay: connectDelays[id] ?? .zero
        )
        channels[id] = channel
        return channel
    }

    func makeSessionChannel(conversationID: String) -> any RuntimeSessionChannel {
        channel(for: conversationID)
    }

    func runtimeCapabilities() async throws -> RuntimeCapabilitySnapshot {
        guard let capabilitySnapshot else { throw TestError.unavailable }
        return capabilitySnapshot
    }

    func activitySnapshot() async throws -> RuntimeActivitySnapshot {
        activitySnapshotRequestCount += 1
        guard let activity else { throw TestError.unavailable }
        return activity
    }

    func createConversation(workspacePath: String) async throws -> ConversationRef {
        ConversationRef(id: UUID().uuidString, workspacePath: workspacePath)
    }
    func listConversations() async throws -> [ConversationRef] { [] }
    func renameConversation(id: String, name: String) async throws -> ConversationRef {
        ConversationRef(id: id, workspacePath: "", name: name)
    }

    func connect(conversationID: String, since: Int) async throws -> AsyncStream<AgentEvent> {
        try await channel(for: conversationID).connect(since: since)
    }
    func send(input: AgentInput) async {}
    func registerTools(_ tools: [ClientToolInfo]) async {}
    func sendApproval(id: String, approved: Bool) async {}
    func sendApproval(id: String, decision: String, scope: String?) async {}
    func sendPlanApproval(id: String, approved: Bool) async {}
    func cancelTurn() async {}
    func disconnect() async {}

    func getConversationDetail(id: String) async throws -> ConversationDetail {
        throw TestError.unavailable
    }
    func getMessages(conversationID: String) async throws -> [Message] { [] }
    func getEvents(conversationID: String) async throws -> [AgentEvent] { [] }
}

private enum TestError: Error {
    case unavailable
}
