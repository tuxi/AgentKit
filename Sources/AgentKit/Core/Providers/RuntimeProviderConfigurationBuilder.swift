//
//  RuntimeProviderConfigurationBuilder.swift
//  AgentKit
//
//  Produces the Code-Agent config document from secret-free connections.
//  JSON is intentionally emitted: JSON is valid YAML input for Code-Agent's
//  yaml.v3 decoder and avoids hand-written YAML escaping.
//

import Foundation

public struct RuntimeProviderConfigurationOptions: Sendable {
    public var maxSteps: Int
    public var maxParallelTools: Int
    public var compactRatio: Double
    public var clientToolTimeoutSeconds: Int
    public var requestTimeoutSeconds: Int
    public var maxRetries: Int
    public var backoffMillis: Int
    public var maxBackoffSeconds: Int
    public var maxConcurrentTurns: Int
    public var defaultContextWindow: Int
    public var currency: String
    public var enableGatewaySearch: Bool

    public init(
        maxSteps: Int = 33,
        maxParallelTools: Int = 4,
        compactRatio: Double = 0.75,
        clientToolTimeoutSeconds: Int = 900,
        requestTimeoutSeconds: Int = 600,
        maxRetries: Int = 5,
        backoffMillis: Int = 500,
        maxBackoffSeconds: Int = 8,
        maxConcurrentTurns: Int = 5,
        defaultContextWindow: Int = 128_000,
        currency: String = "$",
        enableGatewaySearch: Bool = true
    ) {
        self.maxSteps = maxSteps
        self.maxParallelTools = maxParallelTools
        self.compactRatio = compactRatio
        self.clientToolTimeoutSeconds = clientToolTimeoutSeconds
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.maxRetries = maxRetries
        self.backoffMillis = backoffMillis
        self.maxBackoffSeconds = maxBackoffSeconds
        self.maxConcurrentTurns = maxConcurrentTurns
        self.defaultContextWindow = defaultContextWindow
        self.currency = currency
        self.enableGatewaySearch = enableGatewaySearch
    }
}

public struct GeneratedRuntimeProviderConfiguration: Sendable {
    /// Settings.File JSON document (design-config-settings-merge.md) accepted by
    /// the runtime's settings.ParseJSON — the single config source at start:
    /// infrastructure (models/credentials/agent/provider/web/default_model/
    /// subagent_model) AND behavior (permissions/verify/hooks).
    public let settingsJSON: String
    public let models: [UnifiedModelDescriptor]
    public let defaultModelID: String?
    public let defaultRuntimeAlias: String?
    /// True for a history/workspace-only Runtime with no callable model.
    /// Requires Code-Agent empty-catalog startup support.
    public let isEmptyCatalog: Bool

    public init(
        settingsJSON: String,
        models: [UnifiedModelDescriptor],
        defaultModelID: String?,
        defaultRuntimeAlias: String?,
        isEmptyCatalog: Bool = false
    ) {
        self.settingsJSON = settingsJSON
        self.models = models
        self.defaultModelID = defaultModelID
        self.defaultRuntimeAlias = defaultRuntimeAlias
        self.isEmptyCatalog = isEmptyCatalog
    }
}

public enum RuntimeProviderConfigurationError: Error, LocalizedError, Equatable {
    case noEnabledModels
    case unknownDefaultModel(String)
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .noEnabledModels:
            "No enabled provider model is available."
        case .unknownDefaultModel(let id):
            "The default model is not present in the enabled provider catalog: \(id)"
        case .encodingFailed:
            "Unable to encode the embedded Runtime provider configuration."
        }
    }
}

// MARK: - Settings.File behavior sections (permissions / verify / hooks)

/// settings.File `permissions` section: `{allow, deny, protected_paths}`.
public struct RuntimeSettingsPermissions: Codable, Sendable, Equatable {
    public var allow: [String]?
    public var deny: [String]?
    public var protectedPaths: [String]?

    enum CodingKeys: String, CodingKey {
        case allow, deny
        case protectedPaths = "protected_paths"
    }

    public init(allow: [String]? = nil, deny: [String]? = nil, protectedPaths: [String]? = nil) {
        self.allow = allow
        self.deny = deny
        self.protectedPaths = protectedPaths
    }
}

/// settings.File `verify` section: `{command, enabled}`.
public struct RuntimeSettingsVerify: Codable, Sendable, Equatable {
    public var command: String?
    public var enabled: Bool?

