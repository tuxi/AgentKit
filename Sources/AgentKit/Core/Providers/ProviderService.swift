//
//  ProviderService.swift
//  AgentKit
//
//  Stage ③: HTTP provider management over the runtime's /v1/providers API.
//
//  Desktop/server hosts manage provider configuration through the runtime
//  (single source of truth, persisted by the runtime to <root>/.codeagent/
//  settings.json). iOS embedded now uses the same HTTP surface: the embedded
//  runtime persists providers to <DataDir>/.codeagent/settings.json and
//  exposes /v1/providers + /v1/secrets exactly like the daemon, so the local
//  ProviderConnectionRegistry is a read-only cache on every platform.
//

import Foundation

// MARK: - Wire DTOs (mirror the settings `providers` section, §design)

/// Model DTO for the `/v1/providers` config-management protocol.
///
/// NOTE: this is intentionally distinct from `RuntimeConnectionModelDefinition`
/// (ConnectionsJSON.swift), which is the runtime-injection wire shape and emits
/// `runtime_alias` + `wire_model_id`. The providers protocol's ProviderModelDTO
/// requires `id` (json tag "id"); capability fields are optional extras.
public struct RuntimeProviderModelDefinition: Codable, Sendable, Equatable, Identifiable {
    /// Wire model id sent to the provider.
    public let id: String
    /// Short friendly name usable as default_model.
    public let runtimeAlias: String?
    /// Per-model API override (e.g. "responses" vs provider-level "openai").
    public let api: String?
    public let displayName: String?
    public let contextWindow: Int?
    public let temperature: Double?
    public let inputPricePerMillion: Double?
    public let outputPricePerMillion: Double?
    public let cacheInputPricePerMillion: Double?
    public let supportsTools: Bool?
    public let supportsReasoning: Bool?
    public let inputModalities: [String]?
    public let webSearch: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case runtimeAlias = "runtime_alias"
        case api
        case displayName = "display_name"
        case contextWindow = "context_window"
        case temperature
        case inputPricePerMillion = "input_price_per_million"
        case outputPricePerMillion = "output_price_per_million"
        case cacheInputPricePerMillion = "cache_input_price_per_million"
        case supportsTools = "supports_tools"
        case supportsReasoning = "supports_reasoning"
        case inputModalities = "input_modalities"
        case webSearch = "web_search"
    }

    public init(
        id: String,
        runtimeAlias: String? = nil,
        api: String? = nil,
        displayName: String? = nil,
        contextWindow: Int? = nil,
        temperature: Double? = nil,
        inputPricePerMillion: Double? = nil,
        outputPricePerMillion: Double? = nil,
        cacheInputPricePerMillion: Double? = nil,
        supportsTools: Bool? = nil,
        supportsReasoning: Bool? = nil,
        inputModalities: [String]? = nil,
        webSearch: Bool? = nil
    ) {
        self.id = id
        self.runtimeAlias = runtimeAlias
        self.api = api
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.temperature = temperature
        self.inputPricePerMillion = inputPricePerMillion
        self.outputPricePerMillion = outputPricePerMillion
        self.cacheInputPricePerMillion = cacheInputPricePerMillion
        self.supportsTools = supportsTools
        self.supportsReasoning = supportsReasoning
        self.inputModalities = inputModalities
        self.webSearch = webSearch
    }
}

/// Full provider definition exchanged with `/v1/providers`.
///
/// Mirrors the runtime settings `providers` section (service id → definition):
/// `{id, api, base_url, credential, headers, models[], enabled}`.
/// `credential` carries only a source declaration (non-secret); values live in
/// the host CredentialStore / secretsJSON.
public struct RuntimeProviderDefinition: Codable, Sendable, Equatable, Identifiable {
    /// Service id — same namespace as the flat secretsJSON / connectionsJSON key.
    public let id: String
    /// `openai` | `ollama`. Gateway uses the OpenAI-compatible protocol.
    public let api: String
    public let baseURL: String
    public let credential: RuntimeConnectionCredentialDeclaration?
    /// Extra HTTP headers for this provider's upstream (never Authorization —
    /// that is injected from the credential source).
    public let headers: [String: String]?
    /// OQ1 (design §8.1): `enabled` defaults to true; false keeps the config but
    /// the runtime skips its models.
    public let enabled: Bool?
    public let models: [RuntimeProviderModelDefinition]

