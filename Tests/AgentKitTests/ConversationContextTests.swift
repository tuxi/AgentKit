import Foundation
import XCTest
@testable import AgentKit

// MARK: - Mock URLProtocol (HTTP client tests)

private final class ConversationContextMockURLProtocol: URLProtocol {
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
    config.protocolClasses = [ConversationContextMockURLProtocol.self]
    return URLSession(configuration: config)
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

// MARK: - Wire contract decode

final class ConversationContextDecodingTests: XCTestCase {

    private let exampleJSON = """
    {
      "trace_id": "trace-1",
      "code": 0,
      "msg": "success",
      "data": {
        "model": {
          "name": "deepseek-v4-pro",
          "context_window": 1000000,
          "compact_threshold": 750000,
          "compact_ratio": 0.75
        },
        "current": {
          "prompt_tokens": 42000,
          "usage_pct": 4.2,
          "threshold_pct": 75.0
        },
        "compaction": {
          "total_count": 2,
          "total_saved_tokens": 18000,
          "last": {
            "before_tokens": 96000,
            "after_tokens": 82000,
            "saved_tokens": 14000,
            "ratio": 0.1458,
            "summary_chars": 3200,
            "ineffective": false,
            "at": "2026-08-09T12:34:56.789Z"
          }
        },
        "structure": {
          "message_count": 24,
          "estimated_tokens": 8000,
          "has_summary": true,
          "summary_chars": 3200
        }
      }
    }
    """

    func testDecodesFullLockedWireContract() throws {
        let snapshot = try JSONDecoder().decode(
            ConversationContextSnapshot.self,
            from: try XCTUnwrap(exampleJSON.data(using: .utf8))
        )

        // model
        XCTAssertEqual(snapshot.model.name, "deepseek-v4-pro")
        XCTAssertEqual(snapshot.model.contextWindow, 1_000_000)
        XCTAssertEqual(snapshot.model.compactThreshold, 750_000)
        XCTAssertEqual(snapshot.model.compactRatio, 0.75)

        // current
        XCTAssertEqual(snapshot.current.promptTokens, 42_000)
        XCTAssertEqual(snapshot.current.usagePct, 4.2)
        XCTAssertEqual(snapshot.current.thresholdPct, 75.0)

        // compaction
        XCTAssertEqual(snapshot.compaction.totalCount, 2)
        XCTAssertEqual(snapshot.compaction.totalSavedTokens, 18_000)
        let last = try XCTUnwrap(snapshot.compaction.last)
        XCTAssertEqual(last.beforeTokens, 96_000)
        XCTAssertEqual(last.afterTokens, 82_000)
        XCTAssertEqual(last.savedTokens, 14_000)
        XCTAssertEqual(last.ratio, 0.1458, accuracy: 0.0001)
        XCTAssertEqual(last.summaryChars, 3_200)
        XCTAssertEqual(last.ineffective, false)
        XCTAssertEqual(last.at, "2026-08-09T12:34:56.789Z")

        // structure
        XCTAssertEqual(snapshot.structure.messageCount, 24)
        XCTAssertEqual(snapshot.structure.estimatedTokens, 8_000)
        XCTAssertEqual(snapshot.structure.hasSummary, true)
        XCTAssertEqual(snapshot.structure.summaryChars, 3_200)
    }

    func testDecodesWithoutCompactionLast() throws {
        let json = """
        {
          "model": {
            "name": "deepseek-v4-pro",
            "context_window": 1000000,
            "compact_threshold": 750000,
            "compact_ratio": 0.75
          },
          "current": { "prompt_tokens": 100, "usage_pct": 0.01, "threshold_pct": 75.0 },
          "compaction": { "total_count": 0, "total_saved_tokens": 0 },
          "structure": { "message_count": 1, "estimated_tokens": 50, "has_summary": false, "summary_chars": 0 }
        }
        """
        let snapshot = try JSONDecoder().decode(
            ConversationContextSnapshot.self,
            from: try XCTUnwrap(json.data(using: .utf8))
        )
        XCTAssertNil(snapshot.compaction.last)
        XCTAssertEqual(snapshot.compaction.totalCount, 0)
        XCTAssertEqual(snapshot.structure.hasSummary, false)
    }

    func testRoundTripsThroughEncoder() throws {
        let decoded = try JSONDecoder().decode(
            ConversationContextSnapshot.self,
            from: try XCTUnwrap(exampleJSON.data(using: .utf8))
        )
        let reencoded = try JSONEncoder().encode(decoded)
        let redecoded = try JSONDecoder().decode(
            ConversationContextSnapshot.self,
            from: reencoded
        )
        XCTAssertEqual(redecoded, decoded)
    }
}

// MARK: - HTTP client endpoint

final class ConversationContextHTTPTests: XCTestCase {

    private func makeClient(session: URLSession) -> RuntimeHTTPClient {
        RuntimeHTTPClient(
            environment: RuntimeEnvironment(host: "127.0.0.1", port: 8797),
            session: session
        )
    }

