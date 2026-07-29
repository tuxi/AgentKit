//
//  ProviderConnectionRegistry.swift
//  AgentKit
//
//  Persistent, secret-free provider connection registry.
//

import Foundation

@MainActor
@Observable
public final class ProviderConnectionRegistry {
    public static let defaultStorageKey = "agentkit.provider_connections.v1"

    public private(set) var connections: [ProviderConnection]

    private let defaults: UserDefaults
    private let storageKey: String

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = ProviderConnectionRegistry.defaultStorageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([ProviderConnection].self, from: data) {
            self.connections = saved
        } else {
            self.connections = []
        }
    }

    public var enabledConnections: [ProviderConnection] {
        connections.filter(\.isEnabled)
    }

    public var models: [UnifiedModelDescriptor] {
        enabledConnections.unifiedModels
    }

    public var isEmpty: Bool { connections.isEmpty }

    public func connection(id: String) -> ProviderConnection? {
        connections.first { $0.id == id }
    }

    public func model(id: String) -> UnifiedModelDescriptor? {
        models.first { $0.id == id }
    }

    public func model(runtimeAlias: String) -> UnifiedModelDescriptor? {
        models.first { $0.runtimeAlias == runtimeAlias }
    }

    public func upsert(_ connection: ProviderConnection) throws {
        try connection.validate()
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
        } else {
            connections.append(connection)
        }
        persist()
    }

    @discardableResult
    public func remove(connectionID: String) -> ProviderConnection? {
        guard let index = connections.firstIndex(where: { $0.id == connectionID }) else {
            return nil
        }
        let removed = connections.remove(at: index)
        persist()
        return removed
    }

    public func setEnabled(_ enabled: Bool, connectionID: String) {
        guard let index = connections.firstIndex(where: { $0.id == connectionID }) else {
            return
        }
        connections[index].isEnabled = enabled
        persist()
    }

    public func replaceModels(_ models: [ProviderModel], connectionID: String) throws {
        guard let index = connections.firstIndex(where: { $0.id == connectionID }) else {
            return
        }
        var updated = connections[index]
        updated.models = models
        try updated.validate()
        connections[index] = updated
        persist()
    }

    public func replaceAll(_ newConnections: [ProviderConnection]) throws {
        var seen = Set<String>()
        for connection in newConnections {
            try connection.validate()
            guard seen.insert(connection.id).inserted else {
                throw ProviderRegistryError.duplicateConnectionID(connection.id)
            }
        }
        connections = newConnections
        persist()
    }

    public func reset() {
        connections = []
        defaults.removeObject(forKey: storageKey)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

public enum ProviderRegistryError: Error, LocalizedError, Equatable {
    case duplicateConnectionID(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateConnectionID(let id):
            "Duplicate provider connection ID: \(id)"
        }
    }
}
