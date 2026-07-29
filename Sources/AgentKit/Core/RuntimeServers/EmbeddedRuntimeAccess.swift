//
//  EmbeddedRuntimeAccess.swift
//  AgentKit
//
//  Process-local access credential for the embedded CodeAgent Runtime.
//

import Foundation

/// Read-only transport credential store for the embedded Runtime.
///
/// The token is deliberately excluded from `all()` so it can never enter the
/// Provider `secretsJSON` injection path. It exists only to authenticate HTTP
/// and Agent Wire requests targeting the embedded Runtime listener.
final class EmbeddedRuntimeAccessCredentialStore: CredentialStore, @unchecked Sendable {
    let target = CredentialTarget.runtimeAccess(RuntimeServerConnection.embeddedID)

    private let lock = NSLock()
    private var credential: Credential

    init(token: String = EmbeddedRuntimeAccessToken.generate()) {
        credential = Credential(kind: .bearer, secret: token)
    }

    func resolve(_ target: CredentialTarget) async throws -> Credential? {
        resolveSync(target)
    }

    func resolveSync(_ target: CredentialTarget) -> Credential? {
        guard target == self.target else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return credential
    }

    /// Runtime access credentials are never Provider credentials.
    func all() async throws -> CredentialMap {
        CredentialMap()
    }

    func set(_ credential: Credential, for target: CredentialTarget) async throws {}
    func remove(_ target: CredentialTarget) async throws {}
    func clear() async throws {}

    var token: String {
        lock.lock()
        defer { lock.unlock() }
        return credential.secret
    }

    /// Rotates before every actual embedded Runtime launch. Existing clients
    /// retain this resolver and therefore pick up the new token on their next
    /// HTTP request or Agent Wire reconnect.
    @discardableResult
    func rotate() -> String {
        let token = EmbeddedRuntimeAccessToken.generate()
        lock.lock()
        credential = Credential(kind: .bearer, secret: token)
        lock.unlock()
        return token
    }
}

enum EmbeddedRuntimeAccessToken {
    static let byteCount = 32

    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        }
        return Data(bytes).base64EncodedString()
    }
}
