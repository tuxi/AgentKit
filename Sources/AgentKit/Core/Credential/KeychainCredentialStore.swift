//
//  KeychainCredentialStore.swift
//  AgentKit
//
//  Production CredentialStore. Provider configuration never contains secrets.
//

import Foundation

public enum KeychainCredentialStoreError: Error, LocalizedError {
    case encodeFailed
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .encodeFailed: "Unable to encode credential for Keychain."
        case .writeFailed: "Unable to write credential to Keychain."
        }
    }
}

public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    private let keychain: KeychainStore

    public init(service: String = "com.agentkit.provider-credentials") {
        self.keychain = KeychainStore(service: service)
    }

    public func resolve(_ target: CredentialTarget) async throws -> Credential? {
        resolveSync(target)
    }

    public func resolveSync(_ target: CredentialTarget) -> Credential? {
        guard let encoded = keychain.string(for: target.id),
              let data = encoded.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(Credential.self, from: data)
    }

    public func all() async throws -> CredentialMap {
        var map = CredentialMap()
        for account in keychain.accounts() {
            guard let target = CredentialTarget(id: account),
                  let credential = resolveSync(target) else {
                continue
            }
            map[target] = credential
        }
        return map
    }

    public func set(_ credential: Credential, for target: CredentialTarget) async throws {
        guard let data = try? JSONEncoder().encode(credential),
              let encoded = String(data: data, encoding: .utf8) else {
            throw KeychainCredentialStoreError.encodeFailed
        }
        guard keychain.set(encoded, for: target.id) else {
            throw KeychainCredentialStoreError.writeFailed
        }
    }

    public func remove(_ target: CredentialTarget) async throws {
        guard keychain.remove(target.id) else {
            throw KeychainCredentialStoreError.writeFailed
        }
    }

    public func clear() async throws {
        guard keychain.removeAll() else {
            throw KeychainCredentialStoreError.writeFailed
        }
    }
}
