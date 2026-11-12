import Foundation
import XCTest
@testable import AgentKit

private final class SkillPluginHTTPProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            Self.requests.append(request)
            let (status, headers, data) = try XCTUnwrap(Self.handler)(request)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: headers
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class SkillPluginManagementHTTPTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SkillPluginHTTPProtocol.handler = nil
        SkillPluginHTTPProtocol.requests = []
    }

    override func tearDown() {
        SkillPluginHTTPProtocol.handler = nil
        SkillPluginHTTPProtocol.requests = []
        super.tearDown()
    }

    func testSkillInventoryUsesOnlySessionScopeAndNeverWorkspacePath() async throws {
        SkillPluginHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/runtime/skills")
            let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.queryItems, [URLQueryItem(name: "session_id", value: "sess_dreamlog")])
            XCTAssertFalse(components.queryItems?.contains(where: { $0.name == "workspace_path" }) == true)
            return (200, ["Content-Type": "application/json"], Self.envelope(#"""
            {
              "schema": "runtime-skill-inventory/v1",
              "scope": {"session_id": "sess_dreamlog", "display_name": "DreamLog", "resolved": true},
              "items": [],
              "warnings": [],
              "reload_required": false
            }
            """#))
        }

        let inventory = try await client().skillInventory(sessionID: "sess_dreamlog")
        XCTAssertTrue(inventory.scope.resolved)
        XCTAssertEqual(SkillPluginHTTPProtocol.requests.count, 1)
    }

    func testPluginLifecycleUsesStableRoutesAndExplicitConfirmation() async throws {
        SkillPluginHTTPProtocol.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/runtime/plugins"):
                return (200, ["Content-Type": "application/json"], Self.envelope(#"{"schema":"runtime-plugin-inventory/v1","items":[],"reload_required":false}"#))
            case ("POST", "/v1/runtime/plugins/install-local"):
                let body = try XCTUnwrap(Self.bodyData(request))
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(object["source"] as? String, "/tmp/docs-plugin")
                XCTAssertEqual(object["confirmed"] as? Bool, true)
                return (201, ["Content-Type": "application/json"], Self.mutation(action: "installed", reloadRequired: true))
            case ("POST", "/v1/runtime/plugins/docs/disable"):
                return (200, ["Content-Type": "application/json"], Self.mutation(action: "disabled", reloadRequired: true))
            case ("DELETE", "/v1/runtime/plugins/docs"):
                return (200, ["Content-Type": "application/json"], Self.mutation(action: "uninstalled", reloadRequired: true))
            default:
                XCTFail("unexpected request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return (500, [:], Data())
            }
        }

        let runtime = client()
        _ = try await runtime.pluginInventory()
        _ = try await runtime.installLocalPlugin(source: "/tmp/docs-plugin", confirmed: true)
        _ = try await runtime.setPluginEnabled(name: "docs", enabled: false)
        _ = try await runtime.uninstallPlugin(name: "docs")

        XCTAssertEqual(SkillPluginHTTPProtocol.requests.count, 4)
        XCTAssertEqual(SkillPluginHTTPProtocol.requests[1].httpMethod, "POST")
        XCTAssertEqual(SkillPluginHTTPProtocol.requests[2].url?.path, "/v1/runtime/plugins/docs/disable")
        XCTAssertEqual(SkillPluginHTTPProtocol.requests[3].httpMethod, "DELETE")
    }

    func testManagementStatusCodesRemainDistinguishable() async throws {
        let cases: [(Int, String, SkillPluginManagementError)] = [
            (401, "runtime_auth_required", .authenticationRequired("authentication required")),
            (409, "workspace_scope_unresolved", .workspaceScopeUnresolved("workspace unresolved")),
            (422, "plugin_manifest_invalid", .pluginManifestInvalid("manifest invalid")),
            (428, "plugin_confirmation_required", .pluginConfirmationRequired("confirmation required")),
        ]

        for (status, code, expected) in cases {
            SkillPluginHTTPProtocol.handler = { _ in
                (status, ["Content-Type": "application/json"], Self.error(code: code, message: expected.errorDescription ?? code))
            }
            do {
                _ = try await client().pluginInventory()
                XCTFail("HTTP \(status) was accepted")
            } catch let error as SkillPluginManagementError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("unexpected error for HTTP \(status): \(error)")
            }
        }
    }

    private func client() -> RuntimeHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SkillPluginHTTPProtocol.self]
        return RuntimeHTTPClient(
            environment: RuntimeEnvironment(host: "127.0.0.1", port: 8797),
            session: URLSession(configuration: configuration),
            credentialStore: MemoryCredentialStore(),
            credentialTarget: .runtimeAccess("management-test")
        )
    }

    private static func envelope(_ dataJSON: String) -> Data {
        Data(#"{"trace_id":"trace","code":0,"msg":"success","data":\#(dataJSON)}"#.utf8)
    }

    private static func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func error(code: String, message: String) -> Data {
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return Data(#"{"trace_id":"trace","code":40000,"msg":"\#(escaped)","data":{"code":"\#(code)","message":"\#(escaped)"}}"#.utf8)
    }

    private static func mutation(action: String, reloadRequired: Bool) -> Data {
        envelope(#"""
        {
          "schema": "runtime-plugin-mutation/v1",
          "action": "\#(action)",
          "name": "docs",
          "version": "1.0.0",
          "reload_required": \#(reloadRequired),
          "reload_hint": "Restart the CodeAgent runtime to apply plugin changes."
        }
        """#)
    }
}
