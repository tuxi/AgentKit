import Foundation
import XCTest
@testable import AgentKit

final class RuntimeSharingDaemonClientTests: XCTestCase {
    func testInvitationAcceptsDaemonRawBase64SPKI() throws {
        let invitation = RuntimePairingInvitation(
            serverID: "srv_1",
            serverDisplayName: "Mac",
            serviceType: "_talkify-agent._tcp.",
            serviceName: "Mac abc123",
            fallbackHost: "mac-host",
            port: 9443,
            bootstrapSecret: String(repeating: "s", count: 43),
            bootstrapExpiresAt: Date().addingTimeInterval(120),
            spkiSHA256: Data(repeating: 0, count: 32)
                .base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
        )

        let restored = try RuntimePairingInvitation.decode(
            payload: invitation.encodedPayload()
        )
        XCTAssertEqual(restored.spkiSHA256, invitation.spkiSHA256)
    }

    func testStartInvitationAndRevokeUseDaemonManagementContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RuntimeSharingDaemonMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = RuntimeSharingDaemonClient(
            endpoint: URL(string: "http://127.0.0.1:8797")!,
            managementToken: "local-token",
            session: session
        )

        RuntimeSharingDaemonMockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/runtime/sharing/start":
                return .json("""
                {"code":0,"msg":"success","data":{
                  "state":"running","listen_address":"0.0.0.0:0",
                  "listen_origin":"https://mac.local:9443","port":9443,
                  "started_at":"2026-08-20T01:02:03Z",
                  "stopped_at":null,"last_transition_at":"2026-08-20T01:02:03Z",
                  "last_error":null}}
                """)
            case "/v1/runtime/sharing/invitations":
                return .json("""
                {"code":0,"msg":"success","data":{
                  "version":1,"server_id":"srv_1","server_display_name":"Mac",
                  "service_type":"_talkify-agent._tcp.","service_name":"Mac abc123",
                  "fallback_host":"mac.local","port":9443,
                  "bootstrap_secret":"abcdefghijklmnopqrstuvwxyz0123456789_-",
                  "bootstrap_expires_at":"2026-08-20T01:04:03Z",
                  "spki_sha256":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}}
                """)
            case "/v1/runtime/sharing/devices/dev_1":
                return .json(#"{"code":0,"msg":"success","data":null}"#)
            default:
                return .json(#"{"code":404,"msg":"not found","data":null}"#)
            }
        }
        defer { RuntimeSharingDaemonMockURLProtocol.handler = nil }

        let status = try await client.startSharing(
            displayName: "Mac",
            listenAddress: "0.0.0.0:0"
        )
        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.port, 9443)

        let invitation = try await client.createPairingInvitation(validity: 120)
        XCTAssertEqual(invitation.serverID, "srv_1")
        XCTAssertEqual(invitation.port, 9443)

        try await client.revokeDevice("dev_1")
    }

    func testDaemonErrorEnvelopeIsReturnedAsTypedError() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RuntimeSharingDaemonMockURLProtocol.self]
        let client = RuntimeSharingDaemonClient(
            endpoint: URL(string: "http://127.0.0.1:8797")!,
            session: URLSession(configuration: configuration)
        )
        RuntimeSharingDaemonMockURLProtocol.handler = { _ in
            .json(#"{"code":1007,"msg":"sharing is disabled","data":null}"#)
        }
        defer { RuntimeSharingDaemonMockURLProtocol.handler = nil }

        do {
            _ = try await client.refreshStatus()
            XCTFail("Expected daemon error")
        } catch let error as RuntimeSharingDaemonError {
            XCTAssertEqual(
                error,
                .daemon(code: 1007, message: "sharing is disabled")
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private final class RuntimeSharingDaemonMockURLProtocol: URLProtocol
{
    enum Response: Sendable {
        case json(String)
    }

    private static let lock = NSLock()
    fileprivate typealias Handler = @Sendable (URLRequest) -> Response
    nonisolated(unsafe) private static var storedHandler: Handler?

    static var handler: Handler? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedHandler
        }
        set {
            lock.lock()
            storedHandler = newValue
            lock.unlock()
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler,
              case let .json(body) = handler(request),
              let data = body.data(using: .utf8),
              let client = client else {
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: data)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
