//
//  RuntimeSharingController.swift
//  AgentKit
//

#if os(macOS) && canImport(CodeAgentRuntime)
import CryptoKit
import Foundation
import Observation
import Security

@MainActor
@Observable
public final class RuntimeSharingController {
    public let deviceRegistry: RuntimeSharedDeviceRegistry
    public private(set) var status = RuntimeSharedListenerStatus(
        state: .stopped,
        listenAddress: nil,
        listenOrigin: nil,
        port: 0,
        startedAt: nil,
        stoppedAt: nil,
        lastTransitionAt: nil,
        lastError: nil
    )
    public private(set) var advertisedOrigin: URL?
    public private(set) var serviceName: String?
    public private(set) var lastError: String?

    @ObservationIgnored private let runtime: AgentRuntime
    @ObservationIgnored private let identityStore: RuntimeSharingTLSIdentityStore
    @ObservationIgnored private let advertiser = RuntimeBonjourAdvertiser()
    @ObservationIgnored private var enrollmentTask: Task<Void, Never>?
    @ObservationIgnored private var identity: RuntimeSharingTLSIdentity?
    @ObservationIgnored private var runtimeInfo: RuntimeServerInfo?

    public init(
        runtime: AgentRuntime = .shared,
        deviceRegistry: RuntimeSharedDeviceRegistry = RuntimeSharedDeviceRegistry(),
        identityKeychain: KeychainStore = KeychainStore(
            service: "com.agentkit.runtime-sharing"
        )
    ) {
        self.runtime = runtime
        self.deviceRegistry = deviceRegistry
        self.identityStore = RuntimeSharingTLSIdentityStore(
            keychain: identityKeychain
        )
    }

    public var isSharing: Bool { status.state == .running }

    public func startSharing(
        displayName: String? = nil,
        listenAddress: String = "0.0.0.0:0"
    ) async throws {
        _ = try runtime.ensureStarted()
        let info = try await embeddedRuntimeInfo()
        let resolvedName = displayName?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).nilIfEmpty ?? info.displayName
        let identity = try identityStore.loadOrCreate(
            commonName: "\(resolvedName) Runtime"
        )
        let configuration = RuntimeSharedListenerConfiguration(
            address: listenAddress,
            certificatePEM: identity.certificatePEM,
            privateKeyPEM: identity.privateKeyPEM,
            bootstrapSHA256: "",
            bootstrapExpiresAt: 0,
            devices: deviceRegistry.validationRecords(),
            enrollmentTimeoutSeconds: 60
        )
        try runtime.startSharedListener(configuration: configuration)
        let status = try runtime.sharedListenerStatus()
        guard status.state == .running, status.port > 0 else {
            throw RuntimeSharingError.sharedListenerUnavailable
        }
        let host = Self.advertisedHost()
        let serviceName = Self.makeServiceName(
            displayName: resolvedName,
            serverID: info.serverID
        )
        self.identity = identity
        self.runtimeInfo = info
        self.status = status
        self.serviceName = serviceName
        self.advertisedOrigin = URL(string: "https://\(host):\(status.port)")
        self.lastError = nil
        advertiser.start(
            serviceName: serviceName,
            port: status.port,
            serverID: info.serverID,
            displayName: resolvedName
        )
        startEnrollmentPolling()
    }

    public func stopSharing() {
        enrollmentTask?.cancel()
        enrollmentTask = nil
        advertiser.stop()
        try? runtime.stopSharedListener()
        status = (try? runtime.sharedListenerStatus()) ?? RuntimeSharedListenerStatus(
            state: .stopped,
            listenAddress: nil,
            listenOrigin: nil,
            port: 0,
            startedAt: nil,
            stoppedAt: nil,
            lastTransitionAt: nil,
            lastError: nil
        )
        advertisedOrigin = nil
        serviceName = nil
    }

    @discardableResult
    public func refreshStatus() -> RuntimeSharedListenerStatus {
        do {
            status = try runtime.sharedListenerStatus()
            lastError = status.lastError
        } catch {
            lastError = error.localizedDescription
        }
        return status
    }

    public func createPairingInvitation(
        validity: TimeInterval = 120
    ) throws -> RuntimePairingInvitation {
        guard status.state == .running,
              let identity,
              let info = runtimeInfo,
              let serviceName,
              let origin = advertisedOrigin,
              let host = origin.host else {
            throw RuntimeSharingError.sharedListenerUnavailable
        }
        let secret = try Self.randomSecret()
        let expiresAt = Date().addingTimeInterval(
            min(max(validity, 30), 300)
        )
        let digest = SHA256.hash(data: Data(secret.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        try runtime.rotateSharedBootstrap(
            sha256: digest,
            expiresAt: expiresAt
        )
        return RuntimePairingInvitation(
            serverID: info.serverID,
            serverDisplayName: info.displayName,
            serviceType: RuntimeBonjourAdvertiser.serviceType,
            serviceName: serviceName,
            fallbackHost: host,
            port: status.port,
            bootstrapSecret: secret,
            bootstrapExpiresAt: expiresAt,
            spkiSHA256: identity.spkiSHA256
        )
    }

    public func revokeDevice(_ deviceID: String) throws {
        // Persist the revocation tombstone first. A process restart therefore
        // cannot accidentally restore access if the live update is interrupted.
        try deviceRegistry.markRevoked(deviceID: deviceID)
        try runtime.updateSharedDevices(deviceRegistry.validationRecords())
    }

    private func startEnrollmentPolling() {
        enrollmentTask?.cancel()
        enrollmentTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.processPendingEnrollments()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func processPendingEnrollments() {
        guard let pending = try? runtime.pendingSharedEnrollments() else {
            return
        }
        for enrollment in pending {
            do {
                // D1 blocks the iPhone response until this durable write
                // succeeds and the host acknowledges it.
                try deviceRegistry.persist(enrollment: enrollment)
                try runtime.acknowledgeSharedEnrollment(
                    enrollment.enrollmentID
                )
            } catch {
                try? deviceRegistry.markRevoked(deviceID: enrollment.deviceID)
                try? runtime.rejectSharedEnrollment(enrollment.enrollmentID)
                lastError = error.localizedDescription
            }
        }
    }

    private func embeddedRuntimeInfo() async throws -> RuntimeServerInfo {
        let client = RuntimeHTTPClient(
            environment: .fromRuntime(),
            credentialStore: runtime.runtimeAccessCredentialStore,
            credentialTarget: runtime.runtimeAccessCredentialStore.target
        )
        return try await client.runtimeInfo()
    }

    private static func advertisedHost() -> String {
        let value = ProcessInfo.processInfo.hostName
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if value.lowercased().hasSuffix(".local") {
            return value
        }
        return "\(value).local"
    }

    private static func makeServiceName(
        displayName: String,
        serverID: String
    ) -> String {
        let suffix = String(serverID.prefix(6))
        var value = "\(displayName) \(suffix)"
        while value.utf8.count > 63, !value.isEmpty {
            value.removeLast()
        }
        return value
    }

    private static func randomSecret() throws -> String {
        var bytes = Data(count: 32)
        guard bytes.withUnsafeMutableBytes({
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }) == errSecSuccess else {
            throw RuntimeSharingError.sharedListenerUnavailable
        }
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif
