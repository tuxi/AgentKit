//
//  RuntimeSharingBackend.swift
//  AgentKit
//

import Foundation

/// Control-plane operations shared by the embedded and daemon-backed hosts.
///
/// The backend owns the transport and lifecycle details. UI-facing code should
/// depend on this protocol rather than assuming that the Runtime lives in the
/// current process.
public protocol RuntimeSharingBackend: Sendable {
    func startSharing(
        displayName: String?,
        listenAddress: String?
    ) async throws -> RuntimeSharedListenerStatus

    func stopSharing() async throws

    func refreshStatus() async throws -> RuntimeSharedListenerStatus

    func createPairingInvitation(
        validity: TimeInterval
    ) async throws -> RuntimePairingInvitation

    func listDevices() async throws -> [RuntimeSharedDevice]

    func revokeDevice(_ deviceID: String) async throws
}
