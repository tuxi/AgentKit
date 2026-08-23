//
//  RuntimeServerCoordinator.swift
//  AgentKit
//
//  Active Runtime boundary for Embedded, Local and Remote CodeAgent Servers.
//

import Foundation

public enum RuntimeServerCoordinatorError: Error, LocalizedError, Equatable {
    case accessTokenRequired
    case activityCheckFailed
    case activeWorkRequiresConfirmation
    case identityConfirmationRequired(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .accessTokenRequired:
            "Runtime Server Access Token is required."
        case .activityCheckFailed:
            "Unable to verify whether the current Runtime Server has active work."
        case .activeWorkRequiresConfirmation:
            "The current Runtime Server has active work. Confirm before switching."
        case .identityConfirmationRequired(let expected, let actual):
            "Runtime Server identity changed from \(expected) to \(actual)."
        }
    }
}

public struct RuntimeServerActiveContext: Sendable, Equatable {
    public let serverConnectionID: String
    public let info: RuntimeServerInfo
    public let capabilities: RuntimeCapabilitySnapshot
    public let modelCatalog: RuntimeServerModelCatalog
    public let models: [UnifiedModelDescriptor]
    public let defaultModelID: String?
    public let refreshedAt: Date

    public init(
        serverConnectionID: String,
        info: RuntimeServerInfo,
        capabilities: RuntimeCapabilitySnapshot,
        modelCatalog: RuntimeServerModelCatalog,
        scopesModelIdentity: Bool,
        refreshedAt: Date
    ) {
        self.serverConnectionID = serverConnectionID
        self.info = info
        self.capabilities = capabilities
        self.modelCatalog = modelCatalog
        self.models = modelCatalog.unifiedModels(
            serverConnectionID: scopesModelIdentity ? serverConnectionID : nil
        )
        self.defaultModelID = modelCatalog.defaultModelStableID(
            serverConnectionID: scopesModelIdentity ? serverConnectionID : nil
        )
        self.refreshedAt = refreshedAt
    }
}

public struct RuntimeServerSwitchAssessment: Sendable, Equatable {
    public let sourceConnectionID: String
    public let targetConnectionID: String
    public let hasActiveWork: Bool

    public init(
        sourceConnectionID: String,
        targetConnectionID: String,
        hasActiveWork: Bool
    ) {
        self.sourceConnectionID = sourceConnectionID
        self.targetConnectionID = targetConnectionID
        self.hasActiveWork = hasActiveWork
    }

    public var requiresConfirmation: Bool {
        sourceConnectionID != targetConnectionID && hasActiveWork
    }
}

@MainActor
@Observable
public final class RuntimeServerCoordinator {
    public let registry: RuntimeServerRegistry
    public let embeddedStatusMonitor: RuntimeServerStatusMonitor

    /// Hosts use this value as a SwiftUI `.id(...)` to rebuild the complete
    /// Server-scoped Workspace root after an explicit Active Server change.
    public private(set) var activeRevision: UInt64 = 0
    public private(set) var activeContext: RuntimeServerActiveContext?

    private let runtimeCredentialStore: any CredentialStore
    private let platform: RuntimeServerClientPlatform
    private let preflightService: RuntimeServerPreflightService
    @ObservationIgnored private var externalMonitors:
        [String: ExternalRuntimeServerStatusMonitor] = [:]
    /// Bonjour discovery used to re-point a paired connection at the Mac's
    /// *current* host/port after a restart (the shared listener binds an
    /// ephemeral port; `server_id` and the TLS identity stay stable).
    /// Resolves the current endpoint for a stable `server_id`. Injectable for
    /// tests; defaults to a bounded Bonjour lookup.
    @ObservationIgnored private let endpointResolver: @MainActor (String) async -> URL?
    /// Per-connection rate limiter for endpoint rediscovery, so the settings
    /// polling loop cannot hammer Bonjour while a server stays offline.
    @ObservationIgnored private var lastRediscoveryAttempt: [String: Date] = [:]
    private static let rediscoveryMinInterval: TimeInterval = 30