    enum CodingKeys: String, CodingKey {
        case id, api, models, credential, headers, enabled
        case baseURL = "base_url"
    }

    public init(
        id: String,
        api: String,
        baseURL: String,
        credential: RuntimeConnectionCredentialDeclaration?,
        headers: [String: String]? = nil,
        enabled: Bool? = true,
        models: [RuntimeProviderModelDefinition]
    ) {
        self.id = id
        self.api = api
        self.baseURL = baseURL
        self.credential = credential
        self.headers = headers
        self.enabled = enabled
        self.models = models
    }
}

/// Lightweight provider reference returned by list operations.
@available(*, unavailable, message: "GET /v1/providers returns full definitions; use RuntimeProviderDefinition")
public struct RuntimeProviderSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let enabled: Bool?
}

/// OQ2 (design §8.1): PUT/DELETE response marker.
/// `applied == true` → live reconfigure succeeded.
/// `applied == false` → persisted, but a restart is required to take effect
/// (the runtime's reconfigure hook is nil, e.g. daemon mode).
public struct RuntimeProviderWriteResult: Codable, Sendable, Equatable {
    public let applied: Bool

    public init(applied: Bool) {
        self.applied = applied
    }
}

// MARK: - Provider Templates (GET /v1/provider-templates)

/// A built-in provider template exposed by the runtime. Describes a known service
/// the user can connect to with suggested models and defaults.
public struct RuntimeProviderTemplate: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String?
    public let summary: String?
    public let kind: String?     // "api_key" | "local" | "gateway"
    public let baseURL: String?
    public let api: String?
    public let env: String?
    public let models: [RuntimeProviderTemplateModel]?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case summary
        case kind
        case baseURL = "base_url"
        case api
        case env
        case models
    }

    public init(
        id: String,
        displayName: String? = nil,
        summary: String? = nil,
        kind: String? = nil,
        baseURL: String? = nil,
        api: String? = nil,
        env: String? = nil,
        models: [RuntimeProviderTemplateModel]? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.kind = kind
        self.baseURL = baseURL
        self.api = api
        self.env = env
        self.models = models
    }
}

/// One suggested model in a provider template.
public struct RuntimeProviderTemplateModel: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let runtimeAlias: String?
    public let contextWindow: Int?
    public let temperature: Double?
    public let supportsTools: Bool?
    public let supportsReasoning: Bool?
    public let inputModalities: [String]?
    public let webSearch: Bool?
    public let inputPricePerMillion: Double?
    public let outputPricePerMillion: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case runtimeAlias = "runtime_alias"
        case contextWindow = "context_window"
        case temperature = "temperature"
        case supportsTools = "supports_tools"
        case supportsReasoning = "supports_reasoning"
        case inputModalities = "input_modalities"
        case webSearch = "web_search"
        case inputPricePerMillion = "input_price_per_million"
        case outputPricePerMillion = "output_price_per_million"
    }

    public init(
        id: String,
        runtimeAlias: String? = nil,
        contextWindow: Int? = nil,
        temperature: Double? = nil,
        supportsTools: Bool? = nil,
        supportsReasoning: Bool? = nil,
        inputModalities: [String]? = nil,
        webSearch: Bool? = nil,
        inputPricePerMillion: Double? = nil,
        outputPricePerMillion: Double? = nil
    ) {
        self.id = id
        self.runtimeAlias = runtimeAlias
        self.contextWindow = contextWindow
        self.temperature = temperature
        self.supportsTools = supportsTools
        self.supportsReasoning = supportsReasoning
        self.inputModalities = inputModalities
        self.webSearch = webSearch
        self.inputPricePerMillion = inputPricePerMillion
        self.outputPricePerMillion = outputPricePerMillion
    }
}