    public init(command: String? = nil, enabled: Bool? = nil) {
        self.command = command
        self.enabled = enabled
    }
}

/// settings.File `hooks` entry: `{event, match, command}`.
public struct RuntimeSettingsHook: Codable, Sendable, Equatable {
    public var event: String
    public var match: String?
    public var command: String

    public init(event: String, match: String? = nil, command: String) {
        self.event = event
        self.match = match
        self.command = command
    }
}

public enum RuntimeProviderConfigurationBuilder {
    /// Builds an explicit no-model settings document so the Runtime can expose
    /// history and workspace APIs before a Provider is connected. Code-Agent
    /// must treat an empty `default_model` + empty `models` map as a
    /// non-callable Runtime; sending remains disabled by `ModelSettingsStore`.
    public static func buildEmpty(
        options: RuntimeProviderConfigurationOptions = .init()
    ) throws -> GeneratedRuntimeProviderConfiguration {
        let document = RuntimeSettingsDocument(
            defaultModel: "",
            subagentModel: nil,
            credentials: [:],
            models: [:],
            agent: RuntimeAgentConfig(
                maxSteps: options.maxSteps,
                maxParallelTools: options.maxParallelTools,
                compactRatio: options.compactRatio,
                clientToolTimeoutSeconds: options.clientToolTimeoutSeconds
            ),
            provider: RuntimeResilienceConfig(
                requestTimeoutSeconds: options.requestTimeoutSeconds,
                maxRetries: options.maxRetries,
                backoffMillis: options.backoffMillis,
                maxBackoffSeconds: options.maxBackoffSeconds
            ),
            web: RuntimeWebConfig(
                search: nil,
                fetch: RuntimeWebFetchConfig(timeoutSeconds: 30, cacheTTLSeconds: 600)
            ),
            runtime: RuntimeConcurrencyConfig(maxConcurrentTurns: options.maxConcurrentTurns),
            currency: options.currency,
            permissions: nil,
            verify: nil,
            hooks: nil
        )
        return GeneratedRuntimeProviderConfiguration(
            settingsJSON: try encode(document),
            models: [],
            defaultModelID: nil,
            defaultRuntimeAlias: nil,
            isEmptyCatalog: true
        )
    }

