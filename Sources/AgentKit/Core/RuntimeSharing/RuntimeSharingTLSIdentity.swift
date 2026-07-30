//
//  RuntimeSharingTLSIdentity.swift
//  AgentKit
//
//  Generates and persists a self-signed P-256 identity. Clients never use
//  ambient trust for this certificate; the invitation pins its SPKI digest.
//

import CryptoKit
import Foundation
import Security

struct RuntimeSharingTLSIdentity: Codable, Sendable {
    let certificatePEM: String
    let privateKeyPEM: String
    let spkiSHA256: String
    let createdAt: Date
}

struct RuntimeSharingTLSIdentityStore: Sendable {
    private let keychain: KeychainStore
    private let account = "tls-identity/v1"

    init(
        keychain: KeychainStore = KeychainStore(
            service: "com.agentkit.runtime-sharing"
        )
    ) {
        self.keychain = keychain
    }

    func loadOrCreate(commonName: String) throws -> RuntimeSharingTLSIdentity {
        if let encoded = keychain.string(for: account),
           let data = encoded.data(using: .utf8),
           let identity = try? JSONDecoder.runtimeSharing.decode(
               RuntimeSharingTLSIdentity.self,
               from: data
           ) {
            return identity
        }
        let identity = try Self.generate(commonName: commonName)
        guard let data = try? JSONEncoder.runtimeSharing.encode(identity),
              let encoded = String(data: data, encoding: .utf8),
              keychain.set(encoded, for: account) else {
            throw RuntimeSharingError.keychainWriteFailed
        }
        return identity
    }

    static func generate(commonName: String) throws -> RuntimeSharingTLSIdentity {
        let privateKey = P256.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.x963Representation
        let signatureAlgorithm = RuntimeASN1.sequence(
            RuntimeASN1.objectIdentifier([1, 2, 840, 10045, 4, 3, 2])
        )
        let name = RuntimeASN1.sequence(
            RuntimeASN1.set(
                RuntimeASN1.sequence(
                    RuntimeASN1.objectIdentifier([2, 5, 4, 3]),
                    RuntimeASN1.utf8String(
                        String(commonName.prefix(64))
                    )
                )
            )
        )
        var serial = Data(count: 16)
        guard serial.withUnsafeMutableBytes({
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }) == errSecSuccess else {
            throw RuntimeSharingError.tlsIdentityUnavailable
        }
        let now = Date()
        let subjectPublicKeyInfo = RuntimeASN1.sequence(
            RuntimeASN1.sequence(
                RuntimeASN1.objectIdentifier([1, 2, 840, 10045, 2, 1]),
                RuntimeASN1.objectIdentifier([1, 2, 840, 10045, 3, 1, 7])
            ),
            RuntimeASN1.bitString(publicKey)
        )
        let tbsCertificate = RuntimeASN1.sequence(
            RuntimeASN1.context(
                0,
                value: RuntimeASN1.integer(Data([2]))
            ),
            RuntimeASN1.integer(serial),
            signatureAlgorithm,
            name,
            RuntimeASN1.sequence(
                RuntimeASN1.utcTime(now.addingTimeInterval(-300)),
                RuntimeASN1.utcTime(
                    now.addingTimeInterval(60 * 60 * 24 * 365 * 10)
                )
            ),
            name,
            subjectPublicKeyInfo
        )
        let signature = try privateKey.signature(for: tbsCertificate)
        let certificateDER = RuntimeASN1.sequence(
            tbsCertificate,
            signatureAlgorithm,
            RuntimeASN1.bitString(signature.derRepresentation)
        )
        let privateKeyDER = RuntimeASN1.sequence(
            RuntimeASN1.integer(Data([1])),
            RuntimeASN1.octetString(privateKey.rawRepresentation),
            RuntimeASN1.context(
                0,
                value: RuntimeASN1.objectIdentifier(
                    [1, 2, 840, 10045, 3, 1, 7]
                )
            ),
            RuntimeASN1.context(
                1,
                value: RuntimeASN1.bitString(publicKey)
            )
        )
        let spkiSHA256 = Data(
            SHA256.hash(data: subjectPublicKeyInfo)
        ).base64EncodedString()
        return RuntimeSharingTLSIdentity(
            certificatePEM: pem(
                label: "CERTIFICATE",
                der: certificateDER
            ),
            privateKeyPEM: pem(
                label: "EC PRIVATE KEY",
                der: privateKeyDER
            ),
            spkiSHA256: spkiSHA256,
            createdAt: now
        )
    }

    private static func pem(label: String, der: Data) -> String {
        let encoded = der.base64EncodedString(
            options: [.lineLength64Characters]
        )
        return "-----BEGIN \(label)-----\n\(encoded)\n-----END \(label)-----\n"
    }
}
