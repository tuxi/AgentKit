import Foundation
import XCTest
@testable import AgentKit

private final class TaskHTTPProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, data) = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class TaskWriteCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [URLRequest] = []
    func append(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; records.append(request) }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return records }
}

final class CodingTaskHTTPTests: XCTestCase {
    private func client(_ credentials: any CredentialStore) -> RuntimeHTTPClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TaskHTTPProtocol.self]
        return RuntimeHTTPClient(environment: .init(host: "127.0.0.1", port: 1234), session: URLSession(configuration: config), credentialStore: credentials, credentialTarget: .runtimeAccess("fixture"))
    }

    func testReadPortKeepsCredentialTargetAndExactDecimalQuery() async throws {
        let credentials = MemoryCredentialStore()
        try await credentials.set(.init(kind: .bearer, secret: "offline-owner-fixture"), for: .runtimeAccess("fixture"))
        try await credentials.set(.init(kind: .bearer, secret: "unrelated-provider-fixture"), for: .llm("provider"))
        TaskHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer offline-owner-fixture")
            XCTAssertEqual(request.url?.path, "/v1/tasks/task-1/events")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first { $0.name == "after" }?.value, "9007199254740993")
            return (200, Data("{\"code\":0,\"msg\":\"success\",\"data\":{\"task_id\":\"task-1\",\"after\":\"9007199254740993\",\"next_cursor\":\"9007199254740993\",\"events\":[],\"has_more\":false,\"resync_required\":false}}".utf8))
        }
        let page = try await client(credentials).codingTaskGet(CodingTaskEventPage.self, path: ["v1", "tasks", "task-1", "events"], query: [.init(name: "after", value: "9007199254740993")])
        XCTAssertEqual(page.next_cursor, "9007199254740993")
    }

    func testForbiddenAndMissingCapabilityRemainErrors() async throws {
        let http = client(MemoryCredentialStore())
        for status in [401, 403, 404] {
            TaskHTTPProtocol.handler = { _ in (status, Data("{\"code\":40300,\"msg\":\"forbidden\"}".utf8)) }
            do {
                _ = try await http.codingTaskGet(CodingTaskCapabilities.self, path: ["v1", "tasks", "capabilities"])
                XCTFail("HTTP error became an empty successful list")
            } catch {
                let message = await CodingTaskStore.message(error)
                XCTAssertFalse(message.isEmpty)
            }
        }
    }

    func testWritePinsOriginalOriginThroughIdentityProbe() async throws {
        let capture = TaskWriteCapture()
        let environment = RuntimeEnvironment(originProvider: {
            URL(string: capture.requests.isEmpty ? "http://127.0.0.1:1111" : "http://127.0.0.1:2222")
        })
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TaskHTTPProtocol.self]
        let credentials = MemoryCredentialStore()
        try await credentials.set(.init(kind: .bearer, secret: "offline-owner"), for: .runtimeAccess("fixture"))
        let http = RuntimeHTTPClient(environment: environment, session: URLSession(configuration: config), credentialStore: credentials, credentialTarget: .runtimeAccess("fixture"))
        TaskHTTPProtocol.handler = { request in
            capture.append(request)
            XCTAssertEqual(request.url?.port, 1111)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer offline-owner")
            if request.httpMethod == "GET" {
                XCTAssertEqual(request.url?.path, "/v1/tasks/capabilities")
                return (200, Data("{\"code\":0,\"msg\":\"success\",\"data\":{\"server_id\":\"server\",\"store_id\":\"store\",\"capabilities\":[\"task_links_v1\"]}}".utf8))
            }
            XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.url?.path, "/v1/tasks")
            return (200, Data("{\"code\":0,\"msg\":\"success\",\"data\":{\"id\":\"task\",\"status\":\"recorded\"}}".utf8))
        }
        let receipt = try await http.codingTaskPost(CodingTaskReceipt.self, path: ["v1", "tasks"],
            body: CodingTaskCreateRequest(request_id: "fixed", workspace_session_id: "session", goal: "goal", acceptance: []),
            identity: .init(serverID: "server", storeID: "store"), required: ["task_links_v1"])
        XCTAssertEqual(receipt.id, "task"); XCTAssertEqual(capture.requests.count, 2)
    }

    func testWrongStoreAndMissingReadyCapabilityNeverPost() async throws {
        let capture = TaskWriteCapture(), http = client(MemoryCredentialStore())
        TaskHTTPProtocol.handler = { request in
            capture.append(request)
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, Data("{\"code\":0,\"msg\":\"success\",\"data\":{\"server_id\":\"server\",\"store_id\":\"store\",\"capabilities\":[\"task_links_v1\"]}}".utf8))
        }
        for (store, flag) in [("other-store", "task_links_v1"), ("store", "task_managed_workflow_v1")] {
            do {
                _ = try await http.codingTaskPost(CodingTaskReceipt.self, path: ["v1", "tasks"], body: ["request_id": "fixed"],
                    identity: .init(serverID: "server", storeID: store), required: [flag])
                XCTFail("identity/readiness mismatch admitted a write")
            } catch {}
        }
        XCTAssertEqual(capture.requests.count, 2)
    }
}
