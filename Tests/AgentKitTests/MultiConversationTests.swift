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
    func testTurnDispatchRefreshesCapabilitiesAfterRuntimeRestart() async throws {
        let capabilities = RuntimeCapabilitySnapshot(capabilities: [
            "multi_session_execution_v1": true,
            "session_scoped_client_tools_v1": true,
            "activity_snapshot_v1": true,
            "workspace_execution_policy_v1": true,
        ])
        let client = MultiSessionRuntimeClient(capabilitySnapshot: capabilities)
        let store = WorkspaceStore(client: client)
        let a = ConversationRef(id: "a", workspacePath: "/tmp/a")
        let b = ConversationRef(id: "b", workspacePath: "/tmp/b")

        store.selectedConversation = a
        try await Task.sleep(for: .milliseconds(25))
        let controllerA = try XCTUnwrap(store.activeConversationViewModel)
        await controllerA.send(input: .text("a"))

        store.selectedConversation = b
        try await Task.sleep(for: .milliseconds(25))
        let controllerB = try XCTUnwrap(store.activeConversationViewModel)
        await controllerB.send(input: .text("b"))
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(client.channel(for: "a").sentInputs.count, 1)
        XCTAssertEqual(client.channel(for: "b").sentInputs.count, 1)
        XCTAssertGreaterThanOrEqual(client.capabilitySnapshotRequestCount, 2)
    }

    @MainActor
    func testManagedWorktreeDraftSendsOptInIdempotentCreateRequest() async throws {
        let capabilities = RuntimeCapabilitySnapshot(capabilities: [
            "multi_session_execution_v1": true,
            "session_scoped_client_tools_v1": true,
            "activity_snapshot_v1": true,
            "workspace_execution_policy_v1": true,
            "managed_worktree_v1": true,
        ])
        let client = MultiSessionRuntimeClient(
            capabilitySnapshot: capabilities,
            activity: RuntimeActivitySnapshot(sessions: [])
        )
        let store = WorkspaceStore(client: client)
        await store.refreshRuntimeState()
        store.beginDraft()
        store.selectWorkspace(Workspace(
            url: URL(fileURLWithPath: "/tmp/AgentKit"),
            branch: "main"
        ))
        store.setDraftManagedWorktreeEnabled(true)
        store.setDraftManagedWorktreeBaseRef(.fresh)
        let clientRequestID = try XCTUnwrap(store.draft?.clientRequestID)
        let suggestedName = try XCTUnwrap(store.draft?.managedWorktreeSuggestedName)

        await store.commitDraft(firstMessage: "Fix authentication", model: "test-model")

        let request = try XCTUnwrap(client.createRequests.first)
        XCTAssertEqual(request.clientRequestID, clientRequestID)
        XCTAssertEqual(request.workspacePath, "/tmp/AgentKit")
        XCTAssertEqual(request.executionPolicy, .isolatedWorktree)
        XCTAssertEqual(request.workspaceID, "/tmp/AgentKit")
        XCTAssertEqual(request.baseWorkspaceID, "/tmp/AgentKit")
        XCTAssertEqual(request.worktree?.managed, true)
        XCTAssertEqual(request.worktree?.suggestedName, suggestedName)
        XCTAssertFalse(suggestedName.contains("Fix authentication"))
        XCTAssertTrue(suggestedName.allSatisfy {
            $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-")
        })
        XCTAssertEqual(request.worktree?.baseRef, .fresh)
        XCTAssertEqual(store.selectedConversation?.worktree?.state, "ready")
    }

    @MainActor
    func testManagedWorktreeDraftCannotEnableWithoutCapability() async {
        let client = MultiSessionRuntimeClient()
        let store = WorkspaceStore(client: client)
        store.beginDraft()
        store.selectWorkspace(Workspace(
            url: URL(fileURLWithPath: "/tmp/AgentKit"),
            branch: "main"
        ))

        store.setDraftManagedWorktreeEnabled(true)

        XCTAssertFalse(store.draft?.usesManagedWorktree ?? true)
    }

    func testManagedWorktreeSuggestedNameIsReadableAndStableWithinDraft() {
        let draft = SessionDraft(
            workspace: Workspace(url: URL(fileURLWithPath: "/tmp/project"), branch: "main")
        )

        let components = draft.managedWorktreeSuggestedName.split(separator: "-")
        XCTAssertEqual(components.count, 2)
        XCTAssertEqual(draft.managedWorktreeSuggestedName, draft.managedWorktreeSuggestedName)
        XCTAssertTrue(draft.managedWorktreeSuggestedName.allSatisfy {
            $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-")
        })
    }

    @MainActor
    func testManagedWorktreeCapabilityDiscoveryIsNotConflatedWithLegacy() async {
        let capabilities = RuntimeCapabilitySnapshot(capabilities: [
            "workspace_execution_policy_v1": true,
            "managed_worktree_v1": true,
        ])
        let availableStore = WorkspaceStore(client: MultiSessionRuntimeClient(
            capabilitySnapshot: capabilities,
            activity: RuntimeActivitySnapshot(sessions: [])
        ))

        XCTAssertEqual(availableStore.runtimeCapabilityDiscoveryState, .idle)
        await availableStore.refreshRuntimeState()
        XCTAssertEqual(availableStore.runtimeCapabilityDiscoveryState, .available)
        XCTAssertTrue(availableStore.supportsManagedWorktreeCreation)

        let unavailableStore = WorkspaceStore(client: MultiSessionRuntimeClient())
        await unavailableStore.refreshRuntimeState()
        XCTAssertEqual(unavailableStore.runtimeCapabilityDiscoveryState, .unavailable)
        XCTAssertFalse(unavailableStore.supportsManagedWorktreeCreation)
        XCTAssertNotNil(unavailableStore.runtimeCapabilityErrorMessage)
    }

    @MainActor
    func testRuntimeCapabilityAllowsManagedWorktreeWhenLocalBranchProbeIsUnavailable() async {
        let capabilities = RuntimeCapabilitySnapshot(capabilities: [
            "workspace_execution_policy_v1": true,
            "managed_worktree_v1": true,
        ])
        let store = WorkspaceStore(client: MultiSessionRuntimeClient(
            capabilitySnapshot: capabilities,
            activity: RuntimeActivitySnapshot(sessions: [])
        ))
        await store.refreshRuntimeState()
        store.beginDraft()
        store.selectWorkspace(Workspace(
            url: URL(fileURLWithPath: "/sandboxed/project"),
            branch: nil
        ))

        store.setDraftManagedWorktreeEnabled(true)

        XCTAssertTrue(store.draft?.usesManagedWorktree == true)
    }

    @MainActor
    func testManagedWorktreeDeleteRequiresExplicitDirtyForceThenDeletesConversation() async throws {
        let client = MultiSessionRuntimeClient()
        let store = WorkspaceStore(client: client)
        let conversation = ConversationRef(
            id: "managed-delete",
            workspacePath: "/tmp/AgentKit/.codeagent/worktrees/delete-a31f",
            worktree: ManagedWorktreeMetadata(
                managed: true,
                branch: "codeagent/delete-a31f",
                state: "ready"
            )
        )
        store.listViewModel.prepend(conversation)
        client.removeManagedWorktreeError = ManagedWorktreeRemovalError(
            code: "worktree_dirty",
            message: "managed worktree has dirty changes",
            sessionID: conversation.id,
            summary: ManagedWorktreeDirtySummary(
                modifiedFiles: 2,
                untrackedFiles: 1,
                newCommits: 3
            )
        )

        do {
            try await store.deleteConversation(
                conversation,
                worktreeDisposition: .remove
            )
            XCTFail("expected dirty conflict")
        } catch let error as ManagedWorktreeRemovalError {
            XCTAssertTrue(error.isDirtyConflict)
            XCTAssertEqual(error.summary?.newCommits, 3)
        }
        XCTAssertTrue(store.listViewModel.conversations.contains { $0.id == conversation.id })
        XCTAssertTrue(client.deletedConversationIDs.isEmpty)

        client.removeManagedWorktreeError = nil
        try await store.deleteConversation(
            conversation,
            worktreeDisposition: .remove,
            forceWorktreeRemoval: true
        )

        XCTAssertEqual(client.removeManagedWorktreeRequests.map(\.force), [false, true])
        XCTAssertEqual(client.deletedConversationIDs, [conversation.id])
        XCTAssertEqual(client.operationLog.suffix(2), ["remove:managed-delete", "delete:managed-delete"])
        XCTAssertFalse(store.listViewModel.conversations.contains { $0.id == conversation.id })
    }

    @MainActor
    func testDeleteManagedConversationCanKeepWorktree() async throws {
        let client = MultiSessionRuntimeClient()
        let store = WorkspaceStore(client: client)
        let conversation = ConversationRef(
            id: "managed-keep",
            workspacePath: "/tmp/worktree",
            worktree: ManagedWorktreeMetadata(managed: true, state: "ready")
        )
        store.listViewModel.prepend(conversation)

        try await store.deleteConversation(conversation, worktreeDisposition: .keep)

        XCTAssertTrue(client.removeManagedWorktreeRequests.isEmpty)
        XCTAssertEqual(client.deletedConversationIDs, [conversation.id])
    }

    @MainActor
    func testActiveConversationCannotBeDeleted() async throws {
        let client = MultiSessionRuntimeClient()
        let store = WorkspaceStore(client: client)
        let conversation = ConversationRef(
            id: "active-delete",
            workspacePath: "/tmp/AgentKit",
            turnStatus: "running"
        )
        store.listViewModel.prepend(conversation)

        do {
            try await store.deleteConversation(conversation, worktreeDisposition: .keep)
            XCTFail("expected active deletion rejection")
        } catch is ConversationDeletionError {
            // Expected: deleting the repository row underneath a live executor is unsafe.
        }

        XCTAssertTrue(client.deletedConversationIDs.isEmpty)
        XCTAssertTrue(store.listViewModel.conversations.contains { $0.id == conversation.id })
    }

    @MainActor
    func testArchiveAndRestoreMoveRuntimeOwnedPartitionsAndPreserveWorktree() async throws {
        let capabilities = RuntimeCapabilitySnapshot(capabilities: [
            "activity_snapshot_v1": true,
            "conversation_archive_v1": true,
        ])
        let client = MultiSessionRuntimeClient(
            capabilitySnapshot: capabilities,
            activity: RuntimeActivitySnapshot(sessions: [])
        )
        let store = WorkspaceStore(client: client)
        let conversation = ConversationRef(
            id: "archive-me",
            workspacePath: "/tmp/AgentKit/.codeagent/worktrees/archive-me-a31f",
            name: "Archive me",
            worktree: ManagedWorktreeMetadata(
                managed: true,
                branch: "codeagent/archive-me-a31f",
                state: "ready"
            )
        )
        store.listViewModel.prepend(conversation)
        await store.refreshRuntimeState()
        store.selectedConversation = conversation
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertTrue(client.channel(for: conversation.id).isConnected)

        let archived = try await store.archiveConversation(conversation)
        try await Task.sleep(for: .milliseconds(25))

        XCTAssertTrue(archived.isArchived)
        XCTAssertEqual(archived.worktree, conversation.worktree)
        XCTAssertFalse(store.listViewModel.conversations.contains { $0.id == conversation.id })
        XCTAssertEqual(store.listViewModel.archivedConversations.map(\.id), [conversation.id])
        XCTAssertEqual(client.archivedConversationIDs, [conversation.id])
        XCTAssertEqual(client.channel(for: conversation.id).disconnectCount, 1)
        XCTAssertTrue(store.selectedConversation?.isArchived == true)
        XCTAssertTrue(store.activeConversationViewModel?.isArchived == true)
        XCTAssertFalse(client.channel(for: conversation.id).isConnected)

        let restored = try await store.restoreConversation(archived)
        try await Task.sleep(for: .milliseconds(25))

        XCTAssertFalse(restored.isArchived)
        XCTAssertEqual(restored.worktree, conversation.worktree)
        XCTAssertEqual(store.listViewModel.conversations.first?.id, conversation.id)
        XCTAssertTrue(store.listViewModel.archivedConversations.isEmpty)
        XCTAssertEqual(client.restoredConversationIDs, [conversation.id])
        XCTAssertTrue(client.channel(for: conversation.id).isConnected)
        store.supervisor.stopActivityMonitoring()
    }

    @MainActor
    func testArchiveIsCapabilityGatedAndRejectsActiveConversationLocally() async throws {
        let conversation = ConversationRef(id: "archive-running", workspacePath: "/tmp/project")
        let unsupportedStore = WorkspaceStore(client: MultiSessionRuntimeClient())
        unsupportedStore.listViewModel.prepend(conversation)

        do {
            _ = try await unsupportedStore.archiveConversation(conversation)
            XCTFail("expected capability rejection")
        } catch let error as ConversationArchiveError {
            XCTAssertEqual(error, .notSupported)
        }

        let capabilities = RuntimeCapabilitySnapshot(capabilities: [
            "activity_snapshot_v1": true,
            "conversation_archive_v1": true,
        ])
        let client = MultiSessionRuntimeClient(
            capabilitySnapshot: capabilities,
            activity: RuntimeActivitySnapshot(sessions: [
                RuntimeSessionActivity(sessionID: conversation.id, state: "running")
            ])
        )
        let store = WorkspaceStore(client: client)
        store.listViewModel.prepend(conversation)
        await store.refreshRuntimeState()

        do {
            _ = try await store.archiveConversation(conversation)
            XCTFail("expected active archive rejection")
        } catch let error as ConversationArchiveError {
            XCTAssertEqual(error, .inUse(state: ConversationActivityState.running.rawValue))
        }
        XCTAssertTrue(client.archivedConversationIDs.isEmpty)
        store.supervisor.stopActivityMonitoring()
    }

    @MainActor
    func testRefreshMovesExternallyArchivedSelectionToReadOnlyController() async throws {
        let capabilities = RuntimeCapabilitySnapshot(capabilities: [
            "activity_snapshot_v1": true,
            "conversation_archive_v1": true,
        ])
        let conversation = ConversationRef(id: "external-archive", workspacePath: "/tmp/project")
        let client = MultiSessionRuntimeClient(
            capabilitySnapshot: capabilities,
            activity: RuntimeActivitySnapshot(sessions: []),
            activeConversations: [conversation]
        )
        let store = WorkspaceStore(client: client)
        await store.listViewModel.refresh()
        await store.refreshRuntimeState()
        store.selectedConversation = conversation
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertTrue(client.channel(for: conversation.id).isConnected)

        let archived = conversation.withArchivedAt("2026-07-14T10:00:00Z")
        client.setConversationLists(active: [], archived: [archived])
        await store.listViewModel.refresh()
        await store.refreshRuntimeState()
        try await Task.sleep(for: .milliseconds(25))

        XCTAssertTrue(store.selectedConversation?.isArchived == true)
        XCTAssertTrue(store.activeConversationViewModel?.isArchived == true)
        XCTAssertFalse(client.channel(for: conversation.id).isConnected)
        XCTAssertEqual(client.channel(for: conversation.id).disconnectCount, 1)
        store.supervisor.stopActivityMonitoring()
    }

    @MainActor
    func testRuntimeQueueIsNotReportedAsUnsupportedParallelism() async throws {
        let client = MultiSessionRuntimeClient()
        let store = WorkspaceStore(client: client)
        let conversation = ConversationRef(id: "queued", workspacePath: "/tmp/shared")

        store.selectedConversation = conversation
        try await Task.sleep(for: .milliseconds(25))
        let controller = try XCTUnwrap(store.activeConversationViewModel)
        client.channel(for: "queued").yield(.turnQueued(
            turnID: "turn_queued",
            reason: "workspace_lease",
            position: 2
        ))
        try await Task.sleep(for: .milliseconds(25))

        XCTAssertEqual(controller.lifecycleStatus, "queued")
        XCTAssertEqual(controller.queueReason, "workspace_lease")
        XCTAssertEqual(controller.queuePosition, 2)
        XCTAssertEqual(store.supervisor.queueReason(for: conversation.id), "workspace_lease")
        XCTAssertEqual(controller.runtimeQueueDescription, "已排队（第 2 位）— 等待主工作区释放")
        XCTAssertFalse(controller.runtimeQueueDescription.contains("不支持跨会话并行"))

        client.channel(for: "queued").yield(.turnQueued(
            turnID: "turn_queued",
            reason: "global_capacity",
            position: 1
        ))
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(controller.runtimeQueueDescription, "已排队（第 1 位）— 等待 Runtime 执行槽位")

        client.channel(for: "queued").yield(.turnQueued(
            turnID: "turn_queued",
            reason: "session_serialization",
            position: 1
        ))
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(controller.runtimeQueueDescription, "已排队（第 1 位）— 等待当前会话的上一轮完成")
    }

    @MainActor
    func testQueuedActivityRestoresReasonAndPositionIntoBackgroundController() async throws {
        let capabilities = RuntimeCapabilitySnapshot(capabilities: [
            "multi_session_execution_v1": true,
            "session_scoped_client_tools_v1": true,
            "activity_snapshot_v1": true,
            "session_attention_snapshot_v1": true,
            "workspace_execution_policy_v1": true,
        ])
        let conversation = ConversationRef(id: "queued-background", workspacePath: "/tmp/shared")
        let client = MultiSessionRuntimeClient(
            capabilitySnapshot: capabilities,
            activity: RuntimeActivitySnapshot(sessions: [
                RuntimeSessionActivity(
                    sessionID: conversation.id,
                    turnID: "turn_queued",
                    state: "queued",
                    queuePosition: 2,
                    queueReason: "workspace_lease"
                )
            ])
        )
        let store = WorkspaceStore(client: client)
        store.listViewModel.prepend(conversation)

        await store.refreshRuntimeState()

        let controller = try XCTUnwrap(store.supervisor.controller(sessionID: conversation.id))
        XCTAssertEqual(controller.lifecycleStatus, "queued")
        XCTAssertEqual(controller.queuePosition, 2)
        XCTAssertEqual(controller.queueReason, "workspace_lease")
        XCTAssertEqual(controller.runtimeQueueDescription, "已排队（第 2 位）— 等待主工作区释放")
    }

    @MainActor
    func testStaleQueuedActivityCannotOverrideLiveTerminalEvent() async throws {
        let capabilities = RuntimeCapabilitySnapshot(capabilities: [
            "multi_session_execution_v1": true,
            "session_scoped_client_tools_v1": true,
            "activity_snapshot_v1": true,
            "session_attention_snapshot_v1": true,
            "workspace_execution_policy_v1": true,
        ])
        let conversation = ConversationRef(id: "terminal-wins", workspacePath: "/tmp/shared")
        let client = MultiSessionRuntimeClient(
            capabilitySnapshot: capabilities,
            activity: RuntimeActivitySnapshot(sessions: [])
        )
        let store = WorkspaceStore(client: client)

        store.selectedConversation = conversation
        try await Task.sleep(for: .milliseconds(25))
        let controller = try XCTUnwrap(store.activeConversationViewModel)
        client.channel(for: conversation.id).yield(.turnFinished(
            turnID: "turn_live",
            text: "done",
            textAnnotations: []
        ))
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(controller.lifecycleStatus, "done")

        client.setActivity(RuntimeActivitySnapshot(sessions: [
            RuntimeSessionActivity(
                sessionID: conversation.id,
                turnID: "turn_live",
                state: "queued",
                lastSequence: 1,
                queuePosition: 1,
                queueReason: "global_capacity"
            )
        ]))
        await store.supervisor.refreshRuntimeState(conversations: [conversation])

        XCTAssertEqual(controller.lifecycleStatus, "done")
        XCTAssertNil(controller.queueReason)
        XCTAssertNil(controller.queuePosition)
        store.supervisor.stopActivityMonitoring()
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

    @MainActor
    func testConversationRefLifecycleIsUsedBeforeControllerAttachment() {
        let store = WorkspaceStore(
            client: MultiSessionRuntimeClient(),
            attentionReadStore: InMemoryAttentionReadStore()
        )

        XCTAssertEqual(
            store.supervisor.activity(for: ConversationRef(
                id: "failed",
                workspacePath: "",
                turnStatus: "failed"
            )),
            .failed
        )
        XCTAssertEqual(
            store.supervisor.activity(for: ConversationRef(
                id: "running",
                workspacePath: "",
                turnStatus: "running"
            )),
            .running
        )
    }

    @MainActor
    func testAttentionSnapshotBaselinesHistoryThenSurfacesAndReadsNewTerminal() async {
        let capabilities = attentionCapabilities()
        let readStore = InMemoryAttentionReadStore()
        let client = MultiSessionRuntimeClient(
            capabilitySnapshot: capabilities,
            activity: RuntimeActivitySnapshot(sessions: [
                terminalActivity(sessionID: "background", turnID: "old", sequence: 10)
            ])
        )
        var events: [ConversationAttentionEvent] = []
        let store = WorkspaceStore(
            client: client,
            attentionReadStore: readStore,
            onAttentionEvent: { events.append($0) }
        )
        let conversation = ConversationRef(
            id: "background",
            workspacePath: "/tmp/background",
            turnStatus: "failed"
        )

        await store.supervisor.refreshRuntimeState(conversations: [conversation])
        XCTAssertEqual(store.supervisor.activity(for: conversation), .idle)
        XCTAssertTrue(store.supervisor.unreadTerminals.isEmpty)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(readStore.lastSeenTerminalSequence(for: "background"), 10)

        client.setActivity(RuntimeActivitySnapshot(sessions: [
            terminalActivity(sessionID: "background", turnID: "new", sequence: 20)
        ]))
        await store.supervisor.refreshRuntimeState(conversations: [conversation])

        XCTAssertEqual(store.supervisor.activity(for: conversation), .succeeded)
        XCTAssertEqual(store.supervisor.unreadTerminals["background"]?.turnID, "new")
        XCTAssertEqual(events, [.turnCompleted(ConversationTerminalAttention(
            sessionID: "background",
            turnID: "new",
            outcome: .succeeded,
            sequence: 20,
            occurredAt: "2026-07-13T12:00:00Z"
        ))])

        store.selectedConversation = conversation
        XCTAssertEqual(store.supervisor.activity(for: conversation), .idle)
        XCTAssertNil(store.supervisor.unreadTerminals["background"])
        XCTAssertEqual(readStore.lastSeenTerminalSequence(for: "background"), 20)

        store.selectedConversation = nil
        XCTAssertEqual(store.supervisor.activity(for: conversation), .idle)

        client.setActivity(RuntimeActivitySnapshot(sessions: [
            terminalActivity(
                sessionID: "background",
                turnID: "failed-turn",
                sequence: 30,
                kind: "turn_failed"
            )
        ]))
        await store.supervisor.refreshRuntimeState(conversations: [conversation])
        XCTAssertEqual(store.supervisor.activity(for: conversation), .failed)
        XCTAssertEqual(store.supervisor.unreadTerminals["background"]?.outcome, .failed)
        XCTAssertEqual(events.last, .turnCompleted(ConversationTerminalAttention(
            sessionID: "background",
            turnID: "failed-turn",
            outcome: .failed,
            sequence: 30,
            occurredAt: "2026-07-13T12:00:00Z"
        )))
    }

    @MainActor
    func testApprovalAttentionReattachesAndNotifiesOnlyOnce() async {
        let readStore = InMemoryAttentionReadStore()
        readStore.establishBaseline()
        let client = MultiSessionRuntimeClient(
            capabilitySnapshot: attentionCapabilities(),
            activity: RuntimeActivitySnapshot(sessions: [
                RuntimeSessionActivity(
                    sessionID: "approval",
                    turnID: "turn_approval",
                    activeTurnID: "turn_approval",
                    state: "waiting_approval",
                    lastSequence: 42,
                    pendingApprovalCount: 1
                )
            ])
        )
        var events: [ConversationAttentionEvent] = []
        let store = WorkspaceStore(
            client: client,
            attentionReadStore: readStore,
            onAttentionEvent: { events.append($0) }
        )
        let conversation = ConversationRef(id: "approval", workspacePath: "/tmp/approval")

        await store.supervisor.refreshRuntimeState(conversations: [conversation])
        await store.supervisor.refreshRuntimeState(conversations: [conversation])

        XCTAssertEqual(store.supervisor.activity(for: conversation), .waitingForApproval)
        XCTAssertTrue(client.channel(for: "approval").isConnected)
        XCTAssertEqual(events, [.approvalRequired(
            sessionID: "approval",
            turnID: "turn_approval",
            pendingCount: 1,
            sequence: 42
        )])
    }

    @MainActor
    func testIncrementalAttentionMergesWithoutDroppingUnchangedRunningSession() async {
        let capabilities = attentionCapabilities()
        let client = MultiSessionRuntimeClient(
            capabilitySnapshot: capabilities,
            activity: RuntimeActivitySnapshot(
                cursor: 10,
                sessions: [RuntimeSessionActivity(sessionID: "running", turnID: "turn_a", state: "running")]
            )
        )
        let store = WorkspaceStore(
            client: client,
            attentionReadStore: InMemoryAttentionReadStore()
        )
        let running = ConversationRef(id: "running", workspacePath: "/tmp/a")
        let completed = ConversationRef(id: "completed", workspacePath: "/tmp/b")

        await store.supervisor.refreshRuntimeState(conversations: [running, completed])
        client.setActivity(RuntimeActivitySnapshot(
            cursor: 12,
            isDelta: true,
            sessions: [terminalActivity(sessionID: "completed", turnID: "turn_b", sequence: 12)]
        ))
        await store.supervisor.refreshRuntimeState(conversations: [running, completed])

        XCTAssertEqual(client.activitySnapshotCursors.count, 2)
        XCTAssertNil(client.activitySnapshotCursors[0])
        XCTAssertEqual(client.activitySnapshotCursors[1], 10)
        XCTAssertEqual(store.supervisor.runtimeActivities["running"]?.state, "running")
        XCTAssertEqual(store.supervisor.runtimeActivities["completed"]?.latestTerminal?.sequence, 12)
        store.supervisor.stopActivityMonitoring()
    }

    @MainActor
    func testAttentionCursorRollbackForcesFullBaseline() async {
        let client = MultiSessionRuntimeClient(
            capabilitySnapshot: attentionCapabilities(),
            activity: RuntimeActivitySnapshot(
                cursor: 10,
                sessions: [RuntimeSessionActivity(sessionID: "old", state: "running")]
            )
        )
        let store = WorkspaceStore(
            client: client,
            attentionReadStore: InMemoryAttentionReadStore()
        )
        let old = ConversationRef(id: "old", workspacePath: "")
        let reset = ConversationRef(id: "reset", workspacePath: "")
        await store.supervisor.refreshRuntimeState(conversations: [old, reset])

        client.enqueueActivities([
            RuntimeActivitySnapshot(cursor: 2, isDelta: true, sessions: []),
            RuntimeActivitySnapshot(
                cursor: 2,
                sessions: [RuntimeSessionActivity(sessionID: "reset", state: "paused")]
            ),
        ])
        await store.supervisor.refreshRuntimeState(conversations: [old, reset])

        XCTAssertEqual(client.activitySnapshotCursors.count, 3)
        XCTAssertEqual(client.activitySnapshotCursors[1], 10)
        XCTAssertNil(client.activitySnapshotCursors[2])
        XCTAssertNil(store.supervisor.runtimeActivities["old"])
        XCTAssertEqual(store.supervisor.runtimeActivities["reset"]?.state, "paused")
        store.supervisor.stopActivityMonitoring()
    }

    @MainActor
    func testControllerLimitEvictsLeastRecentlyUsedIdleController() async {
        let capabilities = RuntimeCapabilitySnapshot(
            capabilities: ["activity_snapshot_v1": true],
            limits: RuntimeLimits(maxConcurrentTurns: 1, maxConnectedSessions: 2)
        )
        let client = MultiSessionRuntimeClient(
            capabilitySnapshot: capabilities,
            activity: RuntimeActivitySnapshot(sessions: [])
        )
        let store = WorkspaceStore(client: client)
        await store.supervisor.refreshRuntimeState(conversations: [])

        _ = store.supervisor.controller(for: ConversationRef(id: "oldest", workspacePath: ""))
        _ = store.supervisor.controller(for: ConversationRef(id: "middle", workspacePath: ""))
        _ = store.supervisor.controller(for: ConversationRef(id: "newest", workspacePath: ""))
        await store.supervisor.enforceControllerLimit()

        XCTAssertNil(store.supervisor.controller(sessionID: "oldest"))
        XCTAssertNotNil(store.supervisor.controller(sessionID: "middle"))
        XCTAssertNotNil(store.supervisor.controller(sessionID: "newest"))
        store.supervisor.stopActivityMonitoring()
    }

    @MainActor
    func testControllerLimitNeverEvictsLiveOrSelectedSession() async {
        let capabilities = RuntimeCapabilitySnapshot(
            capabilities: ["activity_snapshot_v1": true],
            limits: RuntimeLimits(maxConcurrentTurns: 2, maxConnectedSessions: 1)
        )
        let client = MultiSessionRuntimeClient(
            capabilitySnapshot: capabilities,
            activity: RuntimeActivitySnapshot(sessions: [
                RuntimeSessionActivity(sessionID: "live", turnID: "turn_live", state: "running")
            ])
        )
        let store = WorkspaceStore(client: client)
        let live = ConversationRef(id: "live", workspacePath: "/tmp/live")
        await store.supervisor.refreshRuntimeState(conversations: [live])

        store.supervisor.setSelectedSessionID("selected")
        _ = store.supervisor.controller(for: ConversationRef(id: "idle", workspacePath: ""))
        _ = store.supervisor.controller(for: ConversationRef(id: "selected", workspacePath: ""))
        await store.supervisor.enforceControllerLimit()

        XCTAssertNotNil(store.supervisor.controller(sessionID: "live"))
        XCTAssertNotNil(store.supervisor.controller(sessionID: "selected"))
        XCTAssertNil(store.supervisor.controller(sessionID: "idle"))
        store.supervisor.stopActivityMonitoring()
    }
}

