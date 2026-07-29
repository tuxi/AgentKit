import Foundation
import XCTest
@testable import AgentKit

@MainActor
final class ProviderConnectionsTests: XCTestCase {
    func testStableModelIDIsScopedByConnection() throws {
        let model = ProviderModel(id: "shared/model", displayName: "Shared")
        let first = try makeConnection(id: "company-production", models: [model])
        let second = try makeConnection(id: "company-staging", models: [model])

        let firstDescriptor = UnifiedModelDescriptor(connection: first, model: model)
        let secondDescriptor = UnifiedModelDescriptor(connection: second, model: model)

        XCTAssertNotEqual(firstDescriptor.id, secondDescriptor.id)
        XCTAssertNotEqual(firstDescriptor.runtimeAlias, secondDescriptor.runtimeAlias)
        XCTAssertEqual(firstDescriptor.wireModelID, secondDescriptor.wireModelID)
        XCTAssertFalse(firstDescriptor.runtimeAlias.contains("/"))
    }

    func testRegistryPersistsMultipleConnectionsForSameProvider() throws {
        let suiteName = "ProviderConnectionsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "connections"

        let registry = ProviderConnectionRegistry(defaults: defaults, storageKey: storageKey)
        try registry.upsert(makeConnection(id: "company-production"))
        try registry.upsert(makeConnection(id: "company-staging"))

        let restored = ProviderConnectionRegistry(defaults: defaults, storageKey: storageKey)
        XCTAssertEqual(restored.connections.count, 2)
        XCTAssertEqual(Set(restored.connections.map(\.providerID)), ["openai-compatible"])
    }

    func testUnifiedModelGroupsRemainScopedByConnection() throws {
        let gateway = ProviderConnection.talkifyGateway(
            baseURL: try XCTUnwrap(URL(string: "https://api.objc.com/api/v1/agent")),
            models: [
                ProviderModel(id: "deepseek-v4-flash", displayName: "DeepSeek V4 Flash"),
            ]
        )
        let direct = try makeConnection(
            id: "deepseek",
            models: [
                ProviderModel(id: "deepseek-v4-flash", displayName: "DeepSeek V4 Flash"),
            ]
        )
        let modelSettings = ModelSettingsStore(
            defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
            localStateStore: InMemoryConversationLocalStateStore()
        )
        modelSettings.applyUnifiedCatalog(
            [gateway, direct].unifiedModels,
            defaultModelID: nil
        )

        let groups = modelSettings.unifiedModelGroups
        XCTAssertEqual(groups.map(\.connectionID), ["talkify-gateway", "deepseek"])
        XCTAssertEqual(groups.map(\.name), ["Talkify Gateway", "deepseek"])
        XCTAssertEqual(groups.map(\.models.count), [1, 1])
        XCTAssertNotEqual(groups[0].models[0].id, groups[1].models[0].id)
    }

    func testRuntimeConfigurationContainsAllModelsAndNoSecrets() throws {
        let direct = try makeConnection(
            id: "company-production",
            models: [
                ProviderModel(id: "qwen3-coder", contextWindow: 131_072),
                ProviderModel(id: "deepseek-chat", contextWindow: 128_000),
            ]
        )
        let gateway = ProviderConnection.talkifyGateway(
            baseURL: try XCTUnwrap(URL(string: "https://api.objc.com/api/v1/agent")),
            models: [ProviderModel(id: "gateway-model", displayName: "Gateway Model")]
        )
        let generated = try RuntimeProviderConfigurationBuilder.build(
            connections: [direct, gateway]
        )

        XCTAssertEqual(generated.models.count, 3)
        XCTAssertFalse(generated.configYAML.contains("secret"))
        XCTAssertFalse(generated.configYAML.contains("api-key-value"))

        let root = try jsonObject(generated.configYAML)
        let models = try XCTUnwrap(root["models"] as? [String: Any])
        XCTAssertEqual(models.count, 3)

        let credentials = try XCTUnwrap(root["credentials"] as? [String: Any])
        let llm = try XCTUnwrap(credentials["llm"] as? [String: Any])
        XCTAssertNotNil(llm["company-production"])
        let gatewayCredentials = try XCTUnwrap(credentials["gateway"] as? [String: Any])
        XCTAssertNotNil(gatewayCredentials["default"])

        let web = try XCTUnwrap(root["web"] as? [String: Any])
        let search = try XCTUnwrap(web["search"] as? [String: Any])
        XCTAssertEqual(search["provider"] as? String, "gateway")
    }

