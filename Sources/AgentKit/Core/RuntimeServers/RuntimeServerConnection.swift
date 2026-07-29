//
//  RuntimeServerConnection.swift
//  AgentKit
//
//  Secret-free identity and persistence model for CodeAgent Runtime servers.
//

import Foundation

public enum RuntimeServerKind: String, Codable, Sendable, CaseIterable {
    case embedded
    case local
    case remote
}

public enum RuntimeServerAuthentication: String, Codable, Sendable, CaseIterable {
    case none
    case bearer
}

public enum RuntimeServerClientPlatform: String, Codable, Sendable {
    case iOS
    case macOS

    public static var current: RuntimeServerClientPlatform {
        #if os(iOS)
        .iOS
        #else
        .macOS
        #endif
    }
}

public struct RuntimeServerConnection: Codable, Identifiable, Sendable, Equatable {
    public static let embeddedID = "talkify-embedded-runtime"

    public let id: String
    public var displayName: String
    public let kind: RuntimeServerKind
    /// External Runtime HTTP(S) origin. Embedded Runtime ports are dynamic and
    /// are deliberately never persisted here.
    public var endpoint: URL?
    public var authentication: RuntimeServerAuthentication
    /// Runtime-owned identity returned by `/v1/runtime/info`.
    public var serverID: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        displayName: String,
        kind: RuntimeServerKind,
        endpoint: URL?,
        authentication: RuntimeServerAuthentication,
        serverID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) throws {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.endpoint = endpoint
        self.authentication = authentication
        self.serverID = serverID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        try validate()
    }

    public static func embedded(
        displayName: String = "Talkify Embedded Runtime",
        now: Date = Date()
    ) -> RuntimeServerConnection {
        // The reserved embedded record is constructed from constants and cannot
        // fail validation.
        try! RuntimeServerConnection(
            id: embeddedID,
            displayName: displayName,
            kind: .embedded,
            endpoint: nil,
            authentication: .bearer,
            createdAt: now,
            updatedAt: now
        )
    }

    public static func external(
        id: String,
        displayName: String,
        endpoint: URL,
        authentication: RuntimeServerAuthentication,
        platform: RuntimeServerClientPlatform = .current,
        serverID: String? = nil,
        now: Date = Date()
    ) throws -> RuntimeServerConnection {
        let kind = try RuntimeServerEndpointClassifier.kind(
            for: endpoint,
            platform: platform
        )
        return try RuntimeServerConnection(
            id: id,
            displayName: displayName,
            kind: kind,
            endpoint: endpoint,
            authentication: authentication,
            serverID: serverID,
            createdAt: now,
            updatedAt: now
        )
    }

    public var credentialTarget: CredentialTarget {
        .runtimeAccess(id)
    }

    public func validate() throws {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw RuntimeServerRegistryError.invalidConnectionID
        }
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeServerRegistryError.invalidDisplayName
        }

        if kind == .embedded {
            guard id == Self.embeddedID,
                  endpoint == nil,
                  authentication == .bearer else {
                throw RuntimeServerRegistryError.invalidEmbeddedConnection
            }
            return
        }

        guard id != Self.embeddedID, let endpoint else {
            throw RuntimeServerRegistryError.invalidExternalEndpoint
        }
        try RuntimeServerEndpointClassifier.validateOrigin(endpoint)
    }
}

public struct RuntimeConversationIdentity: Codable, Hashable, Sendable {
    public let serverConnectionID: String
    public let conversationID: String

    public init(serverConnectionID: String, conversationID: String) {
        self.serverConnectionID = serverConnectionID
        self.conversationID = conversationID
    }
}

public struct RuntimeServerProtocolVersion: Codable, Sendable, Equatable {
    public let major: Int
    public let revision: String

    public init(major: Int, revision: String) {
        self.major = major
        self.revision = revision
    }
}

public struct RuntimeServerInfo: Codable, Sendable, Equatable {
    public let schema: String
    public let serverID: String
    public let displayName: String
    public let product: String
    public let runtimeVersion: String
    public let agentWireProtocol: RuntimeServerProtocolVersion
    public let runtimeProfile: String

    enum CodingKeys: String, CodingKey {
        case schema, product
        case serverID = "server_id"
        case displayName = "display_name"
        case runtimeVersion = "runtime_version"
        case agentWireProtocol = "agent_wire_protocol"
        case runtimeProfile = "runtime_profile"
    }

    public init(
        schema: String,
        serverID: String,
        displayName: String,
        product: String,
        runtimeVersion: String,
        agentWireProtocol: RuntimeServerProtocolVersion,
        runtimeProfile: String
    ) {
        self.schema = schema
        self.serverID = serverID
        self.displayName = displayName
        self.product = product
        self.runtimeVersion = runtimeVersion
        self.agentWireProtocol = agentWireProtocol
        self.runtimeProfile = runtimeProfile
    }

    public var isAgentWireV1Compatible: Bool {
        schema == "runtime-info/v1"
            && product == "codeagent"
            && agentWireProtocol.major == 1
    }
}

public enum RuntimeServerEndpointClassifier {
    public static func kind(
        for endpoint: URL,
        platform: RuntimeServerClientPlatform
    ) throws -> RuntimeServerKind {
        try validateOrigin(endpoint)
        if isLoopback(endpoint) {
            guard platform == .macOS else {
                throw RuntimeServerRegistryError.loopbackUnavailableOnIOS
            }
            return .local
        }
        return .remote
    }

    public static func validateOrigin(_ endpoint: URL) throws {
        guard let components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        ), let scheme = components.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           components.host?.isEmpty == false,
           components.user == nil,
           components.password == nil,
           components.query == nil,
           components.fragment == nil,
           components.path.isEmpty || components.path == "/"
        else {
            throw RuntimeServerRegistryError.invalidExternalEndpoint
        }
    }

    public static func isLoopback(_ endpoint: URL) -> Bool {
        guard var host = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        )?.host?.lowercased() else {
            return false
        }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        if host == "localhost" || host == "::1" {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.first == "127"
    }
}

public enum RuntimeServerRegistryError: Error, LocalizedError, Equatable {
    case invalidConnectionID
    case invalidDisplayName
    case invalidEmbeddedConnection
    case invalidExternalEndpoint
    case loopbackUnavailableOnIOS
    case duplicateConnectionID(String)
    case connectionNotFound(String)
    case cannotRemoveEmbedded
    case cannotRemoveActive

    public var errorDescription: String? {
        switch self {
        case .invalidConnectionID:
            "Runtime Server Connection ID is required."
        case .invalidDisplayName:
            "Runtime Server display name is required."
        case .invalidEmbeddedConnection:
            "The embedded Runtime Server record is invalid."
        case .invalidExternalEndpoint:
            "Runtime Server URL must be an HTTP(S) origin without credentials, query, or path."
        case .loopbackUnavailableOnIOS:
            "localhost refers to this iPhone. Use the Mac's LAN, VPN, or domain address."
        case .duplicateConnectionID(let id):
            "Duplicate Runtime Server Connection ID: \(id)"
        case .connectionNotFound(let id):
            "Runtime Server Connection was not found: \(id)"
        case .cannotRemoveEmbedded:
            "The embedded Runtime Server cannot be removed."
        case .cannotRemoveActive:
            "Select another Runtime Server before removing the active one."
        }
    }
}
