//
//  ConnectionsJSON.swift
//  AgentKit
//
//  connection-flattening v2：connection DEFINITIONS 的 wire 类型（non-secret）。
//  secretsJSON 只携带 value；定义（id / api type / base_url / credential 来源声明）
// 走本通道，host 无需手拼 wire。
//

import Foundation

/// connectionsJSON 文档顶层。
///
/// 对齐 design-connection-injection-channel §4：顶层只有 `connections` map
/// （connection_id → definition），**不含** schema 字段。
public struct RuntimeConnectionsDocument: Codable, Sendable, Equatable {
    /// connection_id → definition 的 map（与 secretsJSON 的 flat key 同源）。
    public let connections: [String: RuntimeConnectionDefinition]

    enum CodingKeys: String, CodingKey {
        case connections
    }

    public init(connections: [String: RuntimeConnectionDefinition]) {
        self.connections = connections
    }

    /// 编码为 gomobile 边界友好的 JSON 字符串。
    public func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            throw RuntimeProviderConfigurationError.encodingFailed
        }
        return json
    }
}

/// 单条 connection 定义。
public struct RuntimeConnectionDefinition: Codable, Sendable, Equatable, Identifiable {
    /// flat connection id（与 v2 secretsJSON key 同源）。
    public let id: String
    /// API 类型：`openai` | `ollama`。Gateway 使用 `openai` 协议，
    /// 通过 credential namespace `gateway` 表示身份。
    public let api: String
    public let baseURL: String
    /// credential 来源声明（non-secret）。
    public let credential: RuntimeConnectionCredentialDeclaration?
    /// 该 connection 的模型定义（alias → wire id / context / pricing）。
    public let models: [RuntimeConnectionModelDefinition]

    enum CodingKeys: String, CodingKey {
        case id, api, models
        case baseURL = "base_url"
        case credential
    }

    public init(
        id: String,
        api: String,
        baseURL: String,
        credential: RuntimeConnectionCredentialDeclaration?,
        models: [RuntimeConnectionModelDefinition]
    ) {
        self.id = id
        self.api = api
        self.baseURL = baseURL
        self.credential = credential
        self.models = models
    }
}

/// Credential reference for a connection. Mirrors settings.CredentialRef:
/// `{namespace, name}` resolves into the credentials section (e.g. `llm/deepseek`).
/// Legacy `source`/`ref`/`env` fields are deprecated — use `namespace`/`name`.
public struct RuntimeConnectionCredentialDeclaration: Codable, Sendable, Equatable {
    /// Credential namespace — typically `"llm"` or `"gateway"`.
    public let namespace: String?
    /// Credential name — the key within the namespace (e.g. provider id).
    public let name: String?
    /// Deprecated: use `namespace`/`name` instead.
    public let source: String?
    /// Deprecated: use `name` instead.
    public let ref: String?
    /// Deprecated: use `namespace`/`name` instead.
    public let env: String?

    public init(
        namespace: String? = nil,
        name: String? = nil,
        source: String? = nil,
        ref: String? = nil,
        env: String? = nil
    ) {
        self.namespace = namespace
        self.name = name
        self.source = source
        self.ref = ref
        self.env = env
    }
}

/// connection 内的模型定义（沿用 alias 格式 provider.<b64>.model.<b64>）。
public struct RuntimeConnectionModelDefinition: Codable, Sendable, Equatable, Identifiable {
    /// Identifiable conformance: stable per-connection model identity = runtime alias.
    public var id: String { runtimeAlias }
    public let runtimeAlias: String
    public let wireModelID: String
    public let contextWindow: Int?
    public let inputPricePerMillion: Double?
    public let outputPricePerMillion: Double?
    public let cacheInputPricePerMillion: Double?

    enum CodingKeys: String, CodingKey {
        case runtimeAlias = "runtime_alias"
        case wireModelID = "wire_model_id"
        case contextWindow = "context_window"
        case inputPricePerMillion = "input_price_per_million"
        case outputPricePerMillion = "output_price_per_million"
        case cacheInputPricePerMillion = "cache_input_price_per_million"
    }

    public init(
        runtimeAlias: String,
        wireModelID: String,
        contextWindow: Int?,
        inputPricePerMillion: Double?,
        outputPricePerMillion: Double?,
        cacheInputPricePerMillion: Double?
    ) {
        self.runtimeAlias = runtimeAlias
        self.wireModelID = wireModelID
        self.contextWindow = contextWindow
        self.inputPricePerMillion = inputPricePerMillion
        self.outputPricePerMillion = outputPricePerMillion
        self.cacheInputPricePerMillion = cacheInputPricePerMillion
    }
}
