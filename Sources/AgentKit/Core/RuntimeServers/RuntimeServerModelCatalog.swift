//
//  RuntimeServerModelCatalog.swift
//  AgentKit
//
//  Allowlisted model catalog returned by a CodeAgent Runtime Server.
//

import Foundation

public struct RuntimeServerModelIdentity: Codable, Hashable, Sendable {
    public let serverConnectionID: String
    public let runtimeAlias: String

    public init(serverConnectionID: String, runtimeAlias: String) {
        self.serverConnectionID = serverConnectionID
        self.runtimeAlias = runtimeAlias
    }

    public var stableID: String {
        "runtime.\(Self.encode(serverConnectionID)).model.\(Self.encode(runtimeAlias))"
    }

    private static func encode(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct RuntimeServerModelCatalog: Codable, Sendable, Equatable {
    /// Bridging period: accept every schema under this prefix (v1 AND v2) so
    /// old SDK binaries interoperate with v2 runtimes and vice-versa. Any
    /// future version keeps the prefix contract.
    public static let supportedSchemaPrefix = "runtime-model-catalog/"

    public let schema: String
    public let revision: Int64
    public let defaultRuntimeAlias: String
    public let connections: [RuntimeServerModelConnection]

    enum CodingKeys: String, CodingKey {
        case schema, revision, connections
        case defaultRuntimeAlias = "default_runtime_alias"
    }

    /// True when the catalog schema is a supported version (prefix match).
    public var hasSupportedSchema: Bool {
        schema.hasPrefix(Self.supportedSchemaPrefix)
    }

    public init(
        schema: String,
        revision: Int64,
        defaultRuntimeAlias: String,
        connections: [RuntimeServerModelConnection]
    ) {
        self.schema = schema
        self.revision = revision
        self.defaultRuntimeAlias = defaultRuntimeAlias
        self.connections = connections
    }

    public func unifiedModels(
        serverConnectionID: String?
    ) -> [UnifiedModelDescriptor] {
        connections.flatMap { connection in
            connection.models.compactMap { model in
                guard model.available else { return nil }
                let modalities = Set(
                    model.inputModalities.compactMap(ProviderInputModality.init(rawValue:))
                )
                return UnifiedModelDescriptor(
                    serverConnectionID: serverConnectionID,
                    connectionID: connection.id,
                    providerID: connection.providerID,
                    providerDisplayName: connection.displayName,
                    runtimeAlias: model.runtimeAlias,
                    wireModelID: model.wireModelID,
                    displayName: model.displayName,
                    contextWindow: model.contextWindow,
                    supportsTools: model.supportsTools,
                    supportsReasoning: model.supportsReasoning,
                    inputModalities: modalities.isEmpty ? [.text] : modalities,
                    billingSource: connection.billingSource
                )
            }
        }
    }

    public func defaultModelStableID(
        serverConnectionID: String?
    ) -> String? {
        guard !defaultRuntimeAlias.isEmpty,
              connections.contains(where: {
                  $0.models.contains {
                      $0.available && $0.runtimeAlias == defaultRuntimeAlias
                  }
              }) else {
            return nil
        }
        return serverConnectionID.map {
            RuntimeServerModelIdentity(
                serverConnectionID: $0,
                runtimeAlias: defaultRuntimeAlias
            ).stableID
        } ?? defaultRuntimeAlias
    }
}

public struct RuntimeServerModelConnection: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let providerID: String
    public let displayName: String
    public let billingSource: String
    /// v2 addition (optional for interop): per-connection credential subobject,
    /// e.g. `{ "status": "missing", "source": "injected" }` (wire v2 §4).
    public let credential: RuntimeServerConnectionCredential?
    public let models: [RuntimeServerModelDescriptor]

    enum CodingKeys: String, CodingKey {
        case id, models, credential
        case providerID = "provider_id"
        case displayName = "display_name"
        case billingSource = "billing_source"
    }

    public init(
        id: String,
        providerID: String,
        displayName: String,
        billingSource: String,
        credential: RuntimeServerConnectionCredential? = nil,
        models: [RuntimeServerModelDescriptor]
    ) {
        self.id = id
        self.providerID = providerID
        self.displayName = displayName
        self.billingSource = billingSource
        self.credential = credential
        self.models = models
    }
}

/// Per-connection credential state/source (wire v2 §4, non-secret).
public struct RuntimeServerConnectionCredential: Codable, Sendable, Equatable {
    /// "configured" | "missing" | "none"
    public let status: String?
    /// "env" | "injected" | "keychain" | "none"
    public let source: String?

    enum CodingKeys: String, CodingKey {
        case status, source
    }

    public init(status: String? = nil, source: String? = nil) {
        self.status = status
        self.source = source
    }
}

public struct RuntimeServerModelDescriptor: Codable, Sendable, Equatable {
    public let runtimeAlias: String
    public let wireModelID: String
    public let displayName: String
    public let contextWindow: Int?
    public let supportsTools: Bool
    public let supportsReasoning: Bool
    public let inputModalities: [String]
    public let available: Bool
    /// v2 addition (optional for interop): why the model is unavailable, e.g.
    /// "quota exhausted" / "provider error". Present only when available == false.
    public let unavailableReason: String?

    enum CodingKeys: String, CodingKey {
        case available
        case runtimeAlias = "runtime_alias"
        case wireModelID = "wire_model_id"
        case displayName = "display_name"
        case contextWindow = "context_window"
        case supportsTools = "supports_tools"
        case supportsReasoning = "supports_reasoning"
        case inputModalities = "input_modalities"
        case unavailableReason = "unavailable_reason"
    }

    public init(
        runtimeAlias: String,
        wireModelID: String,
        displayName: String,
        contextWindow: Int?,
        supportsTools: Bool,
        supportsReasoning: Bool,
        inputModalities: [String],
        available: Bool,
        unavailableReason: String? = nil
    ) {
        self.runtimeAlias = runtimeAlias
        self.wireModelID = wireModelID
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.supportsTools = supportsTools
        self.supportsReasoning = supportsReasoning
        self.inputModalities = inputModalities
        self.available = available
        self.unavailableReason = unavailableReason
    }
}