    func testRuntimeConfigurationOmitsGatewaySearchWithoutGatewayConnection() throws {
        let direct = try makeConnection(
            id: "direct",
            models: [ProviderModel(id: "deepseek-chat")]
        )
        let generated = try RuntimeProviderConfigurationBuilder.build(connections: [direct])
        let root = try jsonObject(generated.configYAML)
        let web = try XCTUnwrap(root["web"] as? [String: Any])
        XCTAssertNil(web["search"])
        XCTAssertNotNil(web["fetch"])
    }

    func testEmptyRuntimeConfigurationHasNoGatewayOrCallableModel() throws {
        let generated = try RuntimeProviderConfigurationBuilder.buildEmpty()
        let root = try jsonObject(generated.configYAML)
        XCTAssertTrue(generated.isEmptyCatalog)
        XCTAssertNil(generated.defaultModelID)
        XCTAssertEqual(root["default_model"] as? String, "")
        XCTAssertEqual((root["models"] as? [String: Any])?.count, 0)
        XCTAssertEqual((root["credentials"] as? [String: Any])?.count, 0)
        let web = try XCTUnwrap(root["web"] as? [String: Any])
        XCTAssertNil(web["search"])
        XCTAssertNotNil(web["fetch"])
    }

    func testUnifiedModelStoreLazilyMigratesGatewayWireModel() throws {
        let localState = InMemoryConversationLocalStateStore()
        var state = ConversationLocalState()
        state.selectedModelID = "gateway-model"
        try localState.save(state, for: .session("session-1"))

        let modelSettings = ModelSettingsStore(
            defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
            localStateStore: localState
        )
        let gateway = ProviderConnection.talkifyGateway(
            baseURL: try XCTUnwrap(URL(string: "https://api.objc.com/api/v1/agent")),
            models: [ProviderModel(id: "gateway-model", displayName: "Gateway Model")]
        )
        let descriptor = try XCTUnwrap([gateway].unifiedModels.first)
        modelSettings.applyUnifiedCatalog([descriptor], defaultModelID: descriptor.id)

        XCTAssertEqual(modelSettings.getModel(with: "session-1"), descriptor.id)
        XCTAssertEqual(
            try localState.state(for: .session("session-1"))?.selectedModelID,
            descriptor.id
        )
        XCTAssertEqual(modelSettings.runtimeAlias(for: descriptor.id), descriptor.runtimeAlias)
        XCTAssertTrue(modelSettings.isModelAvailable(descriptor.id))
    }

    func testUnknownHistoricalModelIsPreservedAndUnavailable() throws {
        let modelSettings = ModelSettingsStore(
            defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
            localStateStore: InMemoryConversationLocalStateStore()
        )
        modelSettings.applyUnifiedCatalog([], defaultModelID: nil)

        XCTAssertEqual(modelSettings.resolveLegacyModelID("removed-model"), "removed-model")
        XCTAssertFalse(modelSettings.isModelAvailable("removed-model"))
        XCTAssertNil(modelSettings.runtimeAlias(for: "removed-model"))
    }

    func testRemovedStableModelKeepsReadableUnavailablePresentation() throws {
        let suiteName = "ProviderConnectionsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let connection = ProviderConnection.talkifyGateway(
            baseURL: try XCTUnwrap(URL(string: "https://api.objc.com/api/v1/agent")),
            models: [
                ProviderModel(
                    id: "deepseek-v4-flash",
                    displayName: "DeepSeek V4 Flash"
                ),
            ]
        )
        let descriptor = try XCTUnwrap([connection].unifiedModels.first)
        let firstStore = ModelSettingsStore(
            defaults: defaults,
            localStateStore: InMemoryConversationLocalStateStore()
        )
        firstStore.applyUnifiedCatalog([descriptor], defaultModelID: descriptor.id)
        firstStore.applyUnifiedCatalog([], defaultModelID: nil)

