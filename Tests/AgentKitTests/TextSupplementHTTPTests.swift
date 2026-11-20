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

extension TextSupplementHTTPTests {
    func testUserQueueChecksRuntimeIdentityBeforePosting() async throws {
        SupplementHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/runtime/info")
            return Data(#"{"code":0,"msg":"ok","data":{"schema":"v1","server_id":"other","display_name":"Test","product":"codeagent","runtime_version":"1.0","agent_wire_protocol":{"major":1,"revision":"1.2"},"runtime_profile":"headless"}}"#.utf8)
        }
        do {
            _ = try await client().enqueueUserMessage(sessionID: "s", value: .init(text: "next", model: "selected"), serverID: "original")
            XCTFail("posting to a different runtime must fail")
        } catch RuntimeHTTPError.invalidResponse {}
    }

    func testUserQueueListCarriesRevisionAndCursor() async throws {
        SupplementHTTPProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/runtime/info":
                return Data(#"{"code":0,"msg":"ok","data":{"schema":"v1","server_id":"runtime","display_name":"Test","product":"codeagent","runtime_version":"1.0","agent_wire_protocol":{"major":1,"revision":"1.2"},"runtime_profile":"headless"}}"#.utf8)
            case "/v1/runtime/capabilities":
                return Data(#"{"code":0,"msg":"ok","data":{"capabilities":{"user_queue_text_v1":true}}}"#.utf8)
            default:
                XCTAssertEqual(request.url?.path, "/v1/conversations/s/queue")
                let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query, [.init(name: "revision", value: "3"), .init(name: "after_sequence", value: "2")])
                return Data(#"{"revision":3,"state":"enabled","items":[{"input":{"session_id":"s","request_id":"r","text":"next","context":{"wire_model":"selected"}},"sequence":3,"revision":3,"state":"queued"}]}"#.utf8)
            }
        }
        let cursor = try JSONDecoder().decode(UserQueuePage.Cursor.self, from: Data(#"{"session_id":"s","revision":3,"after_sequence":2}"#.utf8))
        let page = try await client().listUserQueue(sessionID: "s", cursor: cursor, serverID: "runtime")
        XCTAssertEqual(page.items.first?.input.requestID, "r")
    }
}

extension TextSupplementHTTPTests {
    func testQueuePriorityEncodesVersionAndOperationIdentity() throws {
        let change = UserQueueChange(revision: 7, action: .prioritize,
            requestID: "queued-message", operationID: "original-operation")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(change)) as? [String: Any])
        XCTAssertEqual(body["action"] as? String, "prioritize")
        XCTAssertEqual(body["revision"] as? Int, 7)
        XCTAssertEqual(body["request_id"] as? String, "queued-message")
        XCTAssertEqual(body["operation_id"] as? String, "original-operation")
    }

    func testQueueTakeBackRejectsReceiptForDifferentOperation() async throws {
        SupplementHTTPProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/runtime/info":
                return Data(#"{"code":0,"msg":"ok","data":{"schema":"v1","server_id":"runtime","display_name":"Test","product":"codeagent","runtime_version":"1.0","agent_wire_protocol":{"major":1,"revision":"1.2"},"runtime_profile":"headless"}}"#.utf8)
            case "/v1/runtime/capabilities":
                return Data(#"{"code":0,"msg":"ok","data":{"capabilities":{"user_queue_text_v1":true}}}"#.utf8)
            default:
                XCTAssertEqual(request.url?.path, "/v1/conversations/s/queue/original/take-back")
                XCTAssertEqual(request.httpMethod, "POST")
                return Data(#"{"input":{"session_id":"s","request_id":"original","text":"next","context":{"wire_model":"selected"}},"sequence":1,"revision":2,"state":"removed","take_back_id":"different"}"#.utf8)
            }
        }
        let http = client()
        do {
            _ = try await http.takeBackUserQueueMessage(sessionID: "s", requestID: "original",
                operation: .init(id: "expected", revision: 2), serverID: "runtime")
            XCTFail("an operation from another client cannot confirm this take-back")
        } catch RuntimeHTTPError.invalidResponse {}
        let receipt = try await http.takeBackUserQueueMessage(sessionID: "s", requestID: "original",
            operation: .init(id: "different", revision: 2), serverID: "runtime")
        XCTAssertEqual(receipt.takeBackID, "different")
    }

    func testInterruptedQueueResumeCarriesOriginalIdentityAndRevision() async throws {
        SupplementHTTPProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/runtime/info":
                return Data(#"{"code":0,"msg":"ok","data":{"schema":"v1","server_id":"runtime","display_name":"Test","product":"codeagent","runtime_version":"1.0","agent_wire_protocol":{"major":1,"revision":"1.2"},"runtime_profile":"headless"}}"#.utf8)
            case "/v1/runtime/capabilities":
                return Data(#"{"code":0,"msg":"ok","data":{"capabilities":{"user_queue_text_v1":true}}}"#.utf8)
            default:
                XCTAssertEqual(request.url?.path, "/v1/conversations/s/queue/control")
                XCTAssertEqual(request.httpMethod, "POST")
                var payload = request.httpBody ?? Data()
                if payload.isEmpty, let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        payload.append(contentsOf: buffer.prefix(count))
                    }
                }
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
                XCTAssertEqual(body["action"] as? String, "resume_interrupted")
                XCTAssertEqual(body["request_id"] as? String, "original")
                XCTAssertEqual(body["revision"] as? Int, 9)
                return Data(#"{"ok":true}"#.utf8)
            }
        }
        try await client().controlUserQueue(sessionID: "s",
            change: .init(revision: 9, action: .resumeInterrupted, requestID: "original"), serverID: "runtime")
    }
}
