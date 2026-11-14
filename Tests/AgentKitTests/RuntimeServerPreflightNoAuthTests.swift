//
//  RuntimeServerPreflightNoAuthTests.swift
//  AgentKitTests
//
//  Locks the no-auth loopback add flow: a successful `/v1/runtime/models`
//  response must never surface as `modelCatalogUnavailable`, and a v2 catalog
//  with unavailable models still counts as a successful catalog.
//

#if os(macOS)
import Foundation
import XCTest
@testable import AgentKit

final class RuntimeServerPreflightNoAuthTests: XCTestCase {
    func testNoAuthLoopbackPreflightAcceptsV2CatalogWithUnavailableModels() async throws {
        let protocolClass: AnyClass = NoAuthRuntimeURLProtocol.self
        NoAuthRuntimeURLProtocol.handler = { request in
            switch request.url?.path {
            case "/healthz":
                return (200, [:], Data("ok".utf8))
            case "/v1/runtime/info":
                return Self.envelope("""
                {
                  "schema": "runtime-info/v1",
                  "server_id": "srv_no_auth",
                  "display_name": "No Auth Runtime",
                  "product": "codeagent",
                  "runtime_version": "dev",
                  "agent_wire_protocol": {"major": 1, "revision": "1.2"},
                  "runtime_profile": "headless"
                }
                """)
            case "/v1/runtime/capabilities":
                return Self.envelope("""
                {"capabilities": {"activity_snapshot_v1": true, "max_concurrent_turns": 4}}
                """)
            case "/v1/runtime/models":
                return Self.envelope(Self.catalogJSON)
            default:
                return (404, [:], Data())
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        let session = URLSession(configuration: configuration)
        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:18797"))
        let service = RuntimeServerPreflightService(
            platform: .macOS,
            noAuthClientFactory: { endpoint in
                RuntimeHTTPClient(environment: try RuntimeEnvironment(origin: endpoint), session: session)
            }
        )

        let result = try await service.test(
            endpoint: endpoint,
            authentication: .none,
            accessToken: nil
        )
        XCTAssertEqual(result.kind, .local)
        XCTAssertEqual(result.info.serverID, "srv_no_auth")
        XCTAssertEqual(result.modelCatalog.schema, "runtime-model-catalog/v2")
        XCTAssertEqual(result.modelCatalog.connections.count, 1)
        XCTAssertEqual(result.modelCatalog.connections[0].models.count, 2)
        XCTAssertEqual(
            result.modelCatalog.unifiedModels(serverConnectionID: "server-a").map(\.wireModelID),
            ["qwen3.8-flash"]
        )
    }

    func testSuccessfulEmptyCatalogIsNotReportedUnavailable() async throws {
        NoAuthRuntimeURLProtocol.handler = { request in
            switch request.url?.path {
            case "/healthz":
                return (200, [:], Data("ok".utf8))
            case "/v1/runtime/info":
                return Self.envelope("""
                {
                  "schema": "runtime-info/v1",
                  "server_id": "srv_empty",
                  "display_name": "Empty Runtime",
                  "product": "codeagent",
                  "runtime_version": "dev",
                  "agent_wire_protocol": {"major": 1, "revision": "1.2"},
                  "runtime_profile": "headless"
                }
                """)
            case "/v1/runtime/capabilities":
                return Self.envelope(#"{"capabilities": {}}"#)
            case "/v1/runtime/models":
                return Self.envelope("""
                {
                  "schema": "runtime-model-catalog/v1",
                  "revision": 0,
                  "default_runtime_alias": "",
                  "connections": []
                }
                """)
            default:
                return (404, [:], Data())
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NoAuthRuntimeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:18797"))
        let service = RuntimeServerPreflightService(
            platform: .macOS,
            noAuthClientFactory: { endpoint in
                RuntimeHTTPClient(environment: try RuntimeEnvironment(origin: endpoint), session: session)
            }
        )

        let result = try await service.test(
            endpoint: endpoint,
            authentication: .none,
            accessToken: nil
        )
        XCTAssertTrue(result.modelCatalog.connections.isEmpty)
        XCTAssertTrue(result.modelCatalog.hasSupportedSchema)
    }

    private static let catalogJSON = """
    {
      "schema": "runtime-model-catalog/v2",
      "revision": 0,
      "default_runtime_alias": "qwen",
      "connections": [{
        "id": "qwen",
        "provider_id": "qwen",
        "display_name": "qwen",
        "billing_source": "server_managed",
        "credential": {"status": "missing", "source": "env"},
        "models": [
          {
            "runtime_alias": "qwen",
            "wire_model_id": "qwen3-coder-plus",
            "display_name": "qwen3-coder-plus",
            "context_window": 128000,
            "supports_tools": true,
            "supports_reasoning": false,
            "input_modalities": ["text"],
            "available": false,
            "unavailable_reason": "no_auth"
          },
          {
            "runtime_alias": "qwen-flash",
            "wire_model_id": "qwen3.8-flash",
            "display_name": "qwen3.8-flash",
            "context_window": 128000,
            "supports_tools": true,
            "supports_reasoning": true,
            "input_modalities": ["text"],
            "available": true
          }
        ]
      }]
    }
    """

    private static func envelope(_ dataJSON: String) -> (Int, [String: String], Data) {
        let body = """
        {"trace_id":"test","code":0,"msg":"success","data":\(dataJSON)}
        """
        return (200, ["Content-Type": "application/json"], Data(body.utf8))
    }
}

private final class NoAuthRuntimeURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler:
        (@Sendable (URLRequest) -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (status, headers, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
