import Foundation
import XCTest
@testable import AgentKit

private final class JobHTTPProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try XCTUnwrap(Self.handler)(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private actor JobEndpoint {
    var url = URL(string: "https://runtime.example")!
    func get() -> URL { url }
    func set(_ value: String) { url = URL(string: value)! }
}
final class BackgroundJobHTTPTests: XCTestCase {
    override func tearDown() { JobHTTPProtocol.handler = nil; super.tearDown() }
    private func client(environment: RuntimeEnvironment = .init(host: "localhost", port: 1234),
                        credentials: MemoryCredentialStore = .init()) -> RuntimeHTTPClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [JobHTTPProtocol.self]
        return .init(environment: environment, session: URLSession(configuration: config),
                     credentialStore: credentials, credentialTarget: .runtimeAccess("job-fixture"))
    }
    private static func response(_ status: String = "running", pending: Bool = false, call: String = "call", session: String = "session", list: Bool = true) -> Data {
        let snapshot = "{\"job_id\":\"job_opaque-uuid\",\"session_id\":\"\(session)\",\"turn_id\":\"turn\",\"call_id\":\"\(call)\",\"command\":\"worker\",\"status\":\"\(status)\",\"duration_ms\":100,\"cancel_requested\":\(pending),\"output_tail\":\"ok\"}"
        return Data("{\"code\":0,\"msg\":\"ok\",\"data\":{\"\(list ? "jobs" : "job")\":\(list ? "[" : "")\(snapshot)\(list ? "]" : "")}}".utf8)
    }
    func testListUsesScopedRouteAuthAndEnvelope() async throws {
        let credentials = MemoryCredentialStore()
        try await credentials.set(.init(kind: .bearer, secret: "fixture-token"), for: .runtimeAccess("job-fixture"))
        JobHTTPProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/conversations/session/jobs")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            return (200, Self.response())
        }
        let http = client(credentials: credentials)
        let jobs = try await http.listBackgroundJobs(conversationID: "session", runtimeIdentity: http.backgroundJobRuntimeIdentity())
        XCTAssertEqual(jobs.first?.jobID, "job_opaque-uuid")
        XCTAssertEqual(jobs.first?.status, .running)
    }
    func testStop202AndTerminal200UseExactOwnerBody() async throws {
        for (code, status, pending) in [(202, "running", true), (200, "exited", false), (200, "canceled", false)] {
            JobHTTPProtocol.handler = { request in
                XCTAssertEqual(request.url?.path, "/v1/conversations/session/jobs/job_opaque-uuid/cancel")
                XCTAssertEqual(request.httpMethod, "POST")
                let bytes = request.httpBody ?? request.httpBodyStream.flatMap { stream -> Data? in
                    stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 512); var data = Data()
                    while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) }; return data
                }
                let json = try JSONSerialization.jsonObject(with: XCTUnwrap(bytes)) as? [String: String]
                XCTAssertEqual(json, ["turn_id": "turn", "call_id": "call"])
                return (code, Self.response(status, pending: pending, list: false))
            }
            let http = client()
            let result = try await http.cancelBackgroundJob(conversationID: "session", owner: .init(jobID: "job_opaque-uuid", turnID: "turn", callID: "call"), runtimeIdentity: http.backgroundJobRuntimeIdentity())
            XCTAssertEqual(result.status.rawValue, status); XCTAssertEqual(result.cancelRequested, pending)
        }
    }
    func testHTTPFailuresAndWrongOwnerNeverBecomeSuccessfulState() async throws {
        for code in [400, 401, 403, 404, 503] {
            JobHTTPProtocol.handler = { _ in (code, Data("{\"code\":1,\"msg\":\"error\"}".utf8)) }
            let http = client()
            do { _ = try await http.listBackgroundJobs(conversationID: "session", runtimeIdentity: http.backgroundJobRuntimeIdentity()); XCTFail("accepted HTTP failure") } catch {}
        }
        JobHTTPProtocol.handler = { _ in (200, Self.response(session: "another-session")) }
        let http = client()
        do { _ = try await http.listBackgroundJobs(conversationID: "session", runtimeIdentity: http.backgroundJobRuntimeIdentity()); XCTFail("accepted wrong owner") } catch {}
        JobHTTPProtocol.handler = { _ in (202, Self.response(pending: true, call: "stale-call", list: false)) }
        do { _ = try await http.cancelBackgroundJob(conversationID: "session", owner: .init(jobID: "job_opaque-uuid", turnID: "turn", callID: "call"), runtimeIdentity: http.backgroundJobRuntimeIdentity()); XCTFail("accepted wrong call") } catch {}
    }
    func testEndpointSwitchRejectsControlBeforeDispatch() async throws {
        let endpoint = JobEndpoint(); let http = client(environment: .init(originProvider: { await endpoint.get() }))
        let original = try await http.backgroundJobRuntimeIdentity()
        await endpoint.set("https://new-runtime.example")
        JobHTTPProtocol.handler = { _ in XCTFail("old owner retargeted onto new Runtime"); return (202, Self.response(pending: true, list: false)) }
        do { _ = try await http.cancelBackgroundJob(conversationID: "session", owner: .init(jobID: "job_opaque-uuid", turnID: "turn", callID: "call"), runtimeIdentity: original); XCTFail("endpoint switch accepted") } catch {}
    }
    func testBasePathsFailClosedInsteadOfCollapsingControlIdentity() async throws {
        // RuntimeEnvironment's public contract is origin-only. Dynamic provider
        // paths must be rejected too, before normalization can erase the scope.
        for path in ["https://runtime.example/team-a", "https://runtime.example/team-b"] {
            XCTAssertThrowsError(try RuntimeEnvironment(origin: URL(string: path)!))
        }
        let endpoint = JobEndpoint(); let http = client(environment: .init(originProvider: { await endpoint.get() }))
        let original = try await http.backgroundJobRuntimeIdentity()
        await endpoint.set("https://runtime.example/team-b")
        JobHTTPProtocol.handler = { _ in XCTFail("unsupported base path reached network"); return (200, Self.response()) }
        do { _ = try await http.listBackgroundJobs(conversationID: "session", runtimeIdentity: original); XCTFail("base path silently dropped") } catch {}
    }
    func testMalformedEnvelopeAndUnknownStatusAreConservative() async throws {
        let http = client()
        for value in ["{\"code\":1,\"msg\":\"failed\",\"data\":{\"jobs\":[]}}", "{\"code\":0,\"msg\":\"ok\",\"data\":null}"] {
            JobHTTPProtocol.handler = { _ in (200, Data(value.utf8)) }
            do { _ = try await http.listBackgroundJobs(conversationID: "session", runtimeIdentity: http.backgroundJobRuntimeIdentity()); XCTFail("invalid envelope accepted") } catch {}
        }
        JobHTTPProtocol.handler = { _ in (200, Self.response("future-status")) }
        let list = try await http.listBackgroundJobs(conversationID: "session", runtimeIdentity: http.backgroundJobRuntimeIdentity())
        XCTAssertEqual(list.first?.status, .unknown)
    }
}