private func attentionCapabilities() -> RuntimeCapabilitySnapshot {
    RuntimeCapabilitySnapshot(capabilities: [
        "multi_session_execution_v1": true,
        "session_scoped_client_tools_v1": true,
        "activity_snapshot_v1": true,
        "session_attention_snapshot_v1": true,
        "session_attention_delta_v1": true,
        "workspace_execution_policy_v1": true,
    ])
}

private func terminalActivity(
    sessionID: String,
    turnID: String,
    sequence: Int64,
    kind: String = "turn_finished"
) -> RuntimeSessionActivity {
    RuntimeSessionActivity(
        sessionID: sessionID,
        state: "idle",
        lastSequence: sequence,
        latestTerminal: RuntimeTerminalActivity(
            turnID: turnID,
            kind: kind,
            sequence: sequence,
            at: "2026-07-13T12:00:00Z"
        )
    )
}

private final class MultiSessionChannelDouble: RuntimeSessionChannel, @unchecked Sendable {
    let sessionID: String
    let connectDelay: Duration
    var isConnected = false
    var disconnectCount = 0
    var cancelCount = 0
    var sentInputs: [AgentInput] = []
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

    func send(input: AgentInput) async { sentInputs.append(input) }
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
    func yield(_ event: AgentEvent) { continuation?.yield(event) }
}