// MARK: - Mapping (ProviderConnection ↔ RuntimeProviderDefinition)

public extension ProviderConnection {
    /// Maps a local connection to the `/v1/providers` wire definition.
    ///
    /// Lossy: `providerID`, `displayName`, `modelSource` and
    /// `allowsInsecurePrivateNetworkHTTP` have no DTO slot and are not carried.
    func asRuntimeProviderDefinition() -> RuntimeProviderDefinition {
        let api: String
        switch transport {
        case .ollama:
            api = "ollama"
        case .openAIChatCompletions:
            // Gateway is a connection/credential kind. The runtime talks to
            // it through the OpenAI-compatible Chat Completions protocol.
            api = "openai"
        }

        let credential: RuntimeConnectionCredentialDeclaration?
        switch authentication {
        case .gatewayAccount:
            credential = RuntimeConnectionCredentialDeclaration(namespace: "gateway", name: "default")
        case .apiKey:
            credential = RuntimeConnectionCredentialDeclaration(namespace: "llm", name: id)
        case .none:
            credential = nil
        }

        let models = self.models.map { model in
            RuntimeProviderModelDefinition(
                id: model.id,
                runtimeAlias: model.runtimeAlias,
                api: model.api,
                displayName: model.displayName,
                contextWindow: model.contextWindow,
                temperature: model.temperature,
                inputPricePerMillion: model.inputPricePerMillion,
                outputPricePerMillion: model.outputPricePerMillion,
                cacheInputPricePerMillion: model.cacheInputPricePerMillion,
                supportsTools: model.supportsTools,
                supportsReasoning: model.supportsReasoning,
                inputModalities: model.inputModalities.map { $0.rawValue },
                webSearch: model.webSearch
            )
        }

        return RuntimeProviderDefinition(
            id: id,
            api: api,
            baseURL: baseURL.absoluteString.trimmingTrailingSlashes,
            credential: credential,
            enabled: isEnabled,
            models: models
        )
    }
}

public extension RuntimeProviderDefinition {
    /// Rehydrates a local connection from a `/v1/providers` definition.
    ///
    /// Lossy: `providerID` defaults to `openai-compatible`, `displayName` to the
    /// id, `modelSource` to `.configured`, `allowsInsecurePrivateNetworkHTTP`
    /// to false. Models map `id` → ProviderModel.id (capability flags carried
    /// when present).
    func asProviderConnection() -> ProviderConnection {
        let transport: ProviderTransport = api == "ollama" ? .ollama : .openAIChatCompletions
        let authentication: ProviderAuthentication
        if api == "gateway" || credential?.namespace == "gateway" {
            authentication = .gatewayAccount
        } else if credential != nil {
            authentication = .apiKey
        } else {
            authentication = .none
        }
        let models = models.map { model in
            let modalities: Set<ProviderInputModality>? = model.inputModalities.map { raw in
                Set(raw.compactMap { ProviderInputModality(rawValue: $0) })
            }
            return ProviderModel(
                id: model.id,
                runtimeAlias: model.runtimeAlias,
                api: model.api,
                displayName: model.displayName,
                contextWindow: model.contextWindow,
                temperature: model.temperature,
                supportsTools: model.supportsTools ?? true,
                supportsReasoning: model.supportsReasoning ?? false,
                inputModalities: modalities ?? [.text],
                inputPricePerMillion: model.inputPricePerMillion,
                outputPricePerMillion: model.outputPricePerMillion,
                cacheInputPricePerMillion: model.cacheInputPricePerMillion,
                webSearch: model.webSearch ?? false
            )
        }
        return ProviderConnection(
            id: id,
            providerID: "openai-compatible",
            displayName: id,
            transport: transport,
            authentication: authentication,
            baseURL: URL(string: baseURL) ?? URL(string: "https://invalid.local")!,
            models: models,
            isEnabled: enabled ?? true
        )
    }
}

// MARK: - ProviderStore

