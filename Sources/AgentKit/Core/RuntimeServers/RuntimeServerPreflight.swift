//
//  RuntimeServerPreflight.swift
//  AgentKit
//
//  Validated handshake for adding, editing and activating External Runtime Servers.
//

import Foundation

public struct RuntimeServerPreflightResult: Sendable, Equatable {
    public let endpoint: URL
    public let kind: RuntimeServerKind
    public let authentication: RuntimeServerAuthentication
    public let trustPolicy: RuntimeServerTrustPolicy?
    public let info: RuntimeServerInfo
    public let capabilities: RuntimeCapabilitySnapshot
    public let modelCatalog: RuntimeServerModelCatalog
    public let checkedAt: Date

    public init(
        endpoint: URL,
        kind: RuntimeServerKind,
        authentication: RuntimeServerAuthentication,
        trustPolicy: RuntimeServerTrustPolicy? = nil,
        info: RuntimeServerInfo,
        capabilities: RuntimeCapabilitySnapshot,
        modelCatalog: RuntimeServerModelCatalog,
        checkedAt: Date
    ) {
        self.endpoint = endpoint
        self.kind = kind
        self.authentication = authentication
        self.trustPolicy = trustPolicy
        self.info = info
        self.capabilities = capabilities
        self.modelCatalog = modelCatalog
        self.checkedAt = checkedAt
    }
}

public enum RuntimeServerPreflightError: Error, LocalizedError, Equatable {
    case accessTokenRequired
    case accessTokenTooShort
    case authenticationRequired
    case authenticationInvalid
    case offline
    case protocolIncompatible
    case capabilitiesUnavailable
    case modelCatalogUnavailable
    case invalidModelCatalogSchema(String)
    case serverIdentityChanged(expected: String, actual: String)
    case duplicateServerIdentity(connectionID: String)

    public var errorDescription: String? {
        switch self {
        case .accessTokenRequired:
            "Runtime Server Access Token is required."
        case .accessTokenTooShort:
            "Runtime Server Access Token must contain at least 32 bytes."
        case .authenticationRequired:
            "Runtime Server requires an Access Token."
        case .authenticationInvalid:
            "Runtime Server Access Token is invalid."
        case .offline:
            "Runtime Server is offline or its health check failed."
        case .protocolIncompatible:
            "Runtime Server schema, product, or Agent Wire major is incompatible."
        case .capabilitiesUnavailable:
            "Runtime Server capabilities are unavailable."
        case .modelCatalogUnavailable:
            "Runtime Server model catalog is unavailable."
        case .invalidModelCatalogSchema(let schema):
            "Runtime Server returned an unsupported model catalog schema: \(schema)"
        case .serverIdentityChanged(let expected, let actual):
            "Runtime Server identity changed from \(expected) to \(actual)."
        case .duplicateServerIdentity(let connectionID):
            "This Runtime Server is already registered as \(connectionID)."
        }
    }
}

struct RuntimeServerPreflightService: Sendable {
    let platform: RuntimeServerClientPlatform

    init(platform: RuntimeServerClientPlatform = .current) {
        self.platform = platform
    }

    func test(
        endpoint: URL,
        authentication: RuntimeServerAuthentication,
        accessToken: String?,
        trustPolicy: RuntimeServerTrustPolicy? = nil
    ) async throws -> RuntimeServerPreflightResult {
        let kind = try RuntimeServerEndpointClassifier.kind(
            for: endpoint,
            platform: platform
        )
        try RuntimeServerEndpointClassifier.validateSecurity(
            endpoint: endpoint,
            kind: kind,
            authentication: authentication,
            platform: platform
        )
        let environment = try RuntimeEnvironment(origin: endpoint)

        let client: RuntimeHTTPClient
        switch authentication {
        case .none:
            client = RuntimeHTTPClient(
                environment: environment,
                trustPolicy: trustPolicy
            )
        case .bearer:
            guard let accessToken, !accessToken.isEmpty else {
                throw RuntimeServerPreflightError.accessTokenRequired
            }
            guard accessToken.lengthOfBytes(using: .utf8) >= 32 else {
                throw RuntimeServerPreflightError.accessTokenTooShort
            }
            let target = CredentialTarget.runtimeAccess("preflight")
            client = RuntimeHTTPClient(
                environment: environment,
                credentialStore: RuntimeServerProbeCredentialStore(
                    target: target,
                    token: accessToken
                ),
                credentialTarget: target,
                trustPolicy: trustPolicy
            )
        }
        return try await test(
            client: client,
            endpoint: endpoint,
            kind: kind,
            authentication: authentication,
            trustPolicy: trustPolicy
        )
    }

