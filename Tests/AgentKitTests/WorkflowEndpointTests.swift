import Foundation
import XCTest
@testable import AgentKit

// MARK: - Mock URLProtocol (HTTP client tests)

private final class WorkflowMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    private static let lock = NSLock()

    static func setHandler(
        _ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) {
        lock.lock()
        defer { lock.unlock() }
        requestHandler = handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func makeWorkflowMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [WorkflowMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func workflowEnvelopeJSON(_ data: Any) -> Data {
    let obj: [String: Any] = ["code": 0, "msg": "success", "data": data]
    return try! JSONSerialization.data(withJSONObject: obj)
}

// MARK: - LockedBox (thread-safe capture)

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ initial: Value) {
        self.storage = initial
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }
    }
}

// MARK: - Workspace-scoped workflow endpoint tests (P18 R1/R2)

final class WorkflowEndpointHTTPTests: XCTestCase {

    private func makeClient(session: URLSession) -> RuntimeHTTPClient {
        RuntimeHTTPClient(
            environment: RuntimeEnvironment(host: "127.0.0.1", port: 8797),
            session: session
        )
    }

    /// 目录端点：`GET /v1/workflows?workspace=<abs_path>`，workspace 走 query 参数（%2F 编码）。
    func testListRequestsQueryParamWorkspacePath() async throws {
        let session = makeWorkflowMockSession()
        let capturedURL = LockedBox<String?>(nil)
        WorkflowMockURLProtocol.setHandler { request in
            capturedURL.value = request.url?.absoluteString
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!,
                workflowEnvelopeJSON([
                    ["id": 1, "name": "wf-a", "description": "d", "latest_hash": "abc", "latest_status": "success"]
                ])
            )
        }

        let client = makeClient(session: session)
        let items = try await client.listWorkspaceWorkflows(workspacePath: "/Users/me/My Project")

        let url = try XCTUnwrap(capturedURL.value)
        XCTAssertEqual(url, "http://127.0.0.1:8797/v1/workflows?workspace=%2FUsers%2Fme%2FMy%20Project")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "wf-a")
        XCTAssertEqual(items[0].latestStatus, "success")
    }

    /// 详情端点：`GET /v1/workflows/{name}?workspace=<abs_path>`。
    func testDetailUsesNamePathAndQueryParamWorkspace() async throws {
        let session = makeWorkflowMockSession()
        let capturedURL = LockedBox<String?>(nil)
        WorkflowMockURLProtocol.setHandler { request in
            capturedURL.value = request.url?.absoluteString
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!,
                workflowEnvelopeJSON([
                    "id": 1, "name": "wf-a", "description": "Detail",
                    "versions": [["id": 1, "version": 1, "hash": "abc", "created_at": "2026-01-01T00:00:00Z"]],
                    "runs": [["id": 10, "status": "running", "progress": 0.5, "error": "", "created_at": "2026-01-01T00:00:00Z"]],
                ])
            )
        }

        let client = makeClient(session: session)
        let detail = try await client.getWorkspaceWorkflowDetail(
            workspacePath: "/Users/me/code-agent", name: "wf-a"
        )

        let url = try XCTUnwrap(capturedURL.value)
        XCTAssertEqual(url, "http://127.0.0.1:8797/v1/workflows/wf-a?workspace=%2FUsers%2Fme%2Fcode-agent")
        XCTAssertEqual(detail.name, "wf-a")
        XCTAssertEqual(detail.versions.count, 1)
        XCTAssertEqual(detail.runs[0].status, "running")
    }

    /// 观测面端点：`GET /v1/workflows/{name}/runs/{task_id}/snapshot?workspace=<abs_path>`。
    func testSnapshotUsesTaskIDPathAndQueryParamWorkspace() async throws {
        let session = makeWorkflowMockSession()
        let capturedURL = LockedBox<String?>(nil)
        WorkflowMockURLProtocol.setHandler { request in
            capturedURL.value = request.url?.absoluteString
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!,
                workflowEnvelopeJSON([
                    "workflow_id": "wf-a", "goal": "g",
                    "task": ["id": 42, "status": "running", "progress": 0.5],
                    "nodes": [["name": "n", "state": "running", "terminal": false, "active": true, "suspended": false]],
                    "edges": [],
                    "snapshot_sequence": 7,
                ])
            )
        }

        let client = makeClient(session: session)
        let snapshot = try await client.getWorkspaceWorkflowSnapshot(
            workspacePath: "/Users/me/code-agent", workflowName: "wf-a", taskID: 42
        )

        let url = try XCTUnwrap(capturedURL.value)
        XCTAssertEqual(
            url,
            "http://127.0.0.1:8797/v1/workflows/wf-a/runs/42/snapshot?workspace=%2FUsers%2Fme%2Fcode-agent"
        )
        XCTAssertEqual(snapshot.workflowId, "wf-a")
        XCTAssertEqual(snapshot.task?.id, 42)
        XCTAssertEqual(snapshot.snapshotSequence, 7)
    }
}
