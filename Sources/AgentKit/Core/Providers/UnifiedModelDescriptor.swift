//
//  UnifiedModelDescriptor.swift
//  AgentKit
//

import Foundation

public struct UnifiedModelDescriptor: Codable, Hashable, Identifiable, Sendable {
    /// Stable App-facing ID, scoped by provider connection.
    public let id: String
    /// Alias used as the key in Code-Agent's `models` map.
    public let runtimeAlias: String
    public let connectionID: String
    public let providerID: String
    public let providerDisplayName: String
    public let wireModelID: String
    public let displayName: String
    public let contextWindow: Int?
    public let supportsTools: Bool
    public let supportsReasoning: Bool
    public let inputModalities: Set<ProviderInputModality>
    public let inputPricePerMillion: Double?
    public let outputPricePerMillion: Double?
    public let cacheInputPricePerMillion: Double?
    public let authentication: ProviderAuthentication

    public init(connection: ProviderConnection, model: ProviderModel) {
        let alias = Self.makeRuntimeAlias(connectionID: connection.id, wireModelID: model.id)
        self.id = alias
        self.runtimeAlias = alias
        self.connectionID = connection.id
        self.providerID = connection.providerID
        self.providerDisplayName = connection.displayName
        self.wireModelID = model.id
        self.displayName = model.displayName ?? model.id
        self.contextWindow = model.contextWindow
        self.supportsTools = model.supportsTools
        self.supportsReasoning = model.supportsReasoning
        self.inputModalities = model.inputModalities
        self.inputPricePerMillion = model.inputPricePerMillion
        self.outputPricePerMillion = model.outputPricePerMillion
        self.cacheInputPricePerMillion = model.cacheInputPricePerMillion
        self.authentication = connection.authentication
    }

    public static func makeRuntimeAlias(connectionID: String, wireModelID: String) -> String {
        "provider.\(encodeAliasComponent(connectionID)).model.\(encodeAliasComponent(wireModelID))"
    }

    /// Decodes the stable App-facing ID without requiring the Provider
    /// connection to still exist. This is used only for historical UI fallback;
    /// Runtime routing must continue to resolve aliases through the live catalog.
    public static func parseRuntimeAlias(
        _ alias: String
    ) -> (connectionID: String, wireModelID: String)? {
        let components = alias.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4,
              components[0] == "provider",
              components[2] == "model",
              let connectionID = decodeAliasComponent(String(components[1])),
              let wireModelID = decodeAliasComponent(String(components[3])),
              !connectionID.isEmpty,
              !wireModelID.isEmpty else {
            return nil
        }
        return (connectionID, wireModelID)
    }

    private static func encodeAliasComponent(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeAliasComponent(_ value: String) -> String? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingCount = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: paddingCount))
        guard let data = Data(base64Encoded: base64),
              let decoded = String(data: data, encoding: .utf8),
              encodeAliasComponent(decoded) == value else {
            return nil
        }
        return decoded
    }
}

public extension Collection where Element == ProviderConnection {
    var unifiedModels: [UnifiedModelDescriptor] {
        flatMap { connection -> [UnifiedModelDescriptor] in
            guard connection.isEnabled else { return [] }
            return connection.models.map { UnifiedModelDescriptor(connection: connection, model: $0) }
        }
    }
}