    func test(
        connection: RuntimeServerConnection,
        credentialStore: any CredentialStore
    ) async throws -> RuntimeServerPreflightResult {
        guard connection.kind != .embedded, let endpoint = connection.endpoint else {
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
            guard let credential = try await credentialStore.resolve(
                connection.credentialTarget
            ), credential.kind == .bearer, !credential.secret.isEmpty else {
                throw RuntimeServerPreflightError.accessTokenRequired
            }
            client = RuntimeHTTPClient(
                environment: environment,
                credentialStore: credentialStore,
                credentialTarget: connection.credentialTarget,
                trustPolicy: connection.trustPolicy
            )
        }
        return try await test(
            client: client,
            endpoint: endpoint,
            kind: connection.kind,
            authentication: connection.authentication,
            trustPolicy: connection.trustPolicy
        )
    }

    private func test(
        client: RuntimeHTTPClient,
        endpoint: URL,
        kind: RuntimeServerKind,
        authentication: RuntimeServerAuthentication,
        trustPolicy: RuntimeServerTrustPolicy?
    ) async throws -> RuntimeServerPreflightResult {
        do {
            guard try await client.healthCheck() else {
                throw RuntimeServerPreflightError.offline
            }
        } catch let error as RuntimeServerPreflightError {
            throw error
        } catch {
            throw RuntimeServerPreflightError.offline
        }

        let info: RuntimeServerInfo
        do {
            info = try await client.runtimeInfo()
        } catch RuntimeHTTPError.authenticationRequired {
            throw RuntimeServerPreflightError.authenticationRequired
        } catch RuntimeHTTPError.authenticationInvalid {
            throw RuntimeServerPreflightError.authenticationInvalid
        } catch {
            throw RuntimeServerPreflightError.offline
        }
        guard info.isAgentWireV1Compatible else {
            throw RuntimeServerPreflightError.protocolIncompatible
        }

        let capabilities: RuntimeCapabilitySnapshot
        do {
            capabilities = try await client.runtimeCapabilities()
        } catch RuntimeHTTPError.authenticationRequired {
            throw RuntimeServerPreflightError.authenticationRequired
        } catch RuntimeHTTPError.authenticationInvalid {
            throw RuntimeServerPreflightError.authenticationInvalid
        } catch {
            throw RuntimeServerPreflightError.capabilitiesUnavailable
        }

        let models: RuntimeServerModelCatalog
        do {
            models = try await client.runtimeModels()
        } catch RuntimeHTTPError.authenticationRequired {
            throw RuntimeServerPreflightError.authenticationRequired
        } catch RuntimeHTTPError.authenticationInvalid {
            throw RuntimeServerPreflightError.authenticationInvalid
        } catch {
            throw RuntimeServerPreflightError.modelCatalogUnavailable
        }
        guard models.hasSupportedSchema else {
            throw RuntimeServerPreflightError.invalidModelCatalogSchema(models.schema)
        }
        return RuntimeServerPreflightResult(
            endpoint: endpoint,
            kind: kind,
            authentication: authentication,
            trustPolicy: trustPolicy,
            info: info,
            capabilities: capabilities,
            modelCatalog: models,
            checkedAt: Date()
        )
    }
}

private final class RuntimeServerProbeCredentialStore:
    CredentialStore,
    @unchecked Sendable
{
    private let target: CredentialTarget
    private let credential: Credential

    init(target: CredentialTarget, token: String) {
        self.target = target
        self.credential = Credential(kind: .bearer, secret: token)
    }

    func resolve(_ target: CredentialTarget) async throws -> Credential? {
        target == self.target ? credential : nil
    }

    func resolveSync(_ target: CredentialTarget) -> Credential? {
        target == self.target ? credential : nil
    }

    func all() async throws -> CredentialMap { CredentialMap() }
    func set(_ credential: Credential, for target: CredentialTarget) async throws {}
    func remove(_ target: CredentialTarget) async throws {}
    func clear() async throws {}
}
