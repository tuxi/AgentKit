//
//  RuntimeSharingDaemonController.swift
//  AgentKit
//

import Foundation
import Observation

/// Main-actor UI state for a daemon-owned Runtime Sharing instance.
///
/// Unlike `RuntimeSharingController`, this type never starts or stops an
/// Embedded Runtime. Every operation is a localhost management API call to
/// the already-running Code-Agent daemon.
@MainActor
@Observable
public final class RuntimeSharingDaemonController {
    public private(set) var status: RuntimeSharedListenerStatus
    public private(set) var devices: [RuntimeSharedDevice] = []
    public private(set) var lastError: String?

    @ObservationIgnored private var client: RuntimeSharingDaemonClient

    public init(
        client: RuntimeSharingDaemonClient = RuntimeSharingDaemonClient()
    ) {
        self.client = client
        self.status = RuntimeSharedListenerStatus(
            state: .stopped,
            listenAddress: nil,
            listenOrigin: nil,
            port: 0,
            startedAt: nil,
            stoppedAt: nil,
            lastTransitionAt: nil,
            lastError: nil
        )
    }

    /// Updates the daemon endpoint after the host has launched or rediscovered
    /// codeagentd. The daemon uses a dynamic loopback port in macOS App mode.
    public func configure(
        endpoint: URL,
        managementToken: String? = nil
    ) {
        client = RuntimeSharingDaemonClient(
            endpoint: endpoint,
            managementToken: managementToken
        )
    }

    public var isSharing: Bool {
        status.state == .running
    }

    @discardableResult
    public func startSharing(
        displayName: String? = nil,
        listenAddress: String? = nil
    ) async throws -> RuntimeSharedListenerStatus {
        do {
            status = try await client.startSharing(
                displayName: displayName,
                listenAddress: listenAddress
            )
            lastError = status.lastError
            return status
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    public func stopSharing() async {
        do {
            try await client.stopSharing()
            status = try await client.refreshStatus()
            lastError = status.lastError
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    public func refreshStatus() async -> RuntimeSharedListenerStatus {
        do {
            status = try await client.refreshStatus()
            lastError = status.lastError
        } catch {
            lastError = error.localizedDescription
        }
        return status
    }

    public func createPairingInvitation(
        validity: TimeInterval = 120
    ) async throws -> RuntimePairingInvitation {
        try await client.createPairingInvitation(validity: validity)
    }

    @discardableResult
    public func refreshDevices() async -> [RuntimeSharedDevice] {
        do {
            devices = try await client.listDevices()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        return devices
    }

    public func revokeDevice(_ deviceID: String) async throws {
        do {
            try await client.revokeDevice(deviceID)
            devices = try await client.listDevices()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }
}