    public init(
        registry: RuntimeServerRegistry = RuntimeServerRegistry(),
        embeddedStatusMonitor: RuntimeServerStatusMonitor = .init(),
        runtimeCredentialStore: any CredentialStore = KeychainCredentialStore(
            service: "com.agentkit.runtime-server-access"
        ),
        platform: RuntimeServerClientPlatform = .current,
        endpointResolver: (@MainActor (String) async -> URL?)? = nil
    ) {
        self.registry = registry
        self.embeddedStatusMonitor = embeddedStatusMonitor
        self.runtimeCredentialStore = runtimeCredentialStore
        self.platform = platform
        self.preflightService = RuntimeServerPreflightService(platform: platform)
        let browser = RuntimeBonjourBrowser()
        self.endpointResolver = endpointResolver ?? { serverID in
            let discovered = await browser.resolveOnce()
            return discovered.first { $0.serverID == serverID }?.endpoint
        }
    }

    public var activeConnection: RuntimeServerConnection {
        registry.activeConnection
    }

    public var activeConnectionID: String {
        registry.activeConnectionID
    }

    public var activeIdentityRevision: String {
        "\(activeConnectionID):\(activeRevision)"
    }

    public func makeActiveClient() throws -> any RuntimeClient {
        try makeClient(connection: activeConnection)
    }

    public func makeClient(
        connection: RuntimeServerConnection
    ) throws -> DefaultAgentClient {
        switch connection.kind {
        case .embedded:
#if canImport(CodeAgentRuntime)
            return DefaultAgentClient.fromRuntime()
#else
            throw RuntimeServerRegistryError.invalidEmbeddedConnection
#endif
        case .local, .remote:
            
            guard connection.endpoint != nil else {
                throw RuntimeServerRegistryError.invalidExternalEndpoint
            }
            // Read the current endpoint from the registry on every request,
            // not a snapshot at client-creation time. The provider is async and
            // hops to the MainActor via await — suspension, not blocking — so it
            // can never deadlock the main thread the way DispatchQueue.main.sync did.
            let environment = RuntimeEnvironment { [weak self] in
                guard let `self` = self else { return nil }
                return await MainActor.run {
                    self.registry.connection(id: connection.id)?.endpoint
                }
            }
            
            switch connection.authentication {
            case .none:
                return DefaultAgentClient(
                    environment: environment,
                    trustPolicy: connection.trustPolicy
                )
            case .bearer:
                return DefaultAgentClient(
                    environment: environment,
                    credentialStore: runtimeCredentialStore,
                    credentialTarget: connection.credentialTarget,
                    trustPolicy: connection.trustPolicy
                )
            }
        }
    }

    // MARK: - External connection lifecycle

    public func preflightExternal(
        connectionID: String?,
        endpoint: URL,
        authentication: RuntimeServerAuthentication,
        accessToken: String?,
        trustPolicy: RuntimeServerTrustPolicy? = nil
    ) async throws -> RuntimeServerPreflightResult {
        var effectiveToken = accessToken
        let effectiveTrustPolicy = trustPolicy
            ?? connectionID.flatMap { registry.connection(id: $0)?.trustPolicy }
        if authentication == .bearer,
           effectiveToken?.isEmpty != false,
           let connectionID,
           let existing = try await runtimeCredentialStore.resolve(
               .runtimeAccess(connectionID)
           ) {
            effectiveToken = existing.secret
        }
        return try await preflightService.test(
            endpoint: endpoint,
            authentication: authentication,
            accessToken: effectiveToken,
            trustPolicy: effectiveTrustPolicy
        )
    }