private final class MultiSessionRuntimeClient: RuntimeClient, @unchecked Sendable {
    private var channels: [String: MultiSessionChannelDouble] = [:]
    private let connectDelays: [String: Duration]
    private let capabilitySnapshot: RuntimeCapabilitySnapshot?
    private var activity: RuntimeActivitySnapshot?
    private var activeConversations: [ConversationRef]
    private var archivedConversations: [ConversationRef]
    private var queuedActivities: [RuntimeActivitySnapshot] = []
    private(set) var capabilitySnapshotRequestCount = 0
    private(set) var activitySnapshotRequestCount = 0
    private(set) var activitySnapshotCursors: [Int64?] = []
    private(set) var createRequests: [CreateConversationRequest] = []
    private(set) var removeManagedWorktreeRequests: [ManagedWorktreeRemoveRequest] = []
    private(set) var deletedConversationIDs: [String] = []
    private(set) var archivedConversationIDs: [String] = []
    private(set) var restoredConversationIDs: [String] = []
    private(set) var operationLog: [String] = []
    var removeManagedWorktreeError: Error?

    init(
        connectDelays: [String: Duration] = [:],
        capabilitySnapshot: RuntimeCapabilitySnapshot? = nil,
        activity: RuntimeActivitySnapshot? = nil,
        activeConversations: [ConversationRef] = [],
        archivedConversations: [ConversationRef] = []
    ) {
        self.connectDelays = connectDelays
        self.capabilitySnapshot = capabilitySnapshot
        self.activity = activity
        self.activeConversations = activeConversations
        self.archivedConversations = archivedConversations
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
        capabilitySnapshotRequestCount += 1
        guard let capabilitySnapshot else { throw TestError.unavailable }
        return capabilitySnapshot
    }

