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
            healthCheck: { alive }
        ))

        let healthy = await monitor.checkEmbedded(repairIfNeeded: true)
        XCTAssertTrue(healthy)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(monitor.status, .connected)
        XCTAssertEqual(monitor.diagnosticSnapshot.endpoint, endpoint)
        XCTAssertEqual(monitor.diagnosticSnapshot.runtimeProfile, "full_desktop")
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
            healthCheck: { false }
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
            }
        ))

        let healthy = await monitor.checkEmbedded(repairIfNeeded: true)
        XCTAssertTrue(healthy)
        XCTAssertEqual(restarts, 1)
        XCTAssertEqual(monitor.status, .connected)
    }

    private func makeRegistry() -> RuntimeServerRegistry {
        let suite = "RuntimeServerConnectionsTests.\(UUID().uuidString)"
        return RuntimeServerRegistry(
            defaults: UserDefaults(suiteName: suite)!,
            storageKey: "servers",
            activeStorageKey: "active"
        )
    }
}