    /// Completes a QR/Bonjour pairing against a shared Mac Runtime. The
    /// plaintext device credential exists only in this call and is written to
    /// the Runtime Access Keychain before the connection is returned.
        @discardableResult
    public func pairSharedRuntime(
        invitation: RuntimePairingInvitation,
        resolvedEndpoint: URL? = nil,
        connectionID: String? = nil,
        displayName: String? = nil,
        deviceName: String
    ) async throws -> RuntimeServerConnection {
        guard invitation.bootstrapExpiresAt > Date() else {
            throw RuntimeSharingError.invitationExpired
        }
        let fallbackHost = Self.normalizedSharingFallbackHost(
            invitation.fallbackHost
        )
        let endpoint = try (
            resolvedEndpoint ?? URL(
                string: "https://\(fallbackHost):\(invitation.port)"
            )
        ).unwrap(or: RuntimeSharingError.invalidInvitation)
        let trustPolicy = RuntimeServerTrustPolicy(
            expectedHost: endpoint.host ?? "",
            spkiSHA256: invitation.spkiSHA256
        )
        let pairing = try await RuntimePairingClient().pair(
            invitation: invitation,
            endpoint: endpoint,
            deviceName: deviceName,
            platform: platform
        )
        let preflight = try await preflightService.test(
            endpoint: endpoint,
            authentication: .bearer,
            accessToken: pairing.credential,
            trustPolicy: trustPolicy
        )
        guard preflight.info.serverID == invitation.serverID else {
            throw RuntimeSharingError.serverIdentityMismatch
        }
        // Reuse an existing connection that already identifies this Runtime.
        // This makes re-pairing an *update-in-place*: re-scanning the QR after
        // the Mac restarted (or after its listener moved to a new port, or a
        // stale device credential was revoked) refreshes the endpoint, the
        // TLS pin and the device credential on the SAME registered connection,
        // instead of allocating a new id and tripping the duplicate-identity
        // guard. The preserved id is what lets `saveExternalConnection` update
        // in place and keeps the connection's Keychain credential current.
        let existingByServerID = registry.connections.first {
            $0.kind != .embedded && $0.serverID == invitation.serverID
        }
        let id = connectionID?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).nilIfEmpty
            ?? existingByServerID?.id
            ?? Self.suggestedPairedConnectionID(
                serverID: invitation.serverID,
                existing: Set(registry.connections.map(\.id))
            )
        return try await saveExternalConnection(
            id: id,
            displayName: displayName ?? invitation.serverDisplayName,
            preflight: preflight,
            accessToken: pairing.credential
        )
    }

    /// Store a temporary bearer token for an external connection in the
    /// Keychain-backed credential store. Used by the daemon boot path on
    /// macOS Direct to inject a freshly generated access token without
    /// going through the full pairing/preflight flow.
    public func injectBearerToken(for connectionID: String, token: String) async throws {
        try await runtimeCredentialStore.set(
            Credential(kind: .bearer, secret: token),
            for: .runtimeAccess(connectionID)
        )
    }

    @discardableResult
    public func saveExternalConnection(
        id: String,
        displayName: String?,
        preflight: RuntimeServerPreflightResult,
        accessToken: String?,
        confirmIdentityChange: Bool = false
    ) async throws -> RuntimeServerConnection {
        let existing = registry.connection(id: id)
        if let expected = existing?.serverID,
           expected != preflight.info.serverID,
           !confirmIdentityChange {
            throw RuntimeServerCoordinatorError.identityConfirmationRequired(
                expected: expected,
                actual: preflight.info.serverID
            )
        }
        if let duplicate = registry.connections.first(where: {
            $0.id != id && $0.serverID == preflight.info.serverID
        }) {
            throw RuntimeServerPreflightError.duplicateServerIdentity(
                connectionID: duplicate.id
            )
        }

        let now = Date()
        let connection = try RuntimeServerConnection(
            id: id,
            displayName: displayName?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).nilIfEmpty ?? preflight.info.displayName,
            kind: preflight.kind,
            endpoint: preflight.endpoint,
            authentication: preflight.authentication,
            trustPolicy: preflight.trustPolicy,
            serverID: preflight.info.serverID,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )

        switch preflight.authentication {
        case .none:
            try await runtimeCredentialStore.remove(connection.credentialTarget)
        case .bearer:
            if let accessToken, !accessToken.isEmpty {
                guard accessToken.lengthOfBytes(using: .utf8) >= 32 else {
                    throw RuntimeServerPreflightError.accessTokenTooShort
                }
                try await runtimeCredentialStore.set(
                    Credential(kind: .bearer, secret: accessToken),
                    for: connection.credentialTarget
                )
            } else if try await runtimeCredentialStore.resolve(
                connection.credentialTarget
            ) == nil {
                throw RuntimeServerCoordinatorError.accessTokenRequired
            }
        }

        try registry.upsert(connection)
        externalStatusMonitor(for: connection).update(connection: connection)

        if activeConnectionID == connection.id {
            activeContext = Self.context(
                connectionID: connection.id,
                preflight: preflight
            )
            activeRevision &+= 1
        }
        return connection
    }

    @discardableResult
    public func removeExternalConnection(
        connectionID: String
    ) async throws -> RuntimeServerConnection {
        guard let connection = registry.connection(id: connectionID),
              connection.kind != .embedded else {
            throw RuntimeServerRegistryError.cannotRemoveEmbedded
        }
        guard connectionID != activeConnectionID else {
            throw RuntimeServerRegistryError.cannotRemoveActive
        }
        try await runtimeCredentialStore.remove(connection.credentialTarget)
        let removed = try registry.remove(connectionID: connectionID)
        externalMonitors.removeValue(forKey: connectionID)
        return removed
    }

    // MARK: - Active Server

    public func assessSwitch(
        to connectionID: String
    ) async throws -> RuntimeServerSwitchAssessment {
        guard registry.connection(id: connectionID) != nil else {
            throw RuntimeServerRegistryError.connectionNotFound(connectionID)
        }
        guard connectionID != activeConnectionID else {
            return RuntimeServerSwitchAssessment(
                sourceConnectionID: activeConnectionID,
                targetConnectionID: connectionID,
                hasActiveWork: false
            )
        }
        do {
            let snapshot = try await makeActiveClient().activitySnapshot()
            return RuntimeServerSwitchAssessment(
                sourceConnectionID: activeConnectionID,
                targetConnectionID: connectionID,
                hasActiveWork: snapshot.hasActiveRuntimeWork
            )
        } catch {
            // An unreachable current Server cannot prove that work exists.
            // Switching remains an explicit user action and never cancels work
            // on that Server, so do not trap the user on an offline connection.
            return RuntimeServerSwitchAssessment(
                sourceConnectionID: activeConnectionID,
                targetConnectionID: connectionID,
                hasActiveWork: false
            )
        }
    }

    @discardableResult
    public func activate(
        connectionID: String,
        allowingActiveWorkInterruption: Bool = false
    ) async throws -> RuntimeServerActiveContext {
        guard let target = registry.connection(id: connectionID) else {
            throw RuntimeServerRegistryError.connectionNotFound(connectionID)
        }
        if connectionID == activeConnectionID {
            return try await refreshActiveContext()
        }

        let assessment = try await assessSwitch(to: connectionID)
        if assessment.requiresConfirmation && !allowingActiveWorkInterruption {
            throw RuntimeServerCoordinatorError.activeWorkRequiresConfirmation
        }

        let context = try await loadContext(connection: target)
        _ = try registry.setActive(connectionID: connectionID)
        activeContext = context
        activeRevision &+= 1
        return context
    }

    @discardableResult
    public func refreshActiveContext() async throws -> RuntimeServerActiveContext {
        let context = try await loadContext(connection: activeConnection)
        activeContext = context
        return context
    }

    public func fetchActiveRuntimeInfo() async throws -> RuntimeServerInfo {
        let context = try await refreshActiveContext()
        return context.info
    }

    public func fetchActiveModelCatalog() async throws -> RuntimeServerModelCatalog {
        let context = try await refreshActiveContext()
        return context.modelCatalog
    }

    /// HTTP-backed provider store for the active server connection.
    ///
    /// Convenience for hosts that already own a `RuntimeServerCoordinator`:
    /// resolves the Bearer token from this coordinator's runtime credential
    /// store for the connection's target (`.runtimeAccess(id)`), so hosts never
    /// touch the store directly. Embedded connections throw
    /// `invalidEmbeddedConnection` — on iOS provider config stays host-injected.
    public func makeProviderStore() throws -> any ProviderStore {
        try ProviderStoreFactory.http(
            for: activeConnection,
            credentialStore: runtimeCredentialStore,
            trustPolicy: activeConnection.trustPolicy
        )
    }

    // MARK: - Status

    @discardableResult
    public func checkEmbedded(repairIfNeeded: Bool = false) async -> Bool {
#if canImport(CodeAgentRuntime)
        return await embeddedStatusMonitor.checkEmbedded(repairIfNeeded: repairIfNeeded)
#else
        return false
#endif
    }

    @discardableResult
    public func restartEmbedded() async -> Bool {
#if canImport(CodeAgentRuntime)
        return await embeddedStatusMonitor.restartEmbedded()
#else
        return false
#endif
    }

    public var embeddedDiagnostics: RuntimeServerDiagnosticSnapshot {
#if canImport(CodeAgentRuntime)
        embeddedStatusMonitor.diagnosticSnapshot
#else
        RuntimeServerDiagnosticSnapshot(connectionID: "", status: .offline, endpoint: nil, runtimeProfile: nil, lastCheckedAt: nil, lastConnectedAt: nil, lastErrorDescription: nil)
#endif
    }

    public func externalStatusMonitor(
        connectionID: String
    ) throws -> ExternalRuntimeServerStatusMonitor {
        guard let connection = registry.connection(id: connectionID),
              connection.kind != .embedded else {
            throw RuntimeServerRegistryError.connectionNotFound(connectionID)
        }
        return externalStatusMonitor(for: connection)
    }

    @discardableResult
    public func checkExternal(connectionID: String) async throws -> Bool {
        let monitor = try externalStatusMonitor(connectionID: connectionID)
        var healthy = await monitor.check()
        if !healthy,
           await rediscoverPairedEndpoint(connectionID: connectionID) {
            // The Mac restarted and its shared listener moved to a new port
            // (or a new host/IP). The saved connection was re-pointed at the
            // rediscovered endpoint — re-check against it once.
            healthy = await monitor.check()
        }
        return healthy
    }

    // MARK: - Endpoint rediscovery (paired servers)

    /// Re-resolves the *current* host/port for a paired external connection and
    /// updates the stored connection in place.
    ///
    /// The Code-Agent daemon binds its shared TLS listener on an ephemeral
    /// port, so after a Mac restart every paired iPhone is left pointing at a
    /// dead endpoint. Because `server_id` and the TLS identity (SPKI) are
    /// stable across restarts, the connection can be re-pointed at the
    /// Bonjour-advertised address without re-pairing — no user action needed.
    ///
    /// Only pairing-established connections (`trustPolicy != nil`) are
    /// eligible, and attempts are rate-limited per connection so the polling
    /// loop cannot hammer Bonjour while a server stays offline.
    ///
    /// - Returns: `true` when the saved endpoint was updated (and the status
    ///   monitor was re-armed against the new address).
    @discardableResult
    public func rediscoverPairedEndpoint(
        connectionID: String
    ) async -> Bool {
        guard let connection = registry.connection(id: connectionID),
              connection.kind != .embedded,
              let serverID = connection.serverID,
              let existingPolicy = connection.trustPolicy else {
            return false
        }
        let now = Date()
        if let last = lastRediscoveryAttempt[connectionID],
           now.timeIntervalSince(last) < Self.rediscoveryMinInterval {
            return false
        }
        lastRediscoveryAttempt[connectionID] = now

        guard let endpoint = await endpointResolver(serverID),
              endpoint != connection.endpoint,
              let host = endpoint.host else {
            return false
        }
        let updated: RuntimeServerConnection
        do {
            updated = try RuntimeServerConnection(
                id: connection.id,
                displayName: connection.displayName,
                kind: connection.kind,
                endpoint: endpoint,
                authentication: connection.authentication,
                trustPolicy: RuntimeServerTrustPolicy(
                    expectedHost: host,
                    spkiSHA256: existingPolicy.spkiSHA256
                ),
                serverID: serverID,
                createdAt: connection.createdAt,
                updatedAt: now
            )
        } catch {
            return false
        }
        do {
            try registry.upsert(updated)
        } catch {
            return false
        }
        externalStatusMonitor(for: updated).update(connection: updated)
        return true
    }

    // MARK: - Private

    private func loadContext(
        connection: RuntimeServerConnection
    ) async throws -> RuntimeServerActiveContext {
        let preflight: RuntimeServerPreflightResult
        switch connection.kind {
        case .embedded:
#if canImport(CodeAgentRuntime)
            let client = try makeHTTPClient(connection: connection)
            guard try await client.healthCheck() else {
                throw RuntimeServerPreflightError.offline
            }
            let info = try await client.runtimeInfo()
            guard info.isAgentWireV1Compatible else {
                throw RuntimeServerPreflightError.protocolIncompatible
            }
            let capabilities = try await client.runtimeCapabilities()
            let models = try await client.runtimeModels()
            guard models.hasSupportedSchema else {
                throw RuntimeServerPreflightError.invalidModelCatalogSchema(
                    models.schema
                )
            }
            preflight = RuntimeServerPreflightResult(
                endpoint: try await RuntimeEnvironment.fromRuntime().baseURL
                    .unwrap(or: RuntimeHTTPError.runtimeNotStarted),
                kind: .embedded,
                authentication: .bearer,
                trustPolicy: nil,
                info: info,
                capabilities: capabilities,
                modelCatalog: models,
                checkedAt: Date()
            )
#else
            preflight = try await preflightService.test(
                connection: connection,
                credentialStore: runtimeCredentialStore
            )
            if let expected = connection.serverID,
               expected != preflight.info.serverID {
                throw RuntimeServerPreflightError.serverIdentityChanged(
                    expected: expected,
                    actual: preflight.info.serverID
                )
            }
#endif
        case .local, .remote:
            var effective = connection
            do {
                preflight = try await preflightService.test(
                    connection: effective,
                    credentialStore: runtimeCredentialStore
                )
            } catch {
                // The Mac may have restarted and moved its shared listener to a
                // new port. For paired connections, re-resolve the current
                // endpoint over Bonjour and retry once before failing.
                guard await rediscoverPairedEndpoint(connectionID: connection.id),
                      let refreshed = registry.connection(id: connection.id) else {
                    throw error
                }
                effective = refreshed
                preflight = try await preflightService.test(
                    connection: effective,
                    credentialStore: runtimeCredentialStore
                )
            }
            if let expected = effective.serverID,
               expected != preflight.info.serverID {
                throw RuntimeServerPreflightError.serverIdentityChanged(
                    expected: expected,
                    actual: preflight.info.serverID
                )
            }
        }
        return Self.context(connectionID: connection.id, preflight: preflight)
    }

    private func makeHTTPClient(
        connection: RuntimeServerConnection
    ) throws -> RuntimeHTTPClient {
        switch connection.kind {
        case .embedded:
#if canImport(CodeAgentRuntime)
            let runtime = AgentRuntime.shared
            return RuntimeHTTPClient(
                environment: .fromRuntime(),
                credentialStore: runtime.runtimeAccessCredentialStore,
                credentialTarget: runtime.runtimeAccessCredentialStore.target
            )
#else
            throw RuntimeServerRegistryError.invalidEmbeddedConnection
#endif
        case .local, .remote:
            guard let endpoint = connection.endpoint else {
                throw RuntimeServerRegistryError.invalidExternalEndpoint
            }
            let environment = try RuntimeEnvironment(origin: endpoint)
            switch connection.authentication {
            case .none:
                return RuntimeHTTPClient(
                    environment: environment,
                    trustPolicy: connection.trustPolicy
                )
            case .bearer:
                return RuntimeHTTPClient(
                    environment: environment,
                    credentialStore: runtimeCredentialStore,
                    credentialTarget: connection.credentialTarget,
                    trustPolicy: connection.trustPolicy
                )
            }
        }
    }

    private func externalStatusMonitor(
        for connection: RuntimeServerConnection
    ) -> ExternalRuntimeServerStatusMonitor {
        if let monitor = externalMonitors[connection.id] {
            monitor.update(connection: connection)
            return monitor
        }
        let monitor = ExternalRuntimeServerStatusMonitor(
            connection: connection,
            credentialStore: runtimeCredentialStore
        )
        externalMonitors[connection.id] = monitor
        return monitor
    }

    private static func context(
        connectionID: String,
        preflight: RuntimeServerPreflightResult
    ) -> RuntimeServerActiveContext {
        RuntimeServerActiveContext(
            serverConnectionID: connectionID,
            info: preflight.info,
            capabilities: preflight.capabilities,
            modelCatalog: preflight.modelCatalog,
            scopesModelIdentity: preflight.kind != .embedded,
            refreshedAt: preflight.checkedAt
        )
    }

    private static func suggestedPairedConnectionID(
        serverID: String,
        existing: Set<String>
    ) -> String {
        let base = "paired-\(serverID.prefix(12))"
        guard existing.contains(base) else { return base }
        var suffix = 2
        while existing.contains("\(base)-\(suffix)") {
            suffix += 1
        }
        return "\(base)-\(suffix)"
    }

    private static func normalizedSharingFallbackHost(_ value: String) -> String {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty,
              host.lowercased() != "localhost",
              !host.contains("."),
              !host.contains(":") else {
            return host
        }
        // Code-Agent's Bonjour advertiser publishes this hostname as
        // <hostname>.local. The daemon invitation historically returned the
        // bare hostname, so normalize only that unqualified-host case.
        return "\(host).local"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
