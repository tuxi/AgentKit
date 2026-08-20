//
//  RuntimeSharingDaemonClient.swift
//  AgentKit
//

import Foundation

/// Client for the daemon's localhost Runtime Sharing management API.
///
/// This client never owns the shared listener. The daemon remains the source
/// of truth for its TLS identity, paired-device registry, Bonjour publisher,
/// bootstrap state and listener lifecycle.
public struct RuntimeSharingDaemonClient: RuntimeSharingBackend, Sendable {
    public static let defaultEndpoint = URL(
        string: "http://127.0.0.1:8797"
    )!

    private let endpoint: URL
    private let managementToken: String?
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(
        endpoint: URL = RuntimeSharingDaemonClient.defaultEndpoint,
        managementToken: String? = nil,
        trustPolicy: RuntimeServerTrustPolicy? = nil
    ) {
        self.endpoint = endpoint
        self.managementToken = managementToken
        self.session = URLSession(
            configuration: .ephemeral,
            delegate: RuntimeSharingDaemonSessionDelegate(
                trustPolicy: trustPolicy
            ),
            delegateQueue: nil
        )
        self.decoder = JSONDecoder.runtimeSharing
    }

    /// Test seam for URLProtocol-backed daemon API tests.
    init(
        endpoint: URL,
        managementToken: String? = nil,
        session: URLSession
    ) {
        self.endpoint = endpoint
        self.managementToken = managementToken
        self.session = session
        self.decoder = JSONDecoder.runtimeSharing
    }

    public func startSharing(
        displayName: String? = nil,
        listenAddress: String? = nil
    ) async throws -> RuntimeSharedListenerStatus {
        try await request(
            method: "POST",
            path: ["v1", "runtime", "sharing", "start"],
            body: RuntimeSharingStartRequest(
                displayName: displayName,
                listenAddress: listenAddress
            ),
            response: RuntimeSharedListenerStatus.self
        )
    }

    public func stopSharing() async throws {
        try await requestVoid(
            method: "POST",
            path: ["v1", "runtime", "sharing", "stop"]
        )
    }

    public func refreshStatus() async throws -> RuntimeSharedListenerStatus {
        try await request(
            method: "GET",
            path: ["v1", "runtime", "sharing", "status"],
            response: RuntimeSharedListenerStatus.self
        )
    }

    public func createPairingInvitation(
        validity: TimeInterval = 120
    ) async throws -> RuntimePairingInvitation {
        try await request(
            method: "POST",
            path: ["v1", "runtime", "sharing", "invitations"],
            body: RuntimeSharingInvitationRequest(validity: validity),
            response: RuntimePairingInvitation.self
        )
    }

    public func listDevices() async throws -> [RuntimeSharedDevice] {
        try await request(
            method: "GET",
            path: ["v1", "runtime", "sharing", "devices"],
            response: RuntimeSharingDevicesPayload.self
        ).devices ?? []
    }

    public func revokeDevice(_ deviceID: String) async throws {
        try await requestVoid(
            method: "DELETE",
            path: ["v1", "runtime", "sharing", "devices", deviceID]
        )
    }

    private func request<T: Decodable>(
        method: String,
        path: [String],
        body: (any Encodable)? = nil,
        response: T.Type
    ) async throws -> T {
        let (data, http) = try await perform(
            method: method,
            path: path,
            body: body
        )
        guard (200...299).contains(http.statusCode) else {
            throw RuntimeSharingDaemonError.http(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        do {
            let envelope = try decoder.decode(
                RuntimeSharingDaemonEnvelope<T>.self,
                from: data
            )
            return try envelope.value()
        } catch {
            if let error = error as? RuntimeSharingDaemonError {
                throw error
            }
            throw RuntimeSharingDaemonError.invalidResponse
        }
    }

    private func requestVoid(
        method: String,
        path: [String]
    ) async throws {
        let (data, http) = try await perform(method: method, path: path)
        guard (200...299).contains(http.statusCode) else {
            throw RuntimeSharingDaemonError.http(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
    }

    private func perform(
        method: String,
        path: [String],
        body: (any Encodable)? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var url = endpoint
        for component in path {
            url.appendPathComponent(component)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = try JSONEncoder.runtimeSharing.encode(body)
        }
        if let managementToken, !managementToken.isEmpty {
            request.setValue(
                "Bearer \(managementToken)",
                forHTTPHeaderField: "Authorization"
            )
        }
        DeviceContext.apply(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RuntimeSharingDaemonError.invalidResponse
        }
        return (data, http)
    }
}

private final class RuntimeSharingDaemonSessionDelegate:
    NSObject,
    URLSessionDelegate,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    let trustPolicy: RuntimeServerTrustPolicy?

    init(trustPolicy: RuntimeServerTrustPolicy?) {
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

private struct RuntimeSharingDaemonEnvelope<T: Decodable>: Decodable {
    let code: Int
    let msg: String
    let data: T?

    func value() throws -> T {
        guard code == 0, let data else {
            throw RuntimeSharingDaemonError.daemon(code: code, message: msg)
        }
        return data
    }
}

private struct RuntimeSharingStartRequest: Encodable {
    let displayName: String?
    let listenAddress: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case listenAddress = "listen_address"
    }
}

private struct RuntimeSharingInvitationRequest: Encodable {
    let validity: TimeInterval

    enum CodingKeys: String, CodingKey {
        case validity = "validity_seconds"
    }
}

private struct RuntimeSharingDevicesPayload: Decodable {
    let devices: [RuntimeSharedDevice]?
    
    enum CodingKeys: CodingKey {
        case devices
    }
    
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.devices = try container.decodeIfPresent([RuntimeSharedDevice].self, forKey: .devices)
    }
}

public enum RuntimeSharingDaemonError: Error, LocalizedError, Equatable,
    Sendable
{
    case invalidResponse
    case http(statusCode: Int, body: String)
    case daemon(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The Runtime Sharing daemon returned an invalid response."
        case let .http(statusCode, body):
            return body.isEmpty
                ? "Runtime Sharing daemon request failed (HTTP \(statusCode))."
                : body
        case let .daemon(code, message):
            return message.isEmpty
                ? "Runtime Sharing daemon request failed (code \(code))."
                : message
        }
    }
}
