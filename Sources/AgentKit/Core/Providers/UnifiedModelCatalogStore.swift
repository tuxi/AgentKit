//
//  UnifiedModelCatalogStore.swift
//  AgentKit
//

import Foundation

@MainActor
@Observable
public final class UnifiedModelCatalogStore {
    public static let defaultModelStorageKey = "agentkit.provider_models.default.v1"

    public private(set) var models: [UnifiedModelDescriptor] = []
    public private(set) var defaultModelID: String?

    private let defaults: UserDefaults
    private let defaultModelStorageKey: String

    public init(
        defaults: UserDefaults = .standard,
        defaultModelStorageKey: String = UnifiedModelCatalogStore.defaultModelStorageKey
    ) {
        self.defaults = defaults
        self.defaultModelStorageKey = defaultModelStorageKey
        self.defaultModelID = defaults.string(forKey: defaultModelStorageKey)
    }

    public func reload(from connections: [ProviderConnection]) {
        models = connections.unifiedModels
        if let defaultModelID, !models.contains(where: { $0.id == defaultModelID }) {
            self.defaultModelID = nil
            defaults.removeObject(forKey: defaultModelStorageKey)
        }
    }

    public func reload(from registry: ProviderConnectionRegistry) {
        reload(from: registry.enabledConnections)
    }

    public func descriptor(id: String) -> UnifiedModelDescriptor? {
        models.first { $0.id == id }
    }

    public func descriptor(runtimeAlias: String) -> UnifiedModelDescriptor? {
        models.first { $0.runtimeAlias == runtimeAlias }
    }

    public func models(connectionID: String) -> [UnifiedModelDescriptor] {
        models.filter { $0.connectionID == connectionID }
    }

    public func setDefaultModel(id: String?) {
        guard let id else {
            defaultModelID = nil
            defaults.removeObject(forKey: defaultModelStorageKey)
            return
        }
        guard models.contains(where: { $0.id == id }) else { return }
        defaultModelID = id
        defaults.set(id, forKey: defaultModelStorageKey)
    }

    public var resolvedDefaultModel: UnifiedModelDescriptor? {
        if let defaultModelID, let selected = descriptor(id: defaultModelID) {
            return selected
        }
        return models.first
    }
}