        XCTAssertEqual(firstStore.displayName(for: descriptor.id), "DeepSeek V4 Flash")
        XCTAssertEqual(
            firstStore.selectionDisplayName(for: descriptor.id),
            String(
                format: AgentKitLocalized.string("composer.model_unavailable_format"),
                "DeepSeek V4 Flash"
            )
        )
        XCTAssertFalse(firstStore.isModelAvailable(descriptor.id))
        XCTAssertNil(firstStore.runtimeAlias(for: descriptor.id))

        let restoredStore = ModelSettingsStore(
            defaults: defaults,
            localStateStore: InMemoryConversationLocalStateStore()
        )
        XCTAssertEqual(restoredStore.displayName(for: descriptor.id), "DeepSeek V4 Flash")
    }

    func testUnknownStableModelDecodesWireNameWithoutLeakingAlias() throws {
        let modelSettings = ModelSettingsStore(
            defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
            localStateStore: InMemoryConversationLocalStateStore()
        )
        let stableID = UnifiedModelDescriptor.makeRuntimeAlias(
            connectionID: "enterprise.proxy",
            wireModelID: "qwen3-coder-plus"
        )

        XCTAssertEqual(modelSettings.displayName(for: stableID), "qwen3-coder-plus")
        XCTAssertNotEqual(modelSettings.displayName(for: stableID), stableID)
    }

    func testPrivateNetworkHTTPRequiresExplicitConsent() throws {
        let url = try XCTUnwrap(URL(string: "http://192.168.1.10:11434"))
        let denied = ProviderConnection(
            providerID: "ollama",
            displayName: "LAN Ollama",
            transport: .ollama,
            authentication: .none,
            baseURL: url,
            models: [ProviderModel(id: "qwen")]
        )
        XCTAssertThrowsError(try denied.validate())

        var allowed = denied
        allowed.allowsInsecurePrivateNetworkHTTP = true
        XCTAssertNoThrow(try allowed.validate())
    }

    func testRuntimeConfigurationWaitsForActiveTurnAndCoalesces() async throws {
        let queue = RuntimeProviderConfigurationApplyQueue()
        let first = try RuntimeProviderConfigurationBuilder.buildEmpty()
        let second = try RuntimeProviderConfigurationBuilder.buildEmpty()
        _ = await queue.stage(first)
        let latestRevision = await queue.stage(second)

        let busy = RuntimeActivitySnapshot(sessions: [
            RuntimeSessionActivity(
                sessionID: "session",
                activeTurnID: "turn",
                state: "running"
            )
        ])
        let idle = RuntimeActivitySnapshot(sessions: [])

        let whileBusy = await queue.configurationIfRuntimeIdle(busy)
        XCTAssertNil(whileBusy)
        let ready = await queue.configurationIfRuntimeIdle(idle)
        XCTAssertEqual(ready?.revision, latestRevision)
        await queue.markApplied(revision: latestRevision)
        let afterApply = await queue.configurationIfRuntimeIdle(idle)
        XCTAssertNil(afterApply)
    }

    func testCredentialTargetRoundTripsEscapedConnectionID() throws {
        let target = CredentialTarget.llm("enterprise/a model")
        XCTAssertTrue(target.id.contains("%2F"))
        XCTAssertEqual(CredentialTarget(id: target.id), target)
    }

    private func makeConnection(
        id: String,
        models: [ProviderModel] = [ProviderModel(id: "model")]
    ) throws -> ProviderConnection {
        let connection = ProviderConnection(
            id: id,
            providerID: "openai-compatible",
            displayName: id,
            transport: .openAIChatCompletions,
            authentication: .apiKey,
            baseURL: try XCTUnwrap(URL(string: "https://llm.example.com/v1")),
            models: models
        )
        try connection.validate()
        return connection
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
