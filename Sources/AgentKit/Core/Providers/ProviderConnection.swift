//
//  ProviderConnection.swift
//  AgentKit
//
//  Provider connection domain model. Secrets deliberately live elsewhere.
//

import Foundation

public enum ProviderTransport: String, Codable, CaseIterable, Sendable {
    /// OpenAI-compatible `/chat/completions`.
    case openAIChatCompletions = "openai_chat_completions"
    /// Ollama native `/api/chat`.
    case ollama
}

public enum ProviderAuthentication: String, Codable, CaseIterable, Sendable {
    /// Talkify-managed account token, resolved through `gateway/default`.
    case gatewayAccount = "gateway_account"
    /// User-managed bearer key, resolved through `llm/<connection-id>`.
    case apiKey = "api_key"
    /// Local or otherwise unauthenticated endpoint.
    case none
}

public enum ProviderModelSource: String, Codable, CaseIterable, Sendable {
    /// Models explicitly stored on the connection.
    case configured
    /// Models returned by the Talkify Gateway catalog.
    case gatewayRemote = "gateway_remote"
}

public enum ProviderInputModality: String, Codable, CaseIterable, Hashable, Sendable {
    case text
    case image
    case audio
}

public struct ProviderModel: Codable, Hashable, Identifiable, Sendable {
    /// Wire model ID sent to the provider.
    public var id: String
    public var displayName: String?
    public var contextWindow: Int?
    public var supportsTools: Bool
    public var supportsReasoning: Bool
    public var inputModalities: Set<ProviderInputModality>
    public var inputPricePerMillion: Double?
    public var outputPricePerMillion: Double?
    public var cacheInputPricePerMillion: Double?

    public init(
        id: String,
        displayName: String? = nil,
        contextWindow: Int? = nil,
        supportsTools: Bool = true,
        supportsReasoning: Bool = false,
        inputModalities: Set<ProviderInputModality> = [.text],
        inputPricePerMillion: Double? = nil,
        outputPricePerMillion: Double? = nil,
        cacheInputPricePerMillion: Double? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.supportsTools = supportsTools
        self.supportsReasoning = supportsReasoning
        self.inputModalities = inputModalities
        self.inputPricePerMillion = inputPricePerMillion
        self.outputPricePerMillion = outputPricePerMillion
        self.cacheInputPricePerMillion = cacheInputPricePerMillion
    }
}

public struct ProviderConnection: Codable, Hashable, Identifiable, Sendable {
    public static let talkifyGatewayID = "talkify-gateway"

    /// Stable connection ID. Multiple connections may share the same providerID.
    public var id: String
    /// Template/category ID such as `deepseek` or `openai-compatible`.
    public var providerID: String
    public var displayName: String
    public var transport: ProviderTransport
    public var authentication: ProviderAuthentication
    public var baseURL: URL
    public var modelSource: ProviderModelSource
    public var models: [ProviderModel]
    public var isEnabled: Bool
    /// Explicit user consent for plain HTTP on a private LAN endpoint.
    /// Loopback HTTP never requires this flag; public HTTP is always rejected.
    public var allowsInsecurePrivateNetworkHTTP: Bool

    public init(
        id: String = UUID().uuidString.lowercased(),
        providerID: String,
        displayName: String,
        transport: ProviderTransport,
        authentication: ProviderAuthentication,
        baseURL: URL,
        modelSource: ProviderModelSource = .configured,
        models: [ProviderModel] = [],
        isEnabled: Bool = true,
        allowsInsecurePrivateNetworkHTTP: Bool = false
    ) {
        self.id = id
        self.providerID = providerID
        self.displayName = displayName
        self.transport = transport
        self.authentication = authentication
        self.baseURL = baseURL
        self.modelSource = modelSource
        self.models = models
        self.isEnabled = isEnabled
        self.allowsInsecurePrivateNetworkHTTP = allowsInsecurePrivateNetworkHTTP
    }

    public var isTalkifyGateway: Bool {
        id == Self.talkifyGatewayID || authentication == .gatewayAccount
    }

