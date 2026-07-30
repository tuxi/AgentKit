//
//  RuntimeSharingModels.swift
//  AgentKit
//

import Foundation

public enum RuntimeSharedListenerState: String, Codable, Sendable {
    case stopped
    case starting
    case running
    case failed
}

public struct RuntimeSharedListenerStatus: Codable, Sendable, Equatable {
    public let state: RuntimeSharedListenerState
    public let listenAddress: String?
    /// Diagnostic only. Wildcard hosts must never be advertised.
    public let listenOrigin: String?
    public let port: Int
    public let startedAt: Date?
    public let stoppedAt: Date?
    public let lastTransitionAt: Date?
    public let lastError: String?

    enum CodingKeys: String, CodingKey {
        case state, port
        case listenAddress = "listen_address"
        case listenOrigin = "listen_origin"
        case startedAt = "started_at"
        case stoppedAt = "stopped_at"
        case lastTransitionAt = "last_transition_at"
        case lastError = "last_error"
    }
}

public struct RuntimeSharedDevice: Codable, Identifiable, Sendable, Equatable {
    public var id: String { deviceID }
    public let deviceID: String
    public let credentialSHA256: String
    public var displayName: String
    public var platform: String
    public let pairedAt: Date
    public var revokedAt: Date?

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case credentialSHA256 = "credential_sha256"
        case displayName = "display_name"
        case platform
        case pairedAt = "paired_at"
        case revokedAt = "revoked_at"
    }
}

struct RuntimePendingSharedEnrollment: Codable, Sendable, Equatable {
    let enrollmentID: String
    let deviceID: String
    let credentialSHA256: String
    let deviceName: String?
    let platform: String?
    let createdAt: Date
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case enrollmentID = "enrollment_id"
        case deviceID = "device_id"
        case credentialSHA256 = "credential_sha256"
        case deviceName = "device_name"
        case platform
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }
}

struct RuntimeSharedDeviceValidationRecord: Codable, Sendable {
    let deviceID: String
    let credentialSHA256: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case credentialSHA256 = "credential_sha256"
    }
}

struct RuntimeSharedListenerConfiguration: Codable, Sendable {
    let address: String
    let certificatePEM: String
    let privateKeyPEM: String
    let bootstrapSHA256: String
    let bootstrapExpiresAt: Int64
    let devices: [RuntimeSharedDeviceValidationRecord]
    let enrollmentTimeoutSeconds: Int64

    enum CodingKeys: String, CodingKey {
        case address = "addr"
        case certificatePEM = "certificate_pem"
        case privateKeyPEM = "private_key_pem"
        case bootstrapSHA256 = "bootstrap_sha256"
        case bootstrapExpiresAt = "bootstrap_expires_at"
        case devices
        case enrollmentTimeoutSeconds = "enrollment_timeout_seconds"
    }
}

public struct RuntimePairingInvitation: Codable, Sendable, Equatable {
    public let version: Int
    public let serverID: String
    public let serverDisplayName: String
    public let serviceType: String
    public let serviceName: String
    public let fallbackHost: String
    public let port: Int
    public let bootstrapSecret: String
    public let bootstrapExpiresAt: Date
    public let spkiSHA256: String

    public init(
        version: Int = 1,
        serverID: String,
        serverDisplayName: String,
        serviceType: String,
        serviceName: String,
        fallbackHost: String,
        port: Int,
        bootstrapSecret: String,
        bootstrapExpiresAt: Date,
        spkiSHA256: String
    ) {
        self.version = version
        self.serverID = serverID
        self.serverDisplayName = serverDisplayName
        self.serviceType = serviceType
        self.serviceName = serviceName
        self.fallbackHost = fallbackHost
        self.port = port
        self.bootstrapSecret = bootstrapSecret
        self.bootstrapExpiresAt = bootstrapExpiresAt
        self.spkiSHA256 = spkiSHA256
    }

    public func encodedPayload() throws -> String {
        let data = try JSONEncoder.runtimeSharing.encode(self)
        return data.base64URLEncodedString()
    }

    public static func decode(payload: String) throws -> RuntimePairingInvitation {
        guard let data = Data(base64URLEncoded: payload) else {
            throw RuntimeSharingError.invalidInvitation
        }
        let invitation = try JSONDecoder.runtimeSharing.decode(Self.self, from: data)
        guard invitation.version == 1,
              invitation.port > 0,
              invitation.bootstrapSecret.utf8.count >= 32,
              Data(base64Encoded: invitation.spkiSHA256)?.count == 32 else {
            throw RuntimeSharingError.invalidInvitation
        }
        return invitation
    }
}

public enum RuntimeSharingError: Error, LocalizedError, Equatable {
    case runtimeNotStarted
    case sharedListenerUnavailable
    case invalidInvitation
    case invitationExpired
    case tlsIdentityUnavailable
    case keychainWriteFailed
    case serverIdentityMismatch
    case pairingRejected
    case pairingResponseInvalid

    public var errorDescription: String? {
        switch self {
        case .runtimeNotStarted: "Embedded Runtime is not running."
        case .sharedListenerUnavailable: "Shared Runtime listener is unavailable."
        case .invalidInvitation: "The Runtime pairing invitation is invalid."
        case .invitationExpired: "The Runtime pairing invitation has expired."
        case .tlsIdentityUnavailable: "Unable to create the Runtime sharing TLS identity."
        case .keychainWriteFailed: "Unable to persist Runtime sharing material in Keychain."
        case .serverIdentityMismatch: "The paired Runtime identity does not match the invitation."
        case .pairingRejected: "The Mac rejected or timed out the pairing request."
        case .pairingResponseInvalid: "The Runtime returned an invalid pairing response."
        }
    }
}

extension JSONEncoder {
    static var runtimeSharing: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var runtimeSharing: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let container = try value.singleValueContainer()
            let text = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [
                .withInternetDateTime,
                .withFractionalSeconds,
            ]
            if let date = fractional.date(from: text) {
                return date
            }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            guard let date = standard.date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid RFC3339 timestamp."
                )
            }
            return date
        }
        return decoder
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL value: String) {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        self.init(base64Encoded: base64)
    }

    init?(base64URLEncoded value: String) {
        self.init(base64URL: value)
    }
}
