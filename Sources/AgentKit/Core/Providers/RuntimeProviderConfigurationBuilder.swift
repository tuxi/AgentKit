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
    /// JSON document accepted by Code-Agent's YAML decoder.
    public let configYAML: String
    public let models: [UnifiedModelDescriptor]
    public let defaultModelID: String?
    public let defaultRuntimeAlias: String?
    /// True for a history/workspace-only Runtime with no callable model.
    /// Requires Code-Agent empty-catalog startup support.
    public let isEmptyCatalog: Bool

    public init(
        configYAML: String,
        models: [UnifiedModelDescriptor],
        defaultModelID: String?,
        defaultRuntimeAlias: String?,
        isEmptyCatalog: Bool = false
    ) {
        self.configYAML = configYAML
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

public enum RuntimeProviderConfigurationBuilder {
    /// Builds an explicit no-model document so the Runtime can expose history
    /// and workspace APIs before a Provider is connected. Code-Agent must treat
    /// an empty `default_model` + empty `models` map as a non-callable Runtime;
    /// sending remains disabled by `ModelSettingsStore`.
    public static func buildEmpty(
        options: RuntimeProviderConfigurationOptions = .init()
    ) throws -> GeneratedRuntimeProviderConfiguration {
        let document = RuntimeConfigDocument(
            defaultModel: "",
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
            currency: options.currency
        )
        return GeneratedRuntimeProviderConfiguration(
            configYAML: try encode(document),
            models: [],
            defaultModelID: nil,
            defaultRuntimeAlias: nil,
            isEmptyCatalog: true
        )
    }

    public static func build(
        connections: [ProviderConnection],
        defaultModelID: String? = nil,
        options: RuntimeProviderConfigurationOptions = .init()
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
                cacheInputPricePerMillion: descriptor.cacheInputPricePerMillion
            )
        }

        let gateway = enabled.first {
            $0.authentication == .gatewayAccount && $0.isTalkifyGateway
        }
        let gatewaySearch: RuntimeWebSearchConfig?
        if options.enableGatewaySearch, let gateway {
            gatewaySearch = RuntimeWebSearchConfig(
                provider: "gateway",
                gatewayBaseURL: gateway.baseURL.absoluteString.trimmingTrailingSlashes,
                credential: RuntimeCredentialRef(namespace: "gateway", name: "default"),
                topK: 5,
                gatewayTimeoutSeconds: options.requestTimeoutSeconds
            )
        } else {
            gatewaySearch = nil
        }

        let document = RuntimeConfigDocument(
            defaultModel: selected.runtimeAlias,
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
            currency: options.currency
        )

        return GeneratedRuntimeProviderConfiguration(
            configYAML: try encode(document),
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

    private static func encode(_ document: RuntimeConfigDocument) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(document),
              let configYAML = String(data: data, encoding: .utf8) else {
            throw RuntimeProviderConfigurationError.encodingFailed
        }
        return configYAML
    }
}

private struct RuntimeConfigDocument: Encodable {
    let defaultModel: String
    let credentials: [String: [String: RuntimeCredentialConfig]]
    let models: [String: RuntimeModelConfig]
    let agent: RuntimeAgentConfig
    let provider: RuntimeResilienceConfig
    let web: RuntimeWebConfig
    let runtime: RuntimeConcurrencyConfig
    let currency: String

    enum CodingKeys: String, CodingKey {
        case defaultModel = "default_model"
        case credentials, models, agent, provider, web, runtime, currency
    }
}

private struct RuntimeCredentialConfig: Encodable {
    let source: String
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
    let contextWindow: Int
    let inputPricePerMillion: Double?
    let outputPricePerMillion: Double?
    let cacheInputPricePerMillion: Double?

    enum CodingKeys: String, CodingKey {
        case provider
        case baseURL = "base_url"
        case model, credential
        case contextWindow = "context_window"
        case inputPricePerMillion = "input_price_per_million"
        case outputPricePerMillion = "output_price_per_million"
        case cacheInputPricePerMillion = "cache_input_price_per_million"
    }
}

private struct RuntimeAgentConfig: Encodable {
    let maxSteps: Int
    let maxParallelTools: Int
    let compactRatio: Double
    let clientToolTimeoutSeconds: Int

    enum CodingKeys: String, CodingKey {
        case maxSteps = "max_steps"
        case maxParallelTools = "max_parallel_tools"
        case compactRatio = "compact_ratio"
        case clientToolTimeoutSeconds = "client_tool_timeout_seconds"
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
    let gatewayBaseURL: String
    let credential: RuntimeCredentialRef
    let topK: Int
    let gatewayTimeoutSeconds: Int

    enum CodingKeys: String, CodingKey {
        case provider
        case gatewayBaseURL = "gateway_base_url"
        case credential
        case topK = "top_k"
        case gatewayTimeoutSeconds = "gateway_timeout_seconds"
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