    public var credentialTarget: CredentialTarget? {
        switch authentication {
        case .gatewayAccount:
            return .gateway
        case .apiKey:
            return .llm(id)
        case .none:
            return nil
        }
    }

    public static func talkifyGateway(
        baseURL: URL,
        models: [ProviderModel] = [],
        isEnabled: Bool = true
    ) -> ProviderConnection {
        ProviderConnection(
            id: talkifyGatewayID,
            providerID: talkifyGatewayID,
            displayName: "Talkify Gateway",
            transport: .openAIChatCompletions,
            authentication: .gatewayAccount,
            baseURL: baseURL,
            modelSource: .gatewayRemote,
            models: models,
            isEnabled: isEnabled,
            allowsInsecurePrivateNetworkHTTP: false
        )
    }
}

public enum ProviderConnectionValidationError: Error, LocalizedError, Equatable {
    case emptyConnectionID
    case emptyProviderID
    case emptyDisplayName
    case invalidBaseURL
    case duplicateModelID(String)
    case emptyModelID
    case reservedGatewayID
    case gatewayMustUseReservedID

    public var errorDescription: String? {
        switch self {
        case .emptyConnectionID: "Provider connection ID cannot be empty."
        case .emptyProviderID: "Provider ID cannot be empty."
        case .emptyDisplayName: "Provider display name cannot be empty."
        case .invalidBaseURL: "Provider Base URL must use HTTPS, except for loopback endpoints."
        case .duplicateModelID(let id): "Duplicate provider model ID: \(id)"
        case .emptyModelID: "Provider model ID cannot be empty."
        case .reservedGatewayID: "The talkify-gateway ID is reserved for Gateway account connections."
        case .gatewayMustUseReservedID: "Gateway account connections must use the talkify-gateway ID."
        }
    }
}

public extension ProviderConnection {
    func validate() throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderConnectionValidationError.emptyConnectionID
        }
        guard !providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderConnectionValidationError.emptyProviderID
        }
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderConnectionValidationError.emptyDisplayName
        }
        if id == Self.talkifyGatewayID && authentication != .gatewayAccount {
            throw ProviderConnectionValidationError.reservedGatewayID
        }
        if authentication == .gatewayAccount && id != Self.talkifyGatewayID {
            throw ProviderConnectionValidationError.gatewayMustUseReservedID
        }
        guard Self.isAllowedBaseURL(
            baseURL,
            allowsInsecurePrivateNetworkHTTP: allowsInsecurePrivateNetworkHTTP
        ) else {
            throw ProviderConnectionValidationError.invalidBaseURL
        }

        var modelIDs = Set<String>()
        for model in models {
            let modelID = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelID.isEmpty else {
                throw ProviderConnectionValidationError.emptyModelID
            }
            guard modelIDs.insert(modelID).inserted else {
                throw ProviderConnectionValidationError.duplicateModelID(modelID)
            }
        }
    }

    private static func isAllowedBaseURL(
        _ url: URL,
        allowsInsecurePrivateNetworkHTTP: Bool
    ) -> Bool {
        if url.scheme?.lowercased() == "https" {
            return url.host != nil
        }
        guard url.scheme?.lowercased() == "http" else { return false }
        switch url.host?.lowercased() {
        case "localhost", "127.0.0.1", "::1", "0.0.0.0":
            return true
        default:
            return allowsInsecurePrivateNetworkHTTP && isPrivateNetworkHost(url.host)
        }
    }

    private static func isPrivateNetworkHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        if host.hasSuffix(".local") || host.hasPrefix("fc") || host.hasPrefix("fd")
            || host.hasPrefix("fe80:") {
            return true
        }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        if octets[0] == 10 || octets[0] == 127 || octets[0] == 169 && octets[1] == 254 {
            return true
        }
        if octets[0] == 192 && octets[1] == 168 {
            return true
        }
        return octets[0] == 172 && (16...31).contains(octets[1])
    }
}