    public static func build(
        connections: [ProviderConnection],
        defaultModelID: String? = nil,
        options: RuntimeProviderConfigurationOptions = .init(),
        permissions: RuntimeSettingsPermissions? = nil,
        verify: RuntimeSettingsVerify? = nil,
        hooks: [RuntimeSettingsHook] = []
    ) throws -> GeneratedRuntimeProviderConfiguration {
        let enabled = connections.filter(\.isEnabled)
        let descriptors = enabled.unifiedModels
        guard let first = descriptors.first else {
            throw RuntimeProviderConfigurationError.noEnabledModels
        }

        let selected: UnifiedModelDescriptor
        if let defaultModelID {
            guard let requested = descriptors.first(where: { $0.id == defaultModelID }) else {
                throw RuntimeProviderConfigurationError.unknownDefaultModel(defaultModelID)
            }
            selected = requested
        } else {
            selected = first
        }

        let connectionByID = Dictionary(uniqueKeysWithValues: enabled.map { ($0.id, $0) })
        var credentials: [String: [String: RuntimeCredentialConfig]] = [:]
        var runtimeModels: [String: RuntimeModelConfig] = [:]

        for descriptor in descriptors {
            guard let connection = connectionByID[descriptor.connectionID] else { continue }
            let credentialRef: RuntimeCredentialRef?
            switch connection.authentication {
            case .gatewayAccount:
                credentials["gateway", default: [:]]["default"] = RuntimeCredentialConfig(source: "injected")
                credentialRef = RuntimeCredentialRef(namespace: "gateway", name: "default")
            case .apiKey:
                credentials["llm", default: [:]][connection.id] = RuntimeCredentialConfig(source: "injected")
                credentialRef = RuntimeCredentialRef(namespace: "llm", name: connection.id)
            case .none:
                credentialRef = nil
            }

            runtimeModels[descriptor.runtimeAlias] = RuntimeModelConfig(
                provider: connection.transport == .ollama ? "ollama" : "openai",
                baseURL: connection.baseURL.absoluteString.trimmingTrailingSlashes,
                model: descriptor.wireModelID,
                credential: credentialRef,
                contextWindow: descriptor.contextWindow ?? options.defaultContextWindow,
                inputPricePerMillion: descriptor.inputPricePerMillion,
                outputPricePerMillion: descriptor.outputPricePerMillion,
                cacheInputPricePerMillion: descriptor.cacheInputPricePerMillion,
                catalog: RuntimeModelCatalogConfig(
                    connectionID: descriptor.connectionID,
                    providerID: descriptor.providerID,
                    connectionDisplayName: descriptor.providerDisplayName,
                    displayName: descriptor.displayName,
                    supportsTools: descriptor.supportsTools,
                    supportsReasoning: descriptor.supportsReasoning,
                    inputModalities: descriptor.inputModalities
                        .sorted { $0.rawValue < $1.rawValue }
                        .map(\.rawValue)
                )
            )
        }

        let gateway = enabled.first {
            $0.authentication == .gatewayAccount && $0.isTalkifyGateway
        }
        let gatewaySearch: RuntimeWebSearchConfig?
        if options.enableGatewaySearch, let gateway {
            gatewaySearch = RuntimeWebSearchConfig(
                provider: "gateway",
                fallbackProvider: nil,
                gatewayBaseURL: gateway.baseURL.absoluteString.trimmingTrailingSlashes,
                topK: 5,
                timeoutSeconds: options.requestTimeoutSeconds,
                tavilyApiKeyEnv: nil,
                braveApiKeyEnv: nil
            )
        } else {
            gatewaySearch = nil
        }

        let document = RuntimeSettingsDocument(
            defaultModel: selected.runtimeAlias,
            subagentModel: nil,
            credentials: credentials,
            models: runtimeModels,
            agent: RuntimeAgentConfig(
                maxSteps: options.maxSteps,
                maxParallelTools: options.maxParallelTools,
                compactRatio: options.compactRatio,
                clientToolTimeoutSeconds: options.clientToolTimeoutSeconds
            ),
            provider: RuntimeResilienceConfig(
                requestTimeoutSeconds: options.requestTimeoutSeconds,
                maxRetries: options.maxRetries,
                backoffMillis: options.backoffMillis,
                maxBackoffSeconds: options.maxBackoffSeconds
            ),
            web: RuntimeWebConfig(
                search: gatewaySearch,
                fetch: RuntimeWebFetchConfig(timeoutSeconds: 30, cacheTTLSeconds: 600)
            ),
            runtime: RuntimeConcurrencyConfig(maxConcurrentTurns: options.maxConcurrentTurns),
            currency: options.currency,
            permissions: permissions,
            verify: verify,
            hooks: hooks.isEmpty ? nil : hooks
        )

        return GeneratedRuntimeProviderConfiguration(
            settingsJSON: try encode(document),
            models: descriptors,
            defaultModelID: selected.id,
            defaultRuntimeAlias: selected.runtimeAlias
        )
    }

    /// connection-flattening v2：把 enabled connection 序列化为 connectionsJSON
    /// （connection DEFINITIONS，non-secret）。顶层为 `{ "connections": { "<id>": {...} } }`
    /// map（对齐 design-connection-injection-channel §4），无 schema 字段。
    /// models 一并携带（alias → wire id / context / pricing）。secrets 仍走
    /// secretsJSON；credential 声明只描述来源。
    public static func buildConnectionsJSON(
        connections: [ProviderConnection]
    ) throws -> String {
        let enabled = connections.filter(\.isEnabled)
        var definitions: [String: RuntimeConnectionDefinition] = [:]
        for connection in enabled {
            let api: String
            switch connection.transport {
            case .ollama:
                api = "ollama"
            case .openAIChatCompletions:
                api = connection.isTalkifyGateway ? "gateway" : "openai"
            }

            let credential: RuntimeConnectionCredentialDeclaration?
            switch connection.authentication {
            case .gatewayAccount:
                credential = RuntimeConnectionCredentialDeclaration(
                    source: "injected",
                    ref: "gateway",
                    env: nil
                )
            case .apiKey:
                credential = RuntimeConnectionCredentialDeclaration(
                    source: "injected",
                    ref: connection.id,
                    env: nil
                )
            case .none:
                credential = nil
            }

            let models = connection.models.map { model in
                RuntimeConnectionModelDefinition(
                    runtimeAlias: UnifiedModelDescriptor.makeRuntimeAlias(
                        connectionID: connection.id,
                        wireModelID: model.id
                    ),
                    wireModelID: model.id,
                    contextWindow: model.contextWindow,
                    inputPricePerMillion: model.inputPricePerMillion,
                    outputPricePerMillion: model.outputPricePerMillion,
                    cacheInputPricePerMillion: model.cacheInputPricePerMillion
                )
            }

            definitions[connection.id] = RuntimeConnectionDefinition(
                id: connection.id,
                api: api,
                baseURL: connection.baseURL.absoluteString.trimmingTrailingSlashes,
                credential: credential,
                models: models
            )
        }
        let document = RuntimeConnectionsDocument(connections: definitions)
        return try document.encodedJSON()
    }