/// Host-facing provider-management surface.
///
/// Every deployment uses the HTTP-backed `RuntimeProviderService`: the runtime
/// (daemon or embedded) is the single source of truth, persisting providers to
/// its settings.json. `LocalProviderStore` (registry-backed) is retained only
/// as a migration fallback and must not be used for new writes.
public protocol ProviderStore: Sendable {
    func listProviders() async throws -> [RuntimeProviderDefinition]
    func getProvider(id: String) async throws -> RuntimeProviderDefinition?
    func upsertProvider(_ definition: RuntimeProviderDefinition) async throws -> RuntimeProviderWriteResult
    func deleteProvider(id: String) async throws -> RuntimeProviderWriteResult
    func listProviderTemplates() async throws -> [RuntimeProviderTemplate]
    /// `POST /v1/secrets` — push provider credential values into the runtime's
    /// mutable injected resolver so models become available without a restart.
    func pushSecrets(_ entries: [String: RuntimeSecretEntry]) async throws
    /// `POST /v1/settings/reload` — apply a settings.json snapshot immediately.
    func reloadSettings() async throws
}

/// Picks the store for a deployment. All active deployments use the HTTP-backed
/// store; `embedded(registry:)` exists only for migration/fallback.
public enum ProviderStoreFactory {
    /// Registry-backed store (migration fallback only). Writes apply locally
    /// and must be re-injected; prefer `http(for:credentialStore:)` which now
    /// also serves the embedded runtime.
    @MainActor
    public static func embedded(registry: ProviderConnectionRegistry) -> any ProviderStore {
        LocalProviderStore(registry: registry)
    }

    /// Desktop/server: HTTP-backed store against a Runtime Server.
    public static func http(
        environment: RuntimeEnvironment,
        credentialStore: (any CredentialStore)? = nil,
        credentialTarget: CredentialTarget = .runtimeAccess("default"),
        trustPolicy: RuntimeServerTrustPolicy? = nil
    ) -> any ProviderStore {
        RuntimeProviderService(
            environment: environment,
            credentialStore: credentialStore,
            credentialTarget: credentialTarget,
            trustPolicy: trustPolicy
        )
    }

    /// Connection-scoped HTTP-backed store (embedded + desktop/server).
    ///
    /// Resolves the Bearer token through `credentialStore` for the connection's
    /// credential target (`.runtimeAccess(connection.id)`) — the same path
    /// `/v1/runtime/models` uses. Embedded connections resolve the rotated
    /// process-local Runtime Access credential directly from `AgentRuntime`,
    /// because the embedded loopback listener has no fixed endpoint.
    public static func http(
        for connection: RuntimeServerConnection,
        credentialStore: any CredentialStore,
        trustPolicy: RuntimeServerTrustPolicy? = nil
    ) throws -> any ProviderStore {
        switch connection.kind {
        case .embedded:
            #if canImport(CodeAgentRuntime)
            let runtime = AgentRuntime.shared
            return RuntimeProviderService(
                environment: .fromRuntime(),
                credentialStore: runtime.runtimeAccessCredentialStore,
                credentialTarget: runtime.runtimeAccessCredentialStore.target,
                trustPolicy: trustPolicy
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
                return RuntimeProviderService(
                    environment: environment,
                    trustPolicy: trustPolicy
                )
            case .bearer:
                return RuntimeProviderService(
                    environment: environment,
                    credentialStore: credentialStore,
                    credentialTarget: connection.credentialTarget,
                    trustPolicy: trustPolicy
                )
            }
        }
    }
}

// MARK: - RuntimeProviderService (HTTP-backed)

/// HTTP-backed provider store talking to the runtime's `/v1/providers` API.
///
/// Auth is identical to `/v1/runtime/models`: a Bearer token resolved from
/// `credentialStore` for `credentialTarget` (embedded: the rotated Runtime
/// Access credential; external: the server connection credential). Provider
/// credentials are never used for the control plane.
public struct RuntimeProviderService: ProviderStore, Sendable {
    private let client: RuntimeHTTPClient

