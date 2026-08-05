#if os(macOS) && canImport(CodeAgentRuntime)
import Security
import XCTest
@testable import AgentKit

@MainActor
final class RuntimeSharingTests: XCTestCase {
    func testInvitationRoundTripAndFractionalEnrollmentTimestamp() throws {
        let invitation = RuntimePairingInvitation(
            serverID: "srv_test",
            serverDisplayName: "Test Mac",
            serviceType: "_talkify-agent._tcp.",
            serviceName: "Test Mac abc123",
            fallbackHost: "test-mac.local",
            port: 49152,
            bootstrapSecret: String(repeating: "s", count: 43),
            bootstrapExpiresAt: Date().addingTimeInterval(120),
            spkiSHA256: Data(repeating: 7, count: 32).base64EncodedString()
        )
        let restored = try RuntimePairingInvitation.decode(
            payload: invitation.encodedPayload()
        )
        XCTAssertEqual(restored.serverID, invitation.serverID)
        XCTAssertEqual(restored.spkiSHA256, invitation.spkiSHA256)

        let enrollmentJSON = """
        [{
          "enrollment_id":"enr_1",
          "device_id":"dev_1",
          "credential_sha256":"\(String(repeating: "a", count: 64))",
          "device_name":"iPhone",
          "platform":"iOS",
          "created_at":"2026-07-30T01:02:03.123456789Z",
          "expires_at":"2026-07-30T01:03:03Z"
        }]
        """
        let enrollments = try JSONDecoder.runtimeSharing.decode(
            [RuntimePendingSharedEnrollment].self,
            from: XCTUnwrap(enrollmentJSON.data(using: .utf8))
        )
        XCTAssertEqual(enrollments.first?.deviceName, "iPhone")
    }

    func testGeneratedIdentityIsParseableAndSPKIPinMatches() throws {
        let identity = try RuntimeSharingTLSIdentityStore.generate(
            commonName: "AgentKit Test Runtime"
        )
        let base64 = identity.certificatePEM
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
        let der = try XCTUnwrap(
            Data(
                base64Encoded: base64,
                options: .ignoreUnknownCharacters
            )
        )
        let certificate = try XCTUnwrap(
            SecCertificateCreateWithData(nil, der as CFData)
        )
        var trust: SecTrust?
        XCTAssertEqual(
            SecTrustCreateWithCertificates(
                certificate,
                SecPolicyCreateBasicX509(),
                &trust
            ),
            errSecSuccess
        )
        XCTAssertEqual(
            RuntimeTLSSecurity.spkiSHA256Base64(
                from: try XCTUnwrap(trust)
            ),
            identity.spkiSHA256
        )
    }

    func testConnectionPersistsPairingTrustPolicy() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://mac.local:9443"))
        let policy = RuntimeServerTrustPolicy(
            expectedHost: "mac.local",
            spkiSHA256: Data(repeating: 3, count: 32).base64EncodedString()
        )
        let connection = try RuntimeServerConnection.external(
            id: "paired-mac",
            displayName: "Paired Mac",
            endpoint: endpoint,
            authentication: .bearer,
            platform: .iOS,
            trustPolicy: policy,
            serverID: "srv_mac"
        )
        let data = try JSONEncoder().encode(connection)
        let restored = try JSONDecoder().decode(
            RuntimeServerConnection.self,
            from: data
        )
        XCTAssertEqual(restored.trustPolicy, policy)
    }

    func testSharedRuntimePairingAndRevocation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agentkit-runtime-sharing-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let keychainService = "AgentKitTests.RuntimeSharing.\(UUID().uuidString)"
        let sharingKeychain = KeychainStore(service: keychainService)
        defer { sharingKeychain.removeAll() }

        let runtime = AgentRuntime.shared
        runtime.stop()
        try runtime.configure(EmbeddedRuntimeConfiguration(
            workspaceDirectory: root.appendingPathComponent(
                "workspace",
                isDirectory: true
            ),
            dataDirectory: root.appendingPathComponent(
                "data",
                isDirectory: true
            ),
            profile: .fullDesktop,
            runtimeSettingsJSON: "{}"
        ))
        defer { runtime.stop() }

        let devices = RuntimeSharedDeviceRegistry(
            keychain: sharingKeychain
        )
        let sharing = RuntimeSharingController(
            runtime: runtime,
            deviceRegistry: devices,
            identityKeychain: sharingKeychain
        )
        try await sharing.startSharing(displayName: "Test Mac")
        defer { sharing.stopSharing() }

        let invitation = try sharing.createPairingInvitation()
        let endpoint = try XCTUnwrap(
            URL(string: "https://127.0.0.1:\(sharing.status.port)")
        )
        let defaultsName = "RuntimeSharingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let registry = RuntimeServerRegistry(
            defaults: defaults,
            storageKey: "servers",
            activeStorageKey: "active"
        )
        let credentials = MemoryCredentialStore()
        let coordinator = RuntimeServerCoordinator(
            registry: registry,
            runtimeCredentialStore: credentials,
            platform: .macOS
        )
        let connection = try await coordinator.pairSharedRuntime(
            invitation: invitation,
            resolvedEndpoint: endpoint,
            deviceName: "Test iPhone"
        )
        XCTAssertEqual(connection.serverID, invitation.serverID)
        XCTAssertEqual(connection.trustPolicy?.spkiSHA256, invitation.spkiSHA256)
        XCTAssertEqual(devices.activeDevices.count, 1)
        let savedCredential = try await credentials.resolve(
            connection.credentialTarget
        )
        XCTAssertNotNil(savedCredential)
        let client = try coordinator.makeClient(connection: connection)
        _ = try await client.listConversations()
        let conversation = try await client.createConversation(
            workspacePath: root.appendingPathComponent("workspace").path
        )
        let channel = client.makeSessionChannel(
            conversationID: conversation.id
        )
        let stream = try await channel.connect(since: 0)
        _ = stream
        for _ in 0..<40 where !channel.isConnected {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(channel.isConnected)

        let deviceID = try XCTUnwrap(devices.activeDevices.first?.deviceID)
        try sharing.revokeDevice(deviceID)
        XCTAssertTrue(devices.activeDevices.isEmpty)
        for _ in 0..<40 where channel.isConnected {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(channel.isConnected)
        do {
            _ = try await coordinator.preflightExternal(
                connectionID: connection.id,
                endpoint: endpoint,
                authentication: .bearer,
                accessToken: nil
            )
            XCTFail("Revoked device credential unexpectedly remained valid")
        } catch {
            XCTAssertEqual(
                error as? RuntimeServerPreflightError,
                .authenticationInvalid
            )
        }
    }
}
#endif