    private static func encode(_ document: RuntimeSettingsDocument) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(document),
              let settingsJSON = String(data: data, encoding: .utf8) else {
            throw RuntimeProviderConfigurationError.encodingFailed
        }
        return settingsJSON
    }
}

/// settings.File shape (design-config-settings-merge.md) that the runtime's
/// settings.ParseJSON expects. Field names must match exactly.
private struct RuntimeSettingsDocument: Encodable {
    let defaultModel: String
    let subagentModel: String?
    let credentials: [String: [String: RuntimeCredentialConfig]]
    let models: [String: RuntimeModelConfig]
    let agent: RuntimeAgentConfig
    let provider: RuntimeResilienceConfig
    let web: RuntimeWebConfig
    let runtime: RuntimeConcurrencyConfig
    let currency: String
    let permissions: RuntimeSettingsPermissions?
    let verify: RuntimeSettingsVerify?
    let hooks: [RuntimeSettingsHook]?

    enum CodingKeys: String, CodingKey {
        case defaultModel = "default_model"
        case subagentModel = "subagent_model"
        case credentials, models, agent, provider, web, runtime, currency
        case permissions, verify, hooks
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(defaultModel, forKey: .defaultModel)
        try container.encodeIfPresent(subagentModel, forKey: .subagentModel)
        try container.encode(credentials, forKey: .credentials)
        try container.encode(models, forKey: .models)
        try container.encode(agent, forKey: .agent)
        try container.encode(provider, forKey: .provider)
        try container.encode(web, forKey: .web)
        try container.encode(runtime, forKey: .runtime)
        try container.encode(currency, forKey: .currency)
        try container.encodeIfPresent(permissions, forKey: .permissions)
        try container.encodeIfPresent(verify, forKey: .verify)
        try container.encodeIfPresent(hooks, forKey: .hooks)
    }
}

private struct RuntimeCredentialConfig: Encodable {
    let source: String
    let env: String?

    init(source: String, env: String? = nil) {
        self.source = source
        self.env = env
    }
}

private struct RuntimeCredentialRef: Encodable {
    let namespace: String
    let name: String
}

private struct RuntimeModelConfig: Encodable {
    let provider: String
    let baseURL: String
    let model: String
    let credential: RuntimeCredentialRef?
    let apiKeyEnv: String?
    let temperature: Double?
    let contextWindow: Int
    let inputPricePerMillion: Double?
    let outputPricePerMillion: Double?
    let cacheInputPricePerMillion: Double?
    let catalog: RuntimeModelCatalogConfig?

    enum CodingKeys: String, CodingKey {
        case provider
        case baseURL = "base_url"
        case model, credential, temperature, catalog
        case apiKeyEnv = "api_key_env"
        case contextWindow = "context_window"
        case inputPricePerMillion = "input_price_per_million"
        case outputPricePerMillion = "output_price_per_million"
        case cacheInputPricePerMillion = "cache_input_price_per_million"
    }

    init(
        provider: String,
        baseURL: String,
        model: String,
        credential: RuntimeCredentialRef?,
        apiKeyEnv: String? = nil,
        temperature: Double? = nil,
        contextWindow: Int,
        inputPricePerMillion: Double?,
        outputPricePerMillion: Double?,
        cacheInputPricePerMillion: Double?,
        catalog: RuntimeModelCatalogConfig? = nil
    ) {
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.credential = credential
        self.apiKeyEnv = apiKeyEnv
        self.temperature = temperature
        self.contextWindow = contextWindow
        self.inputPricePerMillion = inputPricePerMillion
        self.outputPricePerMillion = outputPricePerMillion
        self.cacheInputPricePerMillion = cacheInputPricePerMillion
        self.catalog = catalog
    }
}