    public init(
        environment: RuntimeEnvironment,
        credentialStore: (any CredentialStore)? = nil,
        credentialTarget: CredentialTarget = .runtimeAccess("default"),
        trustPolicy: RuntimeServerTrustPolicy? = nil
    ) {
        self.client = RuntimeHTTPClient(
            environment: environment,
            credentialStore: credentialStore,
            credentialTarget: credentialTarget,
            trustPolicy: trustPolicy
        )
    }

    /// Test seam: build the service over an explicitly-constructed client.
    init(client: RuntimeHTTPClient) {
        self.client = client
    }

    #if canImport(CodeAgentRuntime)
    /// Embedded convenience: lazy loopback port + the process-local Runtime
    /// Access credential. The embedded runtime persists its providers to
    /// `<DataDir>/.codeagent/settings.json`, so `/v1/providers` reads and writes
    /// work exactly like the daemon's user-scope file.
    public static func fromRuntime() -> RuntimeProviderService {
        let runtime = AgentRuntime.shared
        return RuntimeProviderService(
            environment: .fromRuntime(),
            credentialStore: runtime.runtimeAccessCredentialStore,
            credentialTarget: runtime.runtimeAccessCredentialStore.target
        )
    }
    #endif

    public func listProviders() async throws -> [RuntimeProviderDefinition] {
        try await client.listProviders()
    }

    public func getProvider(id: String) async throws -> RuntimeProviderDefinition? {
        do {
            return try await client.getProvider(id: id)
        } catch RuntimeHTTPError.notFound {
            return nil
        }
    }

    public func upsertProvider(_ definition: RuntimeProviderDefinition) async throws -> RuntimeProviderWriteResult {
        try await client.upsertProvider(definition)
    }

    public func deleteProvider(id: String) async throws -> RuntimeProviderWriteResult {
        try await client.deleteProvider(id: id)
    }

    public func listProviderTemplates() async throws -> [RuntimeProviderTemplate] {
        try await client.listProviderTemplates()
    }

    public func pushSecrets(_ entries: [String: RuntimeSecretEntry]) async throws {
        try await client.pushSecrets(entries)
    }

    public func reloadSettings() async throws {
        try await client.reloadSettings()
    }
}

// MARK: - LocalProviderStore (registry-backed, iOS embedded)

/// Registry-backed provider store for iOS embedded deployments.
/// Writes go to `ProviderConnectionRegistry` (UserDefaults) and take effect on
/// the runtime only after re-injection (`configureProviderConnections` /
/// `buildConnectionsJSON` + restart or reconfigure). Applied is always true
/// (local persistence is immediate).
@MainActor
public struct LocalProviderStore: ProviderStore {
    private let registry: ProviderConnectionRegistry

    public init(registry: ProviderConnectionRegistry) {
        self.registry = registry
    }

    public func listProviders() async throws -> [RuntimeProviderDefinition] {
        registry.connections.map { $0.asRuntimeProviderDefinition() }
    }

    public func getProvider(id: String) async throws -> RuntimeProviderDefinition? {
        registry.connection(id: id)?.asRuntimeProviderDefinition()
    }

    public func upsertProvider(_ definition: RuntimeProviderDefinition) async throws -> RuntimeProviderWriteResult {
        try registry.upsert(definition.asProviderConnection())
        return RuntimeProviderWriteResult(applied: true)
    }

    public func deleteProvider(id: String) async throws -> RuntimeProviderWriteResult {
        registry.remove(connectionID: id)
        return RuntimeProviderWriteResult(applied: true)
    }

    /// iOS embedded has no server to fetch templates from; the app layer keeps a
    /// local "custom" fallback template.
    public func listProviderTemplates() async throws -> [RuntimeProviderTemplate] {
        []
    }

    /// Registry-backed store has no runtime /v1/secrets surface; credential
    /// values flow through the host's legacy injection path instead.
    public func pushSecrets(_ entries: [String: RuntimeSecretEntry]) async throws {
        // No-op: migration fallback only.
    }

    public func reloadSettings() async throws {
        // No-op: migration fallback only.
    }
}

private extension String {
    var trimmingTrailingSlashes: String {
        var result = self
        while result.last == "/" {
            result.removeLast()
        }
        return result
    }
}
