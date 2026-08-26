import Foundation
import XCTest
@testable import AgentKit

// MARK: - Mock URLProtocol (HTTP client tests)

private final class PermissionsMockURLProtocol: URLProtocol {
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

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [PermissionsMockURLProtocol.self]
    return URLSession(configuration: config)
}

/// URLSession streams the request body, so a `URLProtocol` handler sees
/// `httpBody == nil` and must read `httpBodyStream` instead.
private func requestBodyData(_ request: URLRequest) -> Data? {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 4096
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: bufferSize)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return data
}

/// Thread-safe box for capturing values from `@Sendable` handler closures.
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

private func envelopeJSON(_ data: Any) -> Data {
    let obj: [String: Any] = ["code": 0, "msg": "success", "data": data]
    return try! JSONSerialization.data(withJSONObject: obj)
}

// MARK: - Workspace permissions endpoint tests

final class WorkspacePermissionsHTTPTests: XCTestCase {

    private func makeClient(session: URLSession) -> RuntimeHTTPClient {
        RuntimeHTTPClient(
            environment: RuntimeEnvironment(host: "127.0.0.1", port: 8797),
            session: session
        )
    }

    /// GET 路径构造：绝对路径按 `/` 自然分段（含空格段需要 URL 编码），不整体 %2F。
    func testGetRequestsPathSplitBySlashes() async throws {
        let session = makeMockSession()
        let capturedPath = LockedBox<String?>(nil)
        let capturedURL = LockedBox<String?>(nil)
        PermissionsMockURLProtocol.setHandler { request in
            capturedPath.value = request.url?.path
            capturedURL.value = request.url?.absoluteString
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!,
                envelopeJSON([
                    "scope": "workspace",
                    "path": "/Users/me/My Project",
                    "available": ["ask", "auto", "full"],
                    "mode": "auto",
                ])
            )
        }

        let client = makeClient(session: session)
        let permissions = try await client.getWorkspacePermissions(workspacePath: "/Users/me/My Project")

        // 路径按 `/` 自然分段（不整体 %2F）
        XCTAssertEqual(capturedPath.value, "/v1/workspaces/permissions/Users/me/My Project")
        // URLSession 实际发出的请求 URL 中空格被百分号编码（服务器收到 %20）
        XCTAssertEqual(
            capturedURL.value,
            "http://127.0.0.1:8797/v1/workspaces/permissions/Users/me/My%20Project"
        )
        XCTAssertEqual(permissions.scope, "workspace")
        XCTAssertEqual(permissions.path, "/Users/me/My Project")
        XCTAssertEqual(permissions.available, ["ask", "auto", "full"])
        XCTAssertEqual(permissions.mode, "auto")
    }

    /// GET 解码：`mode` 为合并后的有效档位。
    func testGetDecodesEffectiveMode() async throws {
        let session = makeMockSession()
        PermissionsMockURLProtocol.setHandler { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!,
                envelopeJSON([
                    "scope": "workspace",
                    "path": "/Users/me/proj",
                    "available": ["ask", "auto", "full"],
                    "mode": "full",
                ])
            )
        }

        let client = makeClient(session: session)
        let permissions = try await client.getWorkspacePermissions(workspacePath: "/Users/me/proj")

        XCTAssertEqual(permissions.mode, "full")
        XCTAssertEqual(permissions.available, ["ask", "auto", "full"])
    }

    /// PUT：正确路径 + `{"mode":"auto"}` 请求体。
    func testPutSendsModeBody() async throws {
        let session = makeMockSession()
        let captured = LockedBox<(method: String, path: String, body: String)?>(nil)
        PermissionsMockURLProtocol.setHandler { request in
            let body = requestBodyData(request).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            captured.value = (request.httpMethod ?? "", request.url?.path ?? "", body)
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!,
                envelopeJSON([
                    "scope": "workspace",
                    "path": "/Users/me/proj",
                    "available": ["ask", "auto", "full"],
                    "mode": "auto",
                ])
            )
        }

        let client = makeClient(session: session)
        let permissions = try await client.setWorkspacePermissions(workspacePath: "/Users/me/proj", mode: "auto")

        let value = try XCTUnwrap(captured.value)
        XCTAssertEqual(value.method, "PUT")
        XCTAssertEqual(value.path, "/v1/workspaces/permissions/Users/me/proj")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(value.body.utf8)) as? [String: String]
        )
        XCTAssertEqual(body["mode"], "auto")
        XCTAssertEqual(permissions.mode, "auto")
    }
}
