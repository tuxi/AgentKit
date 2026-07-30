//
//  RuntimeTLSSecurity.swift
//  AgentKit
//
//  TLS trust policy used by paired Runtime Servers. A pairing invitation pins
//  the P-256 SubjectPublicKeyInfo digest, so a self-signed LAN certificate does
//  not require installing a root CA on the client device.
//

import CryptoKit
import Foundation
import Security

public struct RuntimeServerTrustPolicy: Codable, Sendable, Equatable {
    public let expectedHost: String
    /// Base64-encoded SHA-256 digest of the leaf certificate SPKI.
    public let spkiSHA256: String

    public init(expectedHost: String, spkiSHA256: String) {
        self.expectedHost = expectedHost.lowercased()
        self.spkiSHA256 = spkiSHA256
    }
}

enum RuntimeTLSSecurity {
    static func evaluate(
        challenge: URLAuthenticationChallenge,
        policy: RuntimeServerTrustPolicy?
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        guard let policy else {
            return (.performDefaultHandling, nil)
        }
        guard challenge.protectionSpace.host.lowercased() == policy.expectedHost,
              let actual = spkiSHA256Base64(from: trust),
              constantTimeEqual(actual, policy.spkiSHA256) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    static func spkiSHA256Base64(from trust: SecTrust) -> String? {
        guard let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = certificates.first,
              let key = SecCertificateCopyKey(certificate),
              let external = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              external.count == 65,
              external.first == 0x04 else {
            return nil
        }
        let spki = RuntimeASN1.sequence(
            RuntimeASN1.sequence(
                RuntimeASN1.objectIdentifier([1, 2, 840, 10045, 2, 1]),
                RuntimeASN1.objectIdentifier([1, 2, 840, 10045, 3, 1, 7])
            ),
            RuntimeASN1.bitString(external)
        )
        return Data(SHA256.hash(data: spki)).base64EncodedString()
    }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices {
            difference |= a[index] ^ b[index]
        }
        return difference == 0
    }
}

enum RuntimeASN1 {
    static func sequence(_ values: Data...) -> Data {
        tagged(0x30, values.reduce(into: Data()) { $0.append($1) })
    }

    static func set(_ values: Data...) -> Data {
        tagged(0x31, values.reduce(into: Data()) { $0.append($1) })
    }

    static func integer(_ bytes: Data) -> Data {
        var value = bytes
        while value.count > 1, value.first == 0, value[value.index(after: value.startIndex)] < 0x80 {
            value.removeFirst()
        }
        if value.first.map({ $0 >= 0x80 }) == true {
            value.insert(0, at: 0)
        }
        return tagged(0x02, value)
    }

    static func octetString(_ value: Data) -> Data {
        tagged(0x04, value)
    }

    static func bitString(_ value: Data) -> Data {
        tagged(0x03, Data([0]) + value)
    }

    static func utf8String(_ value: String) -> Data {
        tagged(0x0C, Data(value.utf8))
    }

    static func utcTime(_ value: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tagged(0x17, Data(formatter.string(from: value).utf8))
    }

    static func objectIdentifier(_ components: [UInt64]) -> Data {
        precondition(components.count >= 2)
        var body = Data([UInt8(components[0] * 40 + components[1])])
        for value in components.dropFirst(2) {
            var encoded = [UInt8(value & 0x7F)]
            var remaining = value >> 7
            while remaining > 0 {
                encoded.insert(UInt8(remaining & 0x7F) | 0x80, at: 0)
                remaining >>= 7
            }
            body.append(contentsOf: encoded)
        }
        return tagged(0x06, body)
    }

    static func context(_ number: UInt8, value: Data) -> Data {
        tagged(0xA0 | number, value)
    }

    static func tagged(_ tag: UInt8, _ body: Data) -> Data {
        Data([tag]) + length(body.count) + body
    }

    private static func length(_ count: Int) -> Data {
        if count < 0x80 {
            return Data([UInt8(count)])
        }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}
