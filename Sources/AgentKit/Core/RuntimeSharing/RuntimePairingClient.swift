//
//  RuntimePairingClient.swift
//  AgentKit
//

import Foundation

struct RuntimePairingResult: Sendable {
    let enrollmentID: String
    let deviceID: String
    let credential: String
}

private struct RuntimePairingRequest: Encodable {
    let bootstrapSecret: String
    let deviceName: String
    let platform: String

    enum CodingKeys: String, CodingKey {
        case bootstrapSecret = "bootstrap_secret"
        case deviceName = "device_name"
        case platform
    }
}

private struct RuntimePairingResponse: Decodable {
    let enrollmentID: String
    let deviceID: String
    let credential: String

    enum CodingKeys: String, CodingKey {
        case enrollmentID = "enrollment_id"
        case deviceID = "device_id"
        case credential
    }
}

private struct RuntimePairingEnvelope<T: Decodable>: Decodable {
    let code: Int
    let msg: String
    let data: T?
}

private final class RuntimePairingSessionDelegate:
    NSObject,
    URLSessionDelegate,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let trustPolicy: RuntimeServerTrustPolicy

    init(trustPolicy: RuntimeServerTrustPolicy) {
        self.trustPolicy = trustPolicy
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        let result = RuntimeTLSSecurity.evaluate(
            challenge: challenge,
            policy: trustPolicy
        )
        completionHandler(result.0, result.1)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct RuntimePairingClient: Sendable {
    func pair(
        invitation: RuntimePairingInvitation,
        endpoint: URL,
        deviceName: String,
        platform: RuntimeServerClientPlatform
    ) async throws -> RuntimePairingResult {
        guard invitation.version == 1 else {
            throw RuntimeSharingError.invalidInvitation
        }
        guard invitation.bootstrapExpiresAt > Date() else {
            throw RuntimeSharingError.invitationExpired
        }
        guard endpoint.scheme?.lowercased() == "https",
              let host = endpoint.host,
              endpoint.port != nil else {
            throw RuntimeSharingError.invalidInvitation
        }
        let trustPolicy = RuntimeServerTrustPolicy(
            expectedHost: host,
            spkiSHA256: invitation.spkiSHA256
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 90
        let session = URLSession(
            configuration: configuration,
            delegate: RuntimePairingSessionDelegate(trustPolicy: trustPolicy),
            delegateQueue: nil
        )
        var request = URLRequest(
            url: endpoint
                .appendingPathComponent("v1")
                .appendingPathComponent("runtime")
                .appendingPathComponent("pair")
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RuntimePairingRequest(
            bootstrapSecret: invitation.bootstrapSecret,
            deviceName: String(deviceName.prefix(128)),
            platform: platform.rawValue
        ))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let envelope = try? JSONDecoder().decode(
                  RuntimePairingEnvelope<RuntimePairingResponse>.self,
                  from: data
              ),
              envelope.code == 0,
              let payload = envelope.data,
              payload.credential.utf8.count >= 32,
              !payload.deviceID.isEmpty else {
            throw RuntimeSharingError.pairingRejected
        }
        return RuntimePairingResult(
            enrollmentID: payload.enrollmentID,
            deviceID: payload.deviceID,
            credential: payload.credential
        )
    }
}
