//
//  ExternalRuntimeServerStatusMonitor.swift
//  AgentKit
//
//  Read-only status source for Local and Remote Runtime Servers.
//

import Foundation

@MainActor
@Observable
public final class ExternalRuntimeServerStatusMonitor {
    public private(set) var connection: RuntimeServerConnection
    public private(set) var status: RuntimeServerConnectionStatus = .checking
    public private(set) var runtimeInfo: RuntimeServerInfo?
    public private(set) var lastCheckedAt: Date?
    public private(set) var lastConnectedAt: Date?
    public private(set) var lastErrorDescription: String?

    private let credentialStore: any CredentialStore
    @ObservationIgnored private var inflight: Task<Bool, Never>?

    init(
        connection: RuntimeServerConnection,
        credentialStore: any CredentialStore
    ) {
        self.connection = connection
        self.credentialStore = credentialStore
    }

    public var diagnosticSnapshot: RuntimeServerDiagnosticSnapshot {
        RuntimeServerDiagnosticSnapshot(
            connectionID: connection.id,
            status: status,
            endpoint: connection.endpoint,
            runtimeInfo: runtimeInfo,
            runtimeProfile: runtimeInfo?.runtimeProfile,
            lastCheckedAt: lastCheckedAt,
            lastConnectedAt: lastConnectedAt,
            lastErrorDescription: lastErrorDescription
        )
    }

    func update(connection: RuntimeServerConnection) {
        self.connection = connection
    }

    @discardableResult
    public func check() async -> Bool {
        if let inflight {
            return await inflight.value
        }
        let task = Task { await self.runCheck() }
        inflight = task
        let healthy = await task.value
        inflight = nil
        return healthy
    }

    private func runCheck() async -> Bool {
        lastCheckedAt = Date()
        lastErrorDescription = nil
        status = .checking

        do {
            try connection.validate()
            guard let endpoint = connection.endpoint else {
                throw RuntimeServerRegistryError.invalidExternalEndpoint
            }
            let environment = try RuntimeEnvironment(origin: endpoint)
            let client: RuntimeHTTPClient
            switch connection.authentication {
            case .none:
                client = RuntimeHTTPClient(
                    environment: environment,
                    trustPolicy: connection.trustPolicy
                )
            case .bearer:
                client = RuntimeHTTPClient(
                    environment: environment,
                    credentialStore: credentialStore,
                    credentialTarget: connection.credentialTarget,
                    trustPolicy: connection.trustPolicy
                )
            }
            guard try await client.healthCheck() else {
                status = .offline
                lastErrorDescription = "Runtime Server health check failed."
                return false
            }
            let info = try await client.runtimeInfo()
            guard info.isAgentWireV1Compatible else {
                status = .protocolIncompatible
                lastErrorDescription = "Runtime Server Agent Wire protocol is incompatible."
                return false
            }
            if let expected = connection.serverID, expected != info.serverID {
                status = .configurationError
                lastErrorDescription = "Runtime Server identity no longer matches this connection."
                return false
            }
            runtimeInfo = info
            status = .connected
            lastConnectedAt = Date()
            return true
        } catch RuntimeHTTPError.authenticationRequired,
                RuntimeServerPreflightError.accessTokenRequired,
                RuntimeServerPreflightError.authenticationRequired {
            status = .authenticationRequired
            lastErrorDescription = "Runtime Server Access Token is required."
            return false
        } catch RuntimeHTTPError.authenticationInvalid,
                RuntimeServerPreflightError.authenticationInvalid {
            status = .authenticationFailed
            lastErrorDescription = "Runtime Server Access Token is invalid."
            return false
        } catch RuntimeServerRegistryError.tlsRequired {
            status = .tlsRequired
            lastErrorDescription = "Remote Runtime Servers require HTTPS/WSS."
            return false
        } catch let error as URLError {
            status = .offline
            lastErrorDescription = Self.safeDescription(error)
            return false
        } catch RuntimeHTTPError.unexpectedStatus {
            status = .configurationError
            lastErrorDescription = "Runtime Server returned an unexpected response."
            return false
        } catch {
            status = .configurationError
            lastErrorDescription = Self.safeDescription(error)
            return false
        }
    }

    private static func safeDescription(_ error: Error) -> String {
        let description = (error as NSError).localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? "Runtime Server check failed." : description
    }
}
