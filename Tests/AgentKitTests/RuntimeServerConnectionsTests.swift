import XCTest
@testable import AgentKit

@MainActor
final class RuntimeServerConnectionsTests: XCTestCase {
    func testRegistrySeedsAndPersistsEmbeddedConnection() throws {
        let suite = "RuntimeServerConnectionsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let registry = RuntimeServerRegistry(
            defaults: defaults,
            storageKey: "servers",
            activeStorageKey: "active"
        )
        XCTAssertEqual(registry.connections.map(\.id), [
            RuntimeServerConnection.embeddedID
        ])
        XCTAssertEqual(registry.activeConnectionID, RuntimeServerConnection.embeddedID)
        XCTAssertEqual(registry.activeConnection.kind, .embedded)

        let restored = RuntimeServerRegistry(
            defaults: defaults,
            storageKey: "servers",
            activeStorageKey: "active"
        )
        XCTAssertEqual(restored.connections, registry.connections)
        XCTAssertEqual(restored.activeConnectionID, RuntimeServerConnection.embeddedID)
    }

    func testRegistryDoesNotRemoveEmbeddedOrActiveConnection() throws {
        let registry = makeRegistry()
        XCTAssertThrowsError(
            try registry.remove(connectionID: RuntimeServerConnection.embeddedID)
        ) { error in
            XCTAssertEqual(error as? RuntimeServerRegistryError, .cannotRemoveEmbedded)
        }

        let remote = try RuntimeServerConnection.external(
            id: "workstation",
            displayName: "Workstation",
            endpoint: XCTUnwrap(URL(string: "https://agent.example.com")),
            authentication: .bearer,
            platform: .macOS
        )
        try registry.upsert(remote)
        try registry.setActive(connectionID: remote.id)
        XCTAssertThrowsError(try registry.remove(connectionID: remote.id)) { error in
            XCTAssertEqual(error as? RuntimeServerRegistryError, .cannotRemoveActive)
        }
    }

    func testEndpointClassificationIsPlatformScoped() throws {
        let loopback = try XCTUnwrap(URL(string: "http://127.42.0.1:8797"))
        XCTAssertEqual(
            try RuntimeServerEndpointClassifier.kind(for: loopback, platform: .macOS),
            .local
        )
        XCTAssertThrowsError(
            try RuntimeServerEndpointClassifier.kind(for: loopback, platform: .iOS)
        ) { error in
            XCTAssertEqual(
                error as? RuntimeServerRegistryError,
                .loopbackUnavailableOnIOS
            )
        }

        let remote = try XCTUnwrap(URL(string: "https://mac.example.com:9443"))
        XCTAssertEqual(
            try RuntimeServerEndpointClassifier.kind(for: remote, platform: .iOS),
            .remote
        )
    }

    func testEndpointRejectsCredentialsAndPathPrefix() throws {
        let credentialURL = try XCTUnwrap(URL(string: "https://user:pass@example.com"))
        XCTAssertThrowsError(
            try RuntimeServerEndpointClassifier.validateOrigin(credentialURL)
        )

        let pathURL = try XCTUnwrap(URL(string: "https://example.com/runtime"))
        XCTAssertThrowsError(
            try RuntimeServerEndpointClassifier.validateOrigin(pathURL)
        )
    }

    func testExternalSecurityRequiresTLSAndTokenForRemoteServers() throws {
        XCTAssertThrowsError(
            try RuntimeServerConnection.external(
                id: "remote-http",
                displayName: "Remote HTTP",
                endpoint: XCTUnwrap(URL(string: "http://agent.example.com:8797")),
                authentication: .bearer,
                platform: .macOS
            )
        ) { error in
            XCTAssertEqual(error as? RuntimeServerRegistryError, .tlsRequired)
        }

        XCTAssertThrowsError(
            try RuntimeServerConnection.external(
                id: "remote-anonymous",
                displayName: "Remote Anonymous",
                endpoint: XCTUnwrap(URL(string: "https://agent.example.com")),
                authentication: .none,
                platform: .macOS
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeServerRegistryError,
                .remoteAuthenticationRequired
            )
        }

        XCTAssertNoThrow(
            try RuntimeServerConnection.external(
                id: "local",
                displayName: "Local",
                endpoint: XCTUnwrap(URL(string: "http://127.0.0.1:8797")),
                authentication: .none,
                platform: .macOS
            )
        )
    }

    func testRuntimeEnvironmentPreservesHTTPSOriginAndDerivesWSS() throws {
        let environment = try RuntimeEnvironment(
            origin: XCTUnwrap(URL(string: "https://agent.example.com:9443/"))
        )
        XCTAssertEqual(environment.baseURL?.absoluteString, "https://agent.example.com:9443")
        XCTAssertEqual(environment.wsURL, "wss://agent.example.com:9443")
        XCTAssertEqual(environment.host, "agent.example.com")
        XCTAssertEqual(environment.port, 9443)
    }

    func testConversationIdentityIncludesServerScope() {
        let first = RuntimeConversationIdentity(
            serverConnectionID: "server-a",
            conversationID: "same-session"
        )
        let second = RuntimeConversationIdentity(
            serverConnectionID: "server-b",
            conversationID: "same-session"
        )
        XCTAssertNotEqual(first, second)
    }

    func testRuntimeInfoDecodesLockedWireContract() throws {
        let json = """
        {
          "schema": "runtime-info/v1",
          "server_id": "srv_stable",
          "display_name": "Xiaoyuan Mac",
          "product": "codeagent",
          "runtime_version": "1.3.0",
          "agent_wire_protocol": {
            "major": 1,
            "revision": "1.2"
          },
          "runtime_profile": "headless"
        }
        """
        let info = try JSONDecoder().decode(
            RuntimeServerInfo.self,
            from: try XCTUnwrap(json.data(using: .utf8))
        )
        XCTAssertEqual(info.serverID, "srv_stable")
        XCTAssertEqual(info.agentWireProtocol.major, 1)
        XCTAssertTrue(info.isAgentWireV1Compatible)
    }

    func testRuntimeModelCatalogDecodesLockedWireContract() throws {
        let json = """
        {
          "schema": "runtime-model-catalog/v1",
          "revision": 7,
          "default_runtime_alias": "provider.ZGVlcHNlZWs.model.ZGVlcHNlZWstY2hhdA",
          "connections": [{
            "id": "deepseek",
            "provider_id": "deepseek",
            "display_name": "DeepSeek",
            "billing_source": "server_managed",
            "models": [{
              "runtime_alias": "provider.ZGVlcHNlZWs.model.ZGVlcHNlZWstY2hhdA",
              "wire_model_id": "deepseek-chat",
              "display_name": "DeepSeek Chat",
              "context_window": 64000,
              "supports_tools": true,
              "supports_reasoning": false,
              "input_modalities": ["text"],
              "available": true
            }]
          }]
        }
        """
        let catalog = try JSONDecoder().decode(
            RuntimeServerModelCatalog.self,
            from: try XCTUnwrap(json.data(using: .utf8))
        )
        XCTAssertEqual(catalog.revision, 7)
        XCTAssertEqual(catalog.connections.first?.models.first?.wireModelID, "deepseek-chat")
        XCTAssertTrue(catalog.connections.first?.models.first?.available == true)

        let firstServerModels = catalog.unifiedModels(serverConnectionID: "server-a")
        let secondServerModels = catalog.unifiedModels(serverConnectionID: "server-b")
        XCTAssertEqual(firstServerModels.first?.runtimeAlias, secondServerModels.first?.runtimeAlias)
        XCTAssertNotEqual(firstServerModels.first?.id, secondServerModels.first?.id)
        XCTAssertEqual(firstServerModels.first?.serverConnectionID, "server-a")
        XCTAssertEqual(
            catalog.defaultModelStableID(serverConnectionID: "server-a"),
            firstServerModels.first?.id
        )
        let embeddedModels = catalog.unifiedModels(serverConnectionID: nil)
        XCTAssertEqual(embeddedModels.first?.id, embeddedModels.first?.runtimeAlias)
        XCTAssertNil(embeddedModels.first?.serverConnectionID)
        XCTAssertEqual(
            catalog.defaultModelStableID(serverConnectionID: nil),
            embeddedModels.first?.runtimeAlias
        )
    }

    func testSavingExternalConnectionRejectsUnexpectedIdentityChange() async throws {
        let registry = makeRegistry()
        let credentials = MemoryCredentialStore()
        let coordinator = RuntimeServerCoordinator(
            registry: registry,
            runtimeCredentialStore: credentials,
            platform: .macOS
        )
        let token = String(repeating: "a", count: 32)

        _ = try await coordinator.saveExternalConnection(
            id: "workstation",
            displayName: "Workstation",
            preflight: Self.preflight(serverID: "server-one"),
            accessToken: token
        )

        do {
            _ = try await coordinator.saveExternalConnection(
                id: "workstation",
                displayName: "Workstation",
                preflight: Self.preflight(serverID: "server-two"),
                accessToken: token
            )
            XCTFail("Expected identity confirmation requirement")
        } catch {
            XCTAssertEqual(
                error as? RuntimeServerCoordinatorError,
                .identityConfirmationRequired(
                    expected: "server-one",
                    actual: "server-two"
                )
            )
        }

        let updated = try await coordinator.saveExternalConnection(
            id: "workstation",
            displayName: "Workstation",
            preflight: Self.preflight(serverID: "server-two"),
            accessToken: token,
            confirmIdentityChange: true
        )
        XCTAssertEqual(updated.serverID, "server-two")
    }

    func testSavingSameRuntimeIdentityTwiceIsRejected() async throws {
        let registry = makeRegistry()
        let coordinator = RuntimeServerCoordinator(
            registry: registry,
            runtimeCredentialStore: MemoryCredentialStore(),
            platform: .macOS
        )
        let token = String(repeating: "b", count: 32)
        let preflight = Self.preflight(serverID: "same-runtime")

        _ = try await coordinator.saveExternalConnection(
            id: "first",
            displayName: "First",
            preflight: preflight,
            accessToken: token
        )

        do {
            _ = try await coordinator.saveExternalConnection(
                id: "second",
                displayName: "Second",
                preflight: preflight,
                accessToken: token
            )
            XCTFail("Expected duplicate Runtime identity rejection")
        } catch {
            XCTAssertEqual(
                error as? RuntimeServerPreflightError,
                .duplicateServerIdentity(connectionID: "first")
            )
        }
    }

    func testEmbeddedAccessCredentialNeverEntersProviderInjectionMap() async throws {
        let store = EmbeddedRuntimeAccessCredentialStore(
            token: "0123456789abcdef0123456789abcdef"
        )
        let credential = try await store.resolve(store.target)
        let providerInjectionMap = try await store.all()
        XCTAssertEqual(credential?.kind, .bearer)
        XCTAssertEqual(credential?.secret.count, 32)
        XCTAssertTrue(providerInjectionMap.isEmpty)

        let oldToken = credential?.secret
        let rotatedToken = store.rotate()
        let resolvedRotatedToken = try await store.resolve(store.target)?.secret
        XCTAssertNotEqual(rotatedToken, oldToken)
        XCTAssertEqual(resolvedRotatedToken, rotatedToken)
    }

    func testMonitorStartsMissingEmbeddedRuntimeAndPublishesDiagnostics() async throws {
        var alive = false
        var starts = 0
        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:54321"))
        let monitor = RuntimeServerStatusMonitor(lifecycle: EmbeddedRuntimeLifecycle(
            isAlive: { alive },
            start: {
                starts += 1
                alive = true
                return 54321
            },
            restart: {
                alive = true
                return 54321
            },
            endpoint: { endpoint },
            profile: { "full_desktop" },
            healthCheck: { alive },
            runtimeInfo: { Self.runtimeInfo(profile: "full_desktop") }
        ))

        let healthy = await monitor.checkEmbedded(repairIfNeeded: true)
        XCTAssertTrue(healthy)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(monitor.status, .connected)
        XCTAssertEqual(monitor.diagnosticSnapshot.endpoint, endpoint)
        XCTAssertEqual(monitor.diagnosticSnapshot.runtimeProfile, "full_desktop")
        XCTAssertEqual(monitor.diagnosticSnapshot.runtimeInfo?.runtimeVersion, "1.3.0")
        XCTAssertNotNil(monitor.diagnosticSnapshot.lastConnectedAt)
    }

    func testStatusOnlyCheckDoesNotStartEmbeddedRuntime() async {
        var starts = 0
        let monitor = RuntimeServerStatusMonitor(lifecycle: EmbeddedRuntimeLifecycle(
            isAlive: { false },
            start: {
                starts += 1
                return 1
            },
            restart: { 1 },
            endpoint: { nil },
            profile: { "full_desktop" },
            healthCheck: { false },
            runtimeInfo: { Self.runtimeInfo(profile: "full_desktop") }
        ))

        let healthy = await monitor.checkEmbedded()
        XCTAssertFalse(healthy)
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(monitor.status, .offline)
    }

    func testMonitorRestartsStaleListener() async {
        var restarts = 0
        var healthChecks = 0
        let monitor = RuntimeServerStatusMonitor(lifecycle: EmbeddedRuntimeLifecycle(
            isAlive: { true },
            start: { 1 },
            restart: {
                restarts += 1
                return 2
            },
            endpoint: { URL(string: "http://127.0.0.1:2") },
            profile: { "sandboxed" },
            healthCheck: {
                healthChecks += 1
                return healthChecks > 1
            },
            runtimeInfo: { Self.runtimeInfo(profile: "sandboxed") }
        ))

        let healthy = await monitor.checkEmbedded(repairIfNeeded: true)
        XCTAssertTrue(healthy)
        XCTAssertEqual(restarts, 1)
        XCTAssertEqual(monitor.status, .connected)
    }

    func testPublicHealthDoesNotHideMissingEmbeddedAccessCredential() async {
        let monitor = RuntimeServerStatusMonitor(lifecycle: EmbeddedRuntimeLifecycle(
            isAlive: { true },
            start: { 1 },
            restart: { 1 },
            endpoint: { URL(string: "http://127.0.0.1:1") },
            profile: { "sandboxed" },
            healthCheck: { true },
            runtimeInfo: { throw RuntimeHTTPError.authenticationRequired }
        ))

        let healthy = await monitor.checkEmbedded()
        XCTAssertFalse(healthy)
        XCTAssertEqual(monitor.status, .authenticationRequired)
        XCTAssertNil(monitor.diagnosticSnapshot.runtimeInfo)
    }

    private func makeRegistry() -> RuntimeServerRegistry {
        let suite = "RuntimeServerConnectionsTests.\(UUID().uuidString)"
        return RuntimeServerRegistry(
            defaults: UserDefaults(suiteName: suite)!,
            storageKey: "servers",
            activeStorageKey: "active"
        )
    }

    private static func runtimeInfo(profile: String) -> RuntimeServerInfo {
        RuntimeServerInfo(
            schema: "runtime-info/v1",
            serverID: "srv_test",
            displayName: "Test Runtime",
            product: "codeagent",
            runtimeVersion: "1.3.0",
            agentWireProtocol: RuntimeServerProtocolVersion(major: 1, revision: "1.2"),
            runtimeProfile: profile
        )
    }

    private static func preflight(
        serverID: String
    ) -> RuntimeServerPreflightResult {
        RuntimeServerPreflightResult(
            endpoint: URL(string: "http://127.0.0.1:8797")!,
            kind: .local,
            authentication: .bearer,
            info: RuntimeServerInfo(
                schema: "runtime-info/v1",
                serverID: serverID,
                displayName: "Test Runtime",
                product: "codeagent",
                runtimeVersion: "1.3.0",
                agentWireProtocol: RuntimeServerProtocolVersion(
                    major: 1,
                    revision: "1.2"
                ),
                runtimeProfile: "headless"
            ),
            capabilities: RuntimeCapabilitySnapshot(),
            modelCatalog: RuntimeServerModelCatalog(
                schema: "runtime-model-catalog/v1",
                revision: 1,
                defaultRuntimeAlias: "",
                connections: []
            ),
            checkedAt: Date()
        )
    }
}
