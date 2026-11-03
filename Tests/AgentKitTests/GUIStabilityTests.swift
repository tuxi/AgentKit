import XCTest
import ClientToolProtocol
@testable import AgentKit

final class GUIStabilityTests: XCTestCase {
    private func event(_ text: String) throws -> AgentEvent {
        let wire = try JSONDecoder().decode(WireFrame.self, from: Data(text.utf8))
        return try XCTUnwrap(AgentEvent.from(wire: wire))
    }

    func testModelAuditReplaysWithoutReplacingConfiguredModel() throws {
        let configured = UnifiedModel(model: "bai/deepseek-flash", reasoningEffort: nil)
        let events = try [
            event(#"{"kind":"model_request","turn_id":"t1","model":"openrouter/free","provider":"openrouter"}"#),
            event(#"{"kind":"model_finished","turn_id":"t1","invocation_id":"i1","model_succeeded":true,"model_selection":{"resolved_model":"openrouter/openrouter/free","actual_model":"upstream/a:free"}}"#),
            event(#"{"kind":"model_finished","turn_id":"t1","invocation_id":"i2","model_succeeded":true,"model_selection":{"actual_model":"upstream/b:free"}}"#),
            event(#"{"kind":"model_request","turn_id":"t1","model":"openrouter/free","provider":"openrouter"}"#),
            event(#"{"kind":"model_finished","turn_id":"t1","invocation_id":"i3","model_succeeded":false,"model_selection":{"actual_model":"failed:model"}}"#),
        ]
        var live = ConversationModelIdentity()
        for e in events { live.apply(e) }
        var replay = ConversationModelIdentity()
        events.forEach { replay.apply($0) }
        XCTAssertEqual(live, replay)
        XCTAssertEqual(replay.resolvedModel, "openrouter/openrouter/free")
        XCTAssertEqual(replay.actualModel, "upstream/b:free")
        XCTAssertEqual(replay.actualInvocationID, "i2")
        XCTAssertEqual(configured.model, "bai/deepseek-flash")
    }

    func testLegacyRequestDoesNotInventActualResponseModel() throws {
        var identity = ConversationModelIdentity()
        identity.apply(try event(#"{"kind":"model_request","model":"legacy/route"}"#))
        identity.apply(try event(#"{"kind":"model_finished","prompt_tokens":1}"#))
        XCTAssertEqual(identity.resolvedModel, "legacy/route")
        XCTAssertNil(identity.actualModel)
    }

    func testAutoApprovalDoesNotInventFileExecutionAndCancelReasonSurvivesReplay() throws {
        var reducer = ExecutionReducer()
        var graph = ExecutionGraph()
        _ = reducer.reduce(.turnStarted(turnID: "t", text: "example"), into: &graph)
        let args: JSONValue = .object(["path": .string("one.py")])
        _ = reducer.reduce(.toolStarted(turnID: "t", callID: "c",
                         tool: ToolCall(callID: "c", toolName: "create_file", toolArgs: args)), into: &graph)
        _ = reducer.reduce(.autoApproved(turnID: "t", toolName: "create_file", toolArgs: args, text: "rule matched"), into: &graph)
        let calls = graph.nodes.values.filter { if case .toolCall = $0.payload { return true }; return false }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.status, .running, "approval cannot report execution success")
        _ = reducer.reduce(.turnCancelled(turnID: "t", reason: "user_requested"), into: &graph)
        _ = reducer.reduce(.turnCancelled(turnID: "t", reason: "user_requested"), into: &graph)
        XCTAssertEqual(graph.nodes["c"]?.status, .cancelled)
        let turn = try XCTUnwrap(TimelineProjection().projectTurns(graph).first)
        let text = turn.blocks.compactMap { block -> String? in
            if case .system(_, let payload) = block { return payload.text }; return nil
        }
        XCTAssertEqual(text.filter { $0.contains("已取消") }, ["已取消 — user_requested"])
    }
}

extension GUIStabilityTests {
    @MainActor
    func testLegacySelectionMigratesToDefaultButPersistedExplicitIsPreserved() throws {
        let settings = ModelSettingsStore(
            defaults: try XCTUnwrap(UserDefaults(suiteName: "GUIStabilityTests.\(UUID().uuidString)")),
            localStateStore: InMemoryConversationLocalStateStore()
        )
        let connection = ProviderConnection.talkifyGateway(
            baseURL: try XCTUnwrap(URL(string: "https://api.objc.com/api/v1/agent")),
            models: [
                ProviderModel(id: "default-flash", displayName: "Default Flash"),
                ProviderModel(id: "explicit-pro", displayName: "Explicit Pro"),
            ]
        )
        let descriptors = [connection].unifiedModels
        settings.applyUnifiedCatalog(descriptors, defaultModelID: descriptors[0].id)

        let legacyDefault = settings.composerSelection(
            selectedModelID: descriptors[0].model,
            storedMode: nil,
            reasoningEffort: nil
        )
        XCTAssertEqual(legacyDefault.mode, .followDefault)
        XCTAssertNil(legacyDefault.wireModelID)

        let legacyExplicit = settings.composerSelection(
            selectedModelID: descriptors[1].model,
            storedMode: nil,
            reasoningEffort: nil
        )
        XCTAssertEqual(legacyExplicit.mode, .followDefault)

        let persistedExplicit = settings.composerSelection(
            selectedModelID: descriptors[0].model,
            storedMode: .explicit,
            storedVersion: ConversationLocalState.currentComposerSelectionVersion,
            reasoningEffort: nil
        )
        XCTAssertEqual(persistedExplicit.mode, .explicit)
        XCTAssertEqual(persistedExplicit.wireModelID, descriptors[0].model)

        let unversionedExplicit = settings.composerSelection(
            selectedModelID: descriptors[0].model,
            storedMode: .explicit,
            storedVersion: nil,
            reasoningEffort: nil
        )
        XCTAssertEqual(unversionedExplicit.mode, .followDefault)
    }

    @MainActor
    func testWorkspaceSendOmitsModelForFollowDefaultCapture() async throws {
        let localState = InMemoryConversationLocalStateStore()
        let client = ModelHistoryClient([])
        let store = WorkspaceStore(client: client, localStateStore: localState)
        let conversation = ConversationRef(id: "wire-session", workspacePath: "/tmp/example")
        let viewModel = ConversationViewModel(
            client: client,
            model: UnifiedModel(model: "", reasoningEffort: nil),
            localStateStore: localState
        )
        await viewModel.connect(to: conversation)

        let accepted = await store.sendUserMessage(
            "follow the default route",
            model: nil,
            reasoningEffort: nil,
            through: viewModel
        )
        XCTAssertTrue(accepted)
        for _ in 0..<100 where client.sentInputs.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let input = try XCTUnwrap(client.sentInputs.last)
        XCTAssertNil(input.model)
        XCTAssertNil(input.reasoningEffort)
        await viewModel.disconnect()
    }

    @MainActor
    func testExternallyCreatedSessionAdoptsContextSnapshotModel() async throws {
        // Simulate an agent-created session: no local state exists, but the
        // Runtime's context snapshot reports the model the agent actually used.
        // The composer should adopt that model as the initial explicit selection.
        let suite = "GUIStabilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let localState = InMemoryConversationLocalStateStore()
        let settings = ModelSettingsStore(defaults: defaults, localStateStore: localState)
        let connection = ProviderConnection.talkifyGateway(
            baseURL: try XCTUnwrap(URL(string: "https://api.objc.com/api/v1/agent")),
            models: [
                ProviderModel(id: "runtime-default", displayName: "Runtime Default"),
                ProviderModel(id: "agent-used-model", displayName: "Agent Used Model"),
            ]
        )
        let descriptors = [connection].unifiedModels
        settings.applyUnifiedCatalog(descriptors, defaultModelID: descriptors[0].id)

        let agentEvents = try [
            event(#"{"kind":"model_request","turn_id":"ext-t1","model":"agent-used-model","provider":"talkify-gateway"}"#),
            event(#"{"kind":"model_finished","turn_id":"ext-t1","invocation_id":"ext-i1","model_succeeded":true,"model_selection":{"resolved_model":"talkify-gateway/agent-used-model","actual_model":"talkify-gateway/agent-used-model"}}"#),
        ]
        let client = ModelHistoryClient(agentEvents)
        // The Runtime reports the model it used in the context snapshot.
        client.contextSnapshot = ConversationContextSnapshot(
            model: ConversationContextModel(
                name: "talkify-gateway/agent-used-model",
                reasoningEffort: nil,
                contextWindow: 128_000,
                compactThreshold: 100_000,
                compactRatio: 0.8
            ),
            current: ConversationContextCurrent(promptTokens: 500, usagePct: 0.4, thresholdPct: 80),
            compaction: ConversationContextCompaction(totalCount: 0, totalSavedTokens: 0, last: nil),
            structure: ConversationContextStructure(messageCount: 2, estimatedTokens: 500, hasSummary: false, summaryChars: 0)
        )

        let store = WorkspaceStore(client: client, localStateStore: localState)
        let conversation = ConversationRef(id: "agent-created-session", workspacePath: "/tmp/example")
        let conversationVM = ConversationViewModel(
            client: client,
            model: UnifiedModel(model: "", reasoningEffort: nil),
            localStateStore: localState
        )
        await conversationVM.connect(to: conversation)

        let composer = DraftComposerPanelViewModel(
            workspaceStore: store,
            modelSettings: settings,
            conversationViewModel: conversationVM,
            isDraft: false,
            isEnabled: true,
            onSend: { _, _, _ in true }
        )
        composer.onAppear()

        // Before the async context arrives, the composer is followDefault.
        // After the context snapshot is received, it should adopt the agent's model.
        for _ in 0..<200 where composer.selectionMode == .followDefault {
            await Task.yield()
        }

        XCTAssertEqual(composer.selectionMode, .explicit)
        XCTAssertEqual(composer.explicitModel?.model, "talkify-gateway/agent-used-model")
        XCTAssertTrue(
            composer.modelButtonTitle.contains("agent-used-model"),
            "composer must show the agent-used model from the context snapshot"
        )

        // Audit identity also reflects the same model.
        XCTAssertEqual(conversationVM.modelIdentity.resolvedModel, "talkify-gateway/agent-used-model")

        // The adopted selection is persisted with a version, so a reopen keeps it.
        let state = try XCTUnwrap(localState.state(for: .session(conversation.id)))
        XCTAssertEqual(state.modelSelectionMode, .explicit)
        XCTAssertEqual(state.composerSelectionVersion, ConversationLocalState.currentComposerSelectionVersion)
        XCTAssertEqual(state.selectedModelID, "talkify-gateway/agent-used-model")

        await conversationVM.disconnect()
    }

    @MainActor
    func testExternallyCreatedSessionWithoutContextStaysFollowDefault() async throws {
        // When the Runtime doesn't provide a context snapshot (unsupported),
        // the composer stays followDefault — no crash, no stale model.
        let suite = "GUIStabilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let localState = InMemoryConversationLocalStateStore()
        let settings = ModelSettingsStore(defaults: defaults, localStateStore: localState)
        let connection = ProviderConnection.talkifyGateway(
            baseURL: try XCTUnwrap(URL(string: "https://api.objc.com/api/v1/agent")),
            models: [
                ProviderModel(id: "runtime-default", displayName: "Runtime Default"),
            ]
        )
        let descriptors = [connection].unifiedModels
        settings.applyUnifiedCatalog(descriptors, defaultModelID: descriptors[0].id)

        let client = ModelHistoryClient([])
        // No contextSnapshot set → getConversationContext throws unsupported.
        let store = WorkspaceStore(client: client, localStateStore: localState)
        let conversation = ConversationRef(id: "no-context-session", workspacePath: "/tmp/example")
        let conversationVM = ConversationViewModel(
            client: client,
            model: UnifiedModel(model: "", reasoningEffort: nil),
            localStateStore: localState
        )
        await conversationVM.connect(to: conversation)

        let composer = DraftComposerPanelViewModel(
            workspaceStore: store,
            modelSettings: settings,
            conversationViewModel: conversationVM,
            isDraft: false,
            isEnabled: true,
            onSend: { _, _, _ in true }
        )
        composer.onAppear()
        // Let the async context refresh complete (it will fail).
        for _ in 0..<200 { await Task.yield() }

        XCTAssertEqual(composer.selectionMode, .followDefault)
        XCTAssertTrue(
            composer.modelButtonTitle.contains(settings.selectionDisplayName(for: descriptors[0].id)),
            "composer must show the Runtime default when context is unavailable"
        )

        await conversationVM.disconnect()
    }

    @MainActor
    func testLegacySessionStateMigratesToFollowDefaultOnComposerRestore() async throws {
        let suite = "GUIStabilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let localState = InMemoryConversationLocalStateStore()
        let settings = ModelSettingsStore(defaults: defaults, localStateStore: localState)
        let connection = ProviderConnection.talkifyGateway(
            baseURL: try XCTUnwrap(URL(string: "https://api.objc.com/api/v1/agent")),
            models: [
                ProviderModel(id: "default-flash", displayName: "Default Flash"),
                ProviderModel(id: "stale-model", displayName: "Stale Model"),
            ]
        )
        let descriptors = [connection].unifiedModels
        settings.applyUnifiedCatalog(descriptors, defaultModelID: descriptors[0].id)

        let conversation = ConversationRef(id: "legacy-session", workspacePath: "/tmp/example")
        try localState.save(
            ConversationLocalState(
                selectedModelID: descriptors[1].model,
                modelSelectionMode: .explicit,
                recentModelIDs: [descriptors[1].model]
            ),
            for: .session(conversation.id)
        )

        let client = ModelHistoryClient([])
        let store = WorkspaceStore(client: client, localStateStore: localState)
        let conversationVM = ConversationViewModel(
            client: client,
            model: UnifiedModel(model: descriptors[1].model, reasoningEffort: nil),
            localStateStore: localState
        )
        await conversationVM.connect(to: conversation)

        let composer = DraftComposerPanelViewModel(
            workspaceStore: store,
            modelSettings: settings,
            conversationViewModel: conversationVM,
            isDraft: false,
            isEnabled: true,
            onSend: { _, _, _ in true }
        )
        composer.onAppear()

        XCTAssertEqual(composer.selectionMode, .followDefault)
        XCTAssertEqual(conversationVM.composerSelectionMode, .followDefault)
        let normalized = try XCTUnwrap(localState.state(for: .session(conversation.id)))
        XCTAssertEqual(normalized.modelSelectionMode, .followDefault)
        XCTAssertNil(normalized.selectedModelID)
        await conversationVM.disconnect()
    }

    @MainActor
    func testComposerFollowsRuntimeDefaultAndOmitsModelOnSend() async throws {
        let suite = "GUIStabilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let localState = InMemoryConversationLocalStateStore()
        let settings = ModelSettingsStore(defaults: defaults, localStateStore: localState)
        let connection = ProviderConnection.talkifyGateway(
            baseURL: try XCTUnwrap(URL(string: "https://api.objc.com/api/v1/agent")),
            models: [
                ProviderModel(id: "default-flash", displayName: "Default Flash"),
                ProviderModel(id: "explicit-pro", displayName: "Explicit Pro"),
            ]
        )
        let descriptors = [connection].unifiedModels
        settings.applyUnifiedCatalog(descriptors, defaultModelID: descriptors[0].id)

        let client = ModelHistoryClient([])
        let store = WorkspaceStore(client: client, localStateStore: localState)
        let conversation = ConversationRef(id: "composer-session", workspacePath: "/tmp/example")
        let conversationVM = ConversationViewModel(
            client: client,
            model: UnifiedModel(model: "", reasoningEffort: nil),
            localStateStore: localState
        )
        await conversationVM.connect(to: conversation)

        var sendCount = 0
        var sentModel: UnifiedModel?
        let composer = DraftComposerPanelViewModel(
            workspaceStore: store,
            modelSettings: settings,
            conversationViewModel: conversationVM,
            isDraft: false,
            isEnabled: true,
            onSend: { _, model, _ in
                sendCount += 1
                sentModel = model
                return true
            }
        )
        composer.onAppear()
        XCTAssertEqual(composer.selectionMode, .followDefault)
        XCTAssertTrue(
            composer.modelButtonTitle.contains(settings.selectionDisplayName(for: descriptors[0].id))
        )

        composer.text = "follow the runtime default"
        composer.send()
        for _ in 0..<100 where sendCount == 0 { await Task.yield() }
        XCTAssertEqual(sendCount, 1)
        XCTAssertNil(sentModel, "follow-default must omit model on the wire")
        let state = try XCTUnwrap(localState.state(for: .session(conversation.id)))
        XCTAssertEqual(state.modelSelectionMode, .followDefault)
        XCTAssertNil(state.selectedModelID)
        XCTAssertNil(state.reasoningEffort)
        await conversationVM.disconnect()
    }

    @MainActor
    func testExplicitComposerSelectionSurvivesRuntimeDefaultSendAndReopen() async throws {
        let suite = "GUIStabilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let localState = InMemoryConversationLocalStateStore()
        let settings = ModelSettingsStore(defaults: defaults, localStateStore: localState)
        let connection = ProviderConnection.talkifyGateway(
            baseURL: try XCTUnwrap(URL(string: "https://api.objc.com/api/v1/agent")),
            models: [
                ProviderModel(id: "default-flash", displayName: "Default Flash"),
                ProviderModel(id: "explicit-pro", displayName: "Explicit Pro"),
            ]
        )
        let descriptors = [connection].unifiedModels
        settings.applyUnifiedCatalog(descriptors, defaultModelID: descriptors[0].id)
        let explicit = descriptors[1].model

        let client = ModelHistoryClient([])
        let store = WorkspaceStore(client: client, localStateStore: localState)
        let conversation = ConversationRef(id: "composer-session", workspacePath: "/tmp/example")
        let conversationVM = ConversationViewModel(
            client: client,
            model: UnifiedModel(model: "", reasoningEffort: nil),
            localStateStore: localState
        )
        await conversationVM.connect(to: conversation)

        var sentModel: UnifiedModel?
        var sendCount = 0
        let composer = DraftComposerPanelViewModel(
            workspaceStore: store,
            modelSettings: settings,
            conversationViewModel: conversationVM,
            isDraft: false,
            isEnabled: true,
            onSend: { _, model, _ in
                sendCount += 1
                sentModel = model
                return true
            }
        )
        composer.onAppear()
        composer.selectModel(explicit, reasoningEffort: nil)
        composer.text = "use the explicit model"
        composer.send()
        for _ in 0..<100 where sendCount == 0 { await Task.yield() }
        XCTAssertEqual(sentModel?.model, explicit)

        let reopened = DraftComposerPanelViewModel(
            workspaceStore: store,
            modelSettings: settings,
            conversationViewModel: conversationVM,
            isDraft: false,
            isEnabled: true,
            onSend: { _, _, _ in true }
        )
        reopened.onAppear()
        XCTAssertEqual(reopened.selectionMode, .explicit)
        XCTAssertEqual(reopened.selectedModel?.model, explicit)
        await conversationVM.disconnect()
    }
}

private final class ModelHistoryClient: RuntimeClient, @unchecked Sendable {
    let history: [AgentEvent]
    private(set) var sentInputs: [AgentInput] = []
    var continuation: AsyncStream<AgentEvent>.Continuation?
    var contextSnapshot: ConversationContextSnapshot?
    init(_ history: [AgentEvent]) { self.history = history }
    func createConversation(workspacePath: String) async throws -> ConversationRef { throw RuntimeHTTPError.unsupported }
    func listConversations() async throws -> [ConversationRef] { [] }
    func renameConversation(id: String, name: String) async throws -> ConversationRef { throw RuntimeHTTPError.unsupported }
    func deleteConversation(id: String) async throws { throw RuntimeHTTPError.unsupported }
    func connect(conversationID: String, since: Int) async throws -> AsyncStream<AgentEvent> {
        AsyncStream { self.continuation = $0 }
    }
    func send(input: AgentInput) async { sentInputs.append(input) }
    func getConversationContext(id: String) async throws -> ConversationContextSnapshot {
        if let contextSnapshot { return contextSnapshot }
        throw RuntimeHTTPError.unsupported
    }
    func registerTools(_ tools: [ClientToolInfo]) async {}
    func sendApproval(id: String, approved: Bool) async { XCTFail("read-only fixture approved") }
    func sendApproval(id: String, decision: String, scope: String?) async { XCTFail("read-only fixture approved") }
    func sendPlanApproval(id: String, approved: Bool) async {}
    func sendAskUserResponse(id: String, selected: [String], notes: String?) async {}
    func cancelTurn() async {}
    func disconnect() async { continuation?.finish() }
    func getConversationDetail(id: String) async throws -> ConversationDetail { throw RuntimeHTTPError.unsupported }
    func getMessages(conversationID: String) async throws -> [Message] { [] }
    func getEvents(conversationID: String) async throws -> [AgentEvent] { history }
}

extension GUIStabilityTests {
    @MainActor
    func testViewModelLoadsHistoryAndLiveAuditWithoutChangingInputSelection() async throws {
        let finished = try event(#"{"kind":"model_finished","turn_id":"t1","invocation_id":"i1","model_selection":{"resolved_model":"openrouter/openrouter/free","actual_model":"upstream/a:free"}}"#)
        let client = ModelHistoryClient([finished])
        let model = UnifiedModel(model: "bai/deepseek-flash", reasoningEffort: nil)
        let vm = ConversationViewModel(client: client, model: model,
                                      localStateStore: InMemoryConversationLocalStateStore())
        await vm.connect(to: ConversationRef(id: "s1", workspacePath: "/tmp/example"))
        XCTAssertEqual(vm.modelIdentity.actualModel, "upstream/a:free")
        XCTAssertEqual(vm.modelIdentity.resolvedModel, "openrouter/openrouter/free")
        XCTAssertEqual(vm.selectedModel, model)
        client.continuation?.yield(try event(#"{"kind":"model_finished","turn_id":"t1","invocation_id":"i2","model_selection":{"resolved_model":"openrouter/openrouter/free","actual_model":"upstream/b:free"}}"#))
        for _ in 0..<100 where vm.modelIdentity.actualModel != "upstream/b:free" { await Task.yield() }
        XCTAssertEqual(vm.modelIdentity.actualModel, "upstream/b:free")
        XCTAssertEqual(vm.selectedModel, model)
        await vm.disconnect()
    }

    @MainActor
    func testCancelledWebPayloadShowsReasonWithoutInternalKindTitle() async throws {
        let engine = RuntimeEngine(sessionID: "s1")
        await engine.importHistory([.turnStarted(turnID: "t1", text: "example"),
                                    .turnCancelled(turnID: "t1", reason: "user_requested")])
        let doc = ConversationWebDocumentBuilder.build(snapshot: await engine.currentSnapshot(), conversationID: "s1")
        let cancelled = try XCTUnwrap(doc.turns.first?.blocks.first { $0.metadata?["type"] == "cancelled" })
        XCTAssertNil(cancelled.title)
        XCTAssertEqual(cancelled.text, "已取消 — user_requested")
    }
}