/// settings.File model `catalog` object: flattened per-model metadata that the
/// runtime's FromSettings receives alongside the model definition.
private struct RuntimeModelCatalogConfig: Encodable {
    let connectionID: String
    let providerID: String
    let connectionDisplayName: String
    let displayName: String
    let supportsTools: Bool?
    let supportsReasoning: Bool?
    let inputModalities: [String]?

    enum CodingKeys: String, CodingKey {
        case connectionID = "connection_id"
        case providerID = "provider_id"
        case connectionDisplayName = "connection_display_name"
        case displayName = "display_name"
        case supportsTools = "supports_tools"
        case supportsReasoning = "supports_reasoning"
        case inputModalities = "input_modalities"
    }
}

private struct RuntimeAgentConfig: Encodable {
    let maxSteps: Int
    let maxParallelTools: Int
    let compactRatio: Double
    let compactKeepRatio: Double?
    let clientToolTimeoutSeconds: Int
    let subagentModel: String?

    enum CodingKeys: String, CodingKey {
        case maxSteps = "max_steps"
        case maxParallelTools = "max_parallel_tools"
        case compactRatio = "compact_ratio"
        case compactKeepRatio = "compact_keep_ratio"
        case clientToolTimeoutSeconds = "client_tool_timeout_seconds"
        case subagentModel = "subagent_model"
    }

    init(
        maxSteps: Int,
        maxParallelTools: Int,
        compactRatio: Double,
        compactKeepRatio: Double? = nil,
        clientToolTimeoutSeconds: Int,
        subagentModel: String? = nil
    ) {
        self.maxSteps = maxSteps
        self.maxParallelTools = maxParallelTools
        self.compactRatio = compactRatio
        self.compactKeepRatio = compactKeepRatio
        self.clientToolTimeoutSeconds = clientToolTimeoutSeconds
        self.subagentModel = subagentModel
    }
}

private struct RuntimeResilienceConfig: Encodable {
    let requestTimeoutSeconds: Int
    let maxRetries: Int
    let backoffMillis: Int
    let maxBackoffSeconds: Int

    enum CodingKeys: String, CodingKey {
        case requestTimeoutSeconds = "request_timeout_seconds"
        case maxRetries = "max_retries"
        case backoffMillis = "backoff_millis"
        case maxBackoffSeconds = "max_backoff_seconds"
    }
}

private struct RuntimeWebConfig: Encodable {
    let search: RuntimeWebSearchConfig?
    let fetch: RuntimeWebFetchConfig

    enum CodingKeys: String, CodingKey {
        case search, fetch
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let search {
            try container.encode(search, forKey: .search)
        }
        try container.encode(fetch, forKey: .fetch)
    }
}

private struct RuntimeWebSearchConfig: Encodable {
    let provider: String
    let fallbackProvider: String?
    let gatewayBaseURL: String
    let topK: Int
    let timeoutSeconds: Int
    let tavilyApiKeyEnv: String?
    let braveApiKeyEnv: String?

    enum CodingKeys: String, CodingKey {
        case provider
        case fallbackProvider = "fallback_provider"
        case gatewayBaseURL = "gateway_base_url"
        case topK = "top_k"
        case timeoutSeconds = "timeout_seconds"
        case tavilyApiKeyEnv = "tavily_api_key_env"
        case braveApiKeyEnv = "brave_api_key_env"
    }

    init(
        provider: String,
        fallbackProvider: String? = nil,
        gatewayBaseURL: String,
        topK: Int,
        timeoutSeconds: Int,
        tavilyApiKeyEnv: String? = nil,
        braveApiKeyEnv: String? = nil
    ) {
        self.provider = provider
        self.fallbackProvider = fallbackProvider
        self.gatewayBaseURL = gatewayBaseURL
        self.topK = topK
        self.timeoutSeconds = timeoutSeconds
        self.tavilyApiKeyEnv = tavilyApiKeyEnv
        self.braveApiKeyEnv = braveApiKeyEnv
    }
}

private struct RuntimeWebFetchConfig: Encodable {
    let timeoutSeconds: Int
    let cacheTTLSeconds: Int

    enum CodingKeys: String, CodingKey {
        case timeoutSeconds = "timeout_seconds"
        case cacheTTLSeconds = "cache_ttl_seconds"
    }
}

private struct RuntimeConcurrencyConfig: Encodable {
    let maxConcurrentTurns: Int

    enum CodingKeys: String, CodingKey {
        case maxConcurrentTurns = "max_concurrent_turns"
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
