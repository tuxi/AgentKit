//
//  CompositeCredentialStore.swift
//  AgentKit
//
//  Routes credential namespaces to independently owned stores.
//

import Foundation

public enum CompositeCredentialStoreError: Error, LocalizedError {
    case noStoreForNamespace(String)

    public var errorDescription: String? {
        switch self {
        case .noStoreForNamespace(let namespace):
            "No credential store is registered for namespace \(namespace)."
        }
    }
}

public final class CompositeCredentialStore: CredentialStore, @unchecked Sendable {
    private let storesByNamespace: [String: any CredentialStore]
    private let fallbackStore: (any CredentialStore)?

    public init(
        storesByNamespace: [String: any CredentialStore],
        fallbackStore: (any CredentialStore)? = nil
    ) {
        self.storesByNamespace = storesByNamespace
        self.fallbackStore = fallbackStore
    }

    public func resolve(_ target: CredentialTarget) async throws -> Credential? {
        guard let store = store(for: target) else { return nil }
        return try await store.resolve(target)
    }

    public func resolveSync(_ target: CredentialTarget) -> Credential? {
        store(for: target)?.resolveSync(target)
    }

    public func all() async throws -> CredentialMap {
        var merged = CredentialMap()
        for store in uniqueStores {
            let map = try await store.all()
            for (target, credential) in map.entries {
                merged[target] = credential
            }
        }
        return merged
    }

    public func set(_ credential: Credential, for target: CredentialTarget) async throws {
        guard let store = store(for: target) else {
            throw CompositeCredentialStoreError.noStoreForNamespace(target.namespace)
        }
        try await store.set(credential, for: target)
    }

    public func remove(_ target: CredentialTarget) async throws {
        guard let store = store(for: target) else {
            throw CompositeCredentialStoreError.noStoreForNamespace(target.namespace)
        }
        try await store.remove(target)
    }

    public func clear() async throws {
        for store in uniqueStores {
            try await store.clear()
        }
    }

    private func store(for target: CredentialTarget) -> (any CredentialStore)? {
        storesByNamespace[target.namespace] ?? fallbackStore
    }

    private var uniqueStores: [any CredentialStore] {
        var seen = Set<ObjectIdentifier>()
        var result: [any CredentialStore] = []
        for store in Array(storesByNamespace.values) + [fallbackStore].compactMap({ $0 }) {
            let identifier = ObjectIdentifier(store as AnyObject)
            if seen.insert(identifier).inserted {
                result.append(store)
            }
        }
        return result
    }
}
