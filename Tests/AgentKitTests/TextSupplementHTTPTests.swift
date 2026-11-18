import Foundation
import XCTest
@testable import AgentKit

private final class SupplementHTTPProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class TextSupplementHTTPTests: XCTestCase {
    private func client() -> RuntimeHTTPClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SupplementHTTPProtocol.self]
        return .init(environment: .init(host: "localhost", port: 1234), session: URLSession(configuration: config))
    }
    func testTextRequestAndRecoveryQueryUseSeparateEndpoints() async throws {
        SupplementHTTPProtocol.handler = { request in
            if request.url?.path == "/v1/runtime/capabilities" { return Data(#"{"code":0,"msg":"ok","data":{"capabilities":{"user_supplement_text_v1":true}}}"#.utf8) }
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.url?.path, "/v1/conversations/s/supplements")
                var payload = request.httpBody ?? Data()
                if payload.isEmpty, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        payload.append(contentsOf: buffer.prefix(count))
                    }
                }
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: String])
                XCTAssertEqual(body, ["request_id": "r", "expected_turn_id": "t", "text": "补充要求"])
            } else { XCTAssertEqual(request.url?.path, "/v1/conversations/s/supplements/r") }
            return Data(#"{"input":{"session_id":"s","request_id":"r","expected_turn_id":"t","text":"补充要求"},"sequence":7,"state":"pending_apply"}"#.utf8)
        }
        let http = client(); let identity = try await http.backgroundJobRuntimeIdentity()
        let sent = try await http.submitTextSupplement(sessionID: "s", request: .init(requestID: "r", expectedTurnID: "t", text: "补充要求"), runtimeIdentity: identity)
        let queried = try await http.queryTextSupplement(sessionID: "s", requestID: "r", runtimeIdentity: identity)
        XCTAssertEqual(sent, queried)
    }
    func testDisabledCapabilityNeverPosts() async throws {
        SupplementHTTPProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/runtime/capabilities")
            return Data(#"{"code":0,"msg":"ok","data":{"capabilities":{}}}"#.utf8)
        }
        do { _ = try await client().submitTextSupplement(sessionID: "s", request: .init(expectedTurnID: "t", text: "keep"), runtimeIdentity: "http://localhost:1234"); XCTFail("unsupported") } catch RuntimeHTTPError.unsupported {} catch { XCTFail("unexpected error: \(error)") }
    }
}
