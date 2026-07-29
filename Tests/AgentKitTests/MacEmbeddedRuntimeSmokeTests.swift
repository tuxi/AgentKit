#if os(macOS) && canImport(CodeAgentRuntime)
import Foundation
import XCTest
@testable import AgentKit

@MainActor
final class MacEmbeddedRuntimeSmokeTests: XCTestCase {
    func testFullDesktopRuntimeStartsOnEphemeralLoopbackPort() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentkit-mac-runtime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = AgentRuntime.shared
        runtime.stop()
        try runtime.configure(
            EmbeddedRuntimeConfiguration(
                workspaceDirectory: root.appendingPathComponent("workspace", isDirectory: true),
                dataDirectory: root.appendingPathComponent("data", isDirectory: true),
                profile: .fullDesktop
            )
        )
        defer { runtime.stop() }

        let port = try runtime.ensureStarted()
        XCTAssertGreaterThan(port, 0)
        XCTAssertEqual(runtime.currentConfiguration.profile, .fullDesktop)

        let healthURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/healthz"))
        let (_, response) = try await URLSession.shared.data(from: healthURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let infoURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/v1/runtime/info"))
        let (unauthenticatedData, unauthenticatedResponse) = try await URLSession.shared.data(
            from: infoURL
        )
        XCTAssertEqual((unauthenticatedResponse as? HTTPURLResponse)?.statusCode, 401)
        XCTAssertTrue(
            String(decoding: unauthenticatedData, as: UTF8.self)
                .contains("runtime_auth_required")
        )

        let coordinator = RuntimeServerCoordinator()
        let info = try await coordinator.fetchActiveRuntimeInfo()
        XCTAssertEqual(info.schema, "runtime-info/v1")
        XCTAssertEqual(info.runtimeProfile, "full_desktop")
        XCTAssertTrue(info.isAgentWireV1Compatible)

        let catalog = try await coordinator.fetchActiveModelCatalog()
        XCTAssertEqual(catalog.schema, "runtime-model-catalog/v1")

        let previousToken = runtime.runtimeAccessCredentialStore.token
        let restartedPort = try runtime.restart()
        let rotatedToken = runtime.runtimeAccessCredentialStore.token
        XCTAssertNotEqual(rotatedToken, previousToken)

        let restartedInfoURL = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(restartedPort)/v1/runtime/info")
        )
        var staleCredentialRequest = URLRequest(url: restartedInfoURL)
        staleCredentialRequest.setValue(
            "Bearer \(previousToken)",
            forHTTPHeaderField: "Authorization"
        )
        let (_, staleCredentialResponse) = try await URLSession.shared.data(
            for: staleCredentialRequest
        )
        XCTAssertEqual((staleCredentialResponse as? HTTPURLResponse)?.statusCode, 401)

        let restartedInfo = try await coordinator.fetchActiveRuntimeInfo()
        XCTAssertEqual(restartedInfo.serverID, info.serverID)

        let suite = "MacEmbeddedRuntimeSmokeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = RuntimeServerRegistry(
            defaults: defaults,
            storageKey: "servers",
            activeStorageKey: "active"
        )
        let credentials = MemoryCredentialStore()
        let externalCoordinator = RuntimeServerCoordinator(
            registry: registry,
            runtimeCredentialStore: credentials,
            platform: .macOS
        )
        let externalEndpoint = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(restartedPort)")
        )
        let preflight = try await externalCoordinator.preflightExternal(
            connectionID: nil,
            endpoint: externalEndpoint,
            authentication: .bearer,
            accessToken: rotatedToken
        )
        XCTAssertEqual(preflight.kind, .local)
        XCTAssertEqual(preflight.info.serverID, restartedInfo.serverID)

        let external = try await externalCoordinator.saveExternalConnection(
            id: "local-codeagent",
            displayName: "Local CodeAgent",
            preflight: preflight,
            accessToken: rotatedToken
        )
        XCTAssertEqual(external.serverID, restartedInfo.serverID)
        let savedCredential = try await credentials.resolve(
            external.credentialTarget
        )
        XCTAssertEqual(
            savedCredential?.secret,
            rotatedToken
        )
        let externalIsHealthy = try await externalCoordinator.checkExternal(
            connectionID: external.id
        )
        XCTAssertTrue(externalIsHealthy)

        let externalClient = try externalCoordinator.makeClient(
            connection: external
        )
        _ = try await externalClient.listConversations()

        let originalRevision = externalCoordinator.activeRevision
        let assessment = try await externalCoordinator.assessSwitch(
            to: external.id
        )
        XCTAssertFalse(assessment.requiresConfirmation)
        let externalContext = try await externalCoordinator.activate(
            connectionID: external.id
        )
        XCTAssertEqual(externalCoordinator.activeConnectionID, external.id)
        XCTAssertGreaterThan(externalCoordinator.activeRevision, originalRevision)
        XCTAssertTrue(
            externalContext.models.allSatisfy {
                $0.serverConnectionID == external.id
            }
        )
        if let defaultModelID = externalContext.defaultModelID {
            XCTAssertTrue(
                externalContext.models.contains { $0.id == defaultModelID }
            )
        }
        _ = try await externalCoordinator.makeActiveClient().listConversations()

        _ = try await externalCoordinator.activate(
            connectionID: RuntimeServerConnection.embeddedID
        )
        XCTAssertEqual(
            externalCoordinator.activeConnectionID,
            RuntimeServerConnection.embeddedID
        )
        _ = try await externalCoordinator.removeExternalConnection(
            connectionID: external.id
        )
        let removedCredential = try await credentials.resolve(
            external.credentialTarget
        )
        XCTAssertNil(removedCredential)
    }
}
#endif
