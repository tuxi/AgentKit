//
//  RuntimeServerRegistry.swift
//  AgentKit
//

import Foundation

@MainActor
@Observable
public final class RuntimeServerRegistry {
    public static let defaultStorageKey = "agentkit.runtime_servers.v1"
    public static let defaultActiveStorageKey = "agentkit.runtime_servers.active.v1"

    public private(set) var connections: [RuntimeServerConnection]
    public private(set) var activeConnectionID: String

    private let defaults: UserDefaults
    private let storageKey: String
    private let activeStorageKey: String

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = RuntimeServerRegistry.defaultStorageKey,
        activeStorageKey: String = RuntimeServerRegistry.defaultActiveStorageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.activeStorageKey = activeStorageKey

        let decoded = defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([RuntimeServerConnection].self, from: $0) }
            ?? []
        var restored = decoded.filter { connection in
            (try? connection.validate()) != nil
        }
#if canImport(CodeAgentRuntime)
        if let index = restored.firstIndex(where: { $0.id == RuntimeServerConnection.embeddedID }) {
            restored[index] = .embedded(
                displayName: restored[index].displayName,
                now: restored[index].createdAt
            )
        } else {
            restored.insert(.embedded(), at: 0)
        }
#else
        restored.removeAll {
            $0.id == RuntimeServerConnection.embeddedID
        }
#endif
        self.connections = restored

        let requestedActive = defaults.string(forKey: activeStorageKey)
        self.activeConnectionID = restored.contains(where: { $0.id == requestedActive })
            ? requestedActive!
            : RuntimeServerConnection.embeddedID
        persist()
    }

    public var activeConnection: RuntimeServerConnection {
        connections.first { $0.id == activeConnectionID } ?? .embedded()
    }

    public func connection(id: String) -> RuntimeServerConnection? {
        connections.first { $0.id == id }
    }

    public func upsert(_ connection: RuntimeServerConnection) throws {
        try connection.validate()
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            if connection.id == RuntimeServerConnection.embeddedID {
                connections[index].displayName = connection.displayName
                connections[index].updatedAt = connection.updatedAt
            } else {
                connections[index] = connection
            }
        } else {
            connections.append(connection)
        }
        persist()
    }

    @discardableResult
    public func setActive(connectionID: String) throws -> RuntimeServerConnection {
        guard let connection = connection(id: connectionID) else {
            throw RuntimeServerRegistryError.connectionNotFound(connectionID)
        }
        activeConnectionID = connectionID
        persist()
        return connection
    }

    @discardableResult
    public func remove(connectionID: String) throws -> RuntimeServerConnection {
        guard connectionID != RuntimeServerConnection.embeddedID else {
            throw RuntimeServerRegistryError.cannotRemoveEmbedded
        }
        guard connectionID != activeConnectionID else {
            throw RuntimeServerRegistryError.cannotRemoveActive
        }
        guard let index = connections.firstIndex(where: { $0.id == connectionID }) else {
            throw RuntimeServerRegistryError.connectionNotFound(connectionID)
        }
        let removed = connections.remove(at: index)
        persist()
        return removed
    }

    public func replaceAll(_ newConnections: [RuntimeServerConnection]) throws {
        var seen = Set<String>()
        for connection in newConnections {
            try connection.validate()
            guard seen.insert(connection.id).inserted else {
                throw RuntimeServerRegistryError.duplicateConnectionID(connection.id)
            }
        }
        guard newConnections.contains(where: { $0.id == RuntimeServerConnection.embeddedID }) else {
            throw RuntimeServerRegistryError.invalidEmbeddedConnection
        }
        connections = newConnections
        if !connections.contains(where: { $0.id == activeConnectionID }) {
            activeConnectionID = RuntimeServerConnection.embeddedID
        }
        persist()
    }

    public func resetToEmbedded() {
        connections = [.embedded()]
        activeConnectionID = RuntimeServerConnection.embeddedID
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(connections) {
            defaults.set(data, forKey: storageKey)
        }
        defaults.set(activeConnectionID, forKey: activeStorageKey)
    }
}