    func activitySnapshot() async throws -> RuntimeActivitySnapshot {
        activitySnapshotRequestCount += 1
        if !queuedActivities.isEmpty {
            return queuedActivities.removeFirst()
        }
        guard let activity else { throw TestError.unavailable }
        return activity
    }

    func activitySnapshot(sinceSequence: Int64?) async throws -> RuntimeActivitySnapshot {
        activitySnapshotCursors.append(sinceSequence)
        return try await activitySnapshot()
    }

    func setActivity(_ activity: RuntimeActivitySnapshot) {
        self.activity = activity
    }

    func enqueueActivities(_ activities: [RuntimeActivitySnapshot]) {
        queuedActivities.append(contentsOf: activities)
    }

    func setConversationLists(active: [ConversationRef], archived: [ConversationRef]) {
        activeConversations = active
        archivedConversations = archived
    }

    func createConversation(workspacePath: String) async throws -> ConversationRef {
        ConversationRef(id: UUID().uuidString, workspacePath: workspacePath)
    }
    func createConversation(request: CreateConversationRequest) async throws -> ConversationRef {
        createRequests.append(request)
        let id = UUID().uuidString
        if let worktree = request.worktree, worktree.managed {
            let path = request.workspacePath + "/.codeagent/worktrees/test-managed-a31f"
            return ConversationRef(
                id: id,
                workspacePath: path,
                name: worktree.suggestedName,
                executionPolicy: request.executionPolicy?.rawValue,
                workspaceID: path,
                baseWorkspaceID: request.baseWorkspaceID,
                worktree: ManagedWorktreeMetadata(
                    managed: true,
                    name: "test-managed-a31f",
                    branch: "codeagent/test-managed-a31f",
                    baseRef: worktree.baseRef?.rawValue,
                    state: "ready"
                )
            )
        }
        return ConversationRef(
            id: id,
            workspacePath: request.workspacePath,
            executionPolicy: request.executionPolicy?.rawValue,
            workspaceID: request.workspaceID,
            baseWorkspaceID: request.baseWorkspaceID
        )
    }
    func listConversations() async throws -> [ConversationRef] { activeConversations }
    func listArchivedConversations() async throws -> [ConversationRef] { archivedConversations }
    func archiveConversation(id: String) async throws -> ConversationArchiveResponse {
        archivedConversationIDs.append(id)
        operationLog.append("archive:\(id)")
        let archivedAt = "2026-07-14T10:00:00Z"
        if let ref = activeConversations.first(where: { $0.id == id }) {
            activeConversations.removeAll { $0.id == id }
            archivedConversations.removeAll { $0.id == id }
            archivedConversations.append(ref.withArchivedAt(archivedAt))
        }
        return ConversationArchiveResponse(id: id, archivedAt: archivedAt)
    }
    func restoreConversation(id: String) async throws -> ConversationArchiveResponse {
        restoredConversationIDs.append(id)
        operationLog.append("restore:\(id)")
        if let ref = archivedConversations.first(where: { $0.id == id }) {
            archivedConversations.removeAll { $0.id == id }
            activeConversations.removeAll { $0.id == id }
            activeConversations.append(ref.withArchivedAt(nil))
        }
        return ConversationArchiveResponse(id: id)
    }
    func renameConversation(id: String, name: String) async throws -> ConversationRef {
        ConversationRef(id: id, workspacePath: "", name: name)
    }
    func removeManagedWorktree(
        conversationID: String,
        request: ManagedWorktreeRemoveRequest
    ) async throws -> ManagedWorktreeRemoveResponse {
        removeManagedWorktreeRequests.append(request)
        operationLog.append("remove:\(conversationID)")
        if let removeManagedWorktreeError { throw removeManagedWorktreeError }
        return ManagedWorktreeRemoveResponse(
            sessionID: conversationID,
            worktree: ManagedWorktreeMetadata(managed: true, state: "removed")
        )
    }
    func deleteConversation(id: String) async throws {
        operationLog.append("delete:\(id)")
        deletedConversationIDs.append(id)
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

private final class InMemoryAttentionReadStore: ConversationAttentionReadStore, @unchecked Sendable {
    private(set) var hasEstablishedBaseline = false
    private var seen: [String: Int64] = [:]
    private var notifiedTerminal: [String: Int64] = [:]
    private var notifiedApproval: [String: Int64] = [:]

    func establishBaseline() { hasEstablishedBaseline = true }
    func lastSeenTerminalSequence(for sessionID: String) -> Int64? { seen[sessionID] }
    func setLastSeenTerminalSequence(_ sequence: Int64, for sessionID: String) { seen[sessionID] = sequence }
    func lastNotifiedTerminalSequence(for sessionID: String) -> Int64? { notifiedTerminal[sessionID] }
    func setLastNotifiedTerminalSequence(_ sequence: Int64, for sessionID: String) { notifiedTerminal[sessionID] = sequence }
    func lastNotifiedApprovalSequence(for sessionID: String) -> Int64? { notifiedApproval[sessionID] }
    func setLastNotifiedApprovalSequence(_ sequence: Int64, for sessionID: String) { notifiedApproval[sessionID] = sequence }
}