    func testGetConversationContextRequestsCorrectPath() async throws {
        let session = makeMockSession()
        let capturedPath = LockedBox<String?>(nil)
        MockURLProtocol.setHandler { request in
            capturedPath.value = request.url?.path
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!,
                envelopeJSON([
                    "model": [
                        "name": "deepseek-v4-pro",
                        "context_window": 1_000_000,
                        "compact_threshold": 750_000,
                        "compact_ratio": 0.75,
                    ],
                    "current": ["prompt_tokens": 42_000, "usage_pct": 4.2, "threshold_pct": 75.0],
                    "compaction": ["total_count": 0, "total_saved_tokens": 0],
                    "structure": [
                        "message_count": 24,
                        "estimated_tokens": 8_000,
                        "has_summary": true,
                        "summary_chars": 3_200,
                    ],
                ])
            )
        }

        let client = makeClient(session: session)
        let snapshot = try await client.getConversationContext(id: "conv-123")

        XCTAssertEqual(capturedPath.value, "/v1/conversations/conv-123/context")
        XCTAssertEqual(snapshot.model.name, "deepseek-v4-pro")
        XCTAssertEqual(snapshot.current.promptTokens, 42_000)
        XCTAssertEqual(snapshot.structure.messageCount, 24)
    }

    func testGetConversationContextNotFoundThrows() async {
        let session = makeMockSession()
        MockURLProtocol.setHandler { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 404,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!,
                Data("{}".utf8)
            )
        }

        let client = makeClient(session: session)
        do {
            _ = try await client.getConversationContext(id: "missing")
            XCTFail("expected notFound error")
        } catch let error as RuntimeHTTPError {
            if case .notFound = error {
                // expected
            } else {
                XCTFail("unexpected error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

// MARK: - DefaultAgentClient forwarding

final class ConversationContextForwardingTests: XCTestCase {

    private func makeSnapshot() -> ConversationContextSnapshot {
        ConversationContextSnapshot(
            model: ConversationContextModel(
                name: "deepseek-v4-pro",
                contextWindow: 1_000_000,
                compactThreshold: 750_000,
                compactRatio: 0.75
            ),
            current: ConversationContextCurrent(
                promptTokens: 42_000,
                usagePct: 4.2,
                thresholdPct: 75.0
            ),
            compaction: ConversationContextCompaction(
                totalCount: 2,
                totalSavedTokens: 18_000,
                last: ConversationContextCompactEntry(
                    beforeTokens: 96_000,
                    afterTokens: 82_000,
                    savedTokens: 14_000,
                    ratio: 0.1458,
                    summaryChars: 3_200,
                    ineffective: false,
                    at: "2026-08-09T12:34:56.789Z"
                )
            ),
            structure: ConversationContextStructure(
                messageCount: 24,
                estimatedTokens: 8_000,
                hasSummary: true,
                summaryChars: 3_200
            )
        )
    }

    func testDefaultAgentClientForwardsContextToTransport() async throws {
        let expected = makeSnapshot()
        let transport = StubContextTransport(snapshot: expected)
        let client = DefaultAgentClient(transport: transport)

        let snapshot = try await client.getConversationContext(id: "conv-123")

        XCTAssertEqual(transport.lastRequestedID, "conv-123")
        XCTAssertEqual(snapshot, expected)
    }

    func testDefaultAgentClientPropagatesTransportError() async {
        struct StubError: Error, Sendable {}
        let transport = StubContextTransport(snapshot: nil, error: StubError())
        let client = DefaultAgentClient(transport: transport)

        do {
            _ = try await client.getConversationContext(id: "conv-123")
            XCTFail("expected error to propagate")
        } catch is StubError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

/// Minimal AgentTransport fake covering only the context snapshot path.
private final class StubContextTransport: AgentTransport, @unchecked Sendable {
    let snapshot: ConversationContextSnapshot?
    let error: Error?
    private(set) var lastRequestedID: String?

    init(snapshot: ConversationContextSnapshot?, error: Error? = nil) {
        self.snapshot = snapshot
        self.error = error
    }

    var isConnected: Bool { false }
    var activeSessionID: String? { nil }

    func createConversation(workspacePath: String) async throws -> ConversationRef {
        throw RuntimeHTTPError.unsupported
    }
    func listConversations() async throws -> [ConversationRef] { [] }
    func renameConversation(id: String, name: String) async throws -> ConversationRef {
        throw RuntimeHTTPError.unsupported
    }
    func attach(sessionID: String, since: Int) async throws -> AsyncStream<AgentEvent> {
        AsyncStream { $0.finish() }
    }
    func disconnect() async {}
    func send(input: AgentInput) async {}
    func approve(id: String, value: Bool) async {}
    func approve(id: String, decision: String, scope: String?) async {}
    func approvePlan(id: String, value: Bool) async {}
    func sendAskUserResponse(id: String, selected: [String], notes: String?) async {}
    func cancelTurn() async {}
    func getConversationDetail(id: String) async throws -> ConversationDetail {
        throw RuntimeHTTPError.unsupported
    }
    func getConversationContext(id: String) async throws -> ConversationContextSnapshot {
        lastRequestedID = id
        if let error { throw error }
        guard let snapshot else { throw RuntimeHTTPError.unsupported }
        return snapshot
    }
    func getMessages(conversationID: String) async throws -> [Message] { [] }
    func getEvents(conversationID: String) async throws -> [AgentEvent] { [] }
    func registerTools(_ tools: [ClientToolInfo]) async {}
    func capabilities() async -> AgentCapabilityFlags { .default }
}
