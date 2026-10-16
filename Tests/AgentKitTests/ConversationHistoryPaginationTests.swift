import Foundation
import XCTest
@testable import AgentKit

private final class EventPageURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { return }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ConversationHistoryPaginationTests: XCTestCase {
    func testConversationListPageUsesOpaqueCursorAndServerHeaders() async throws {
        EventPageURLProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            XCTAssertTrue(query.contains { $0.name == "limit" && $0.value == "100" })
            XCTAssertTrue(query.contains { $0.name == "before" && $0.value == "opaque-cursor" })
            XCTAssertTrue(query.contains { $0.name == "archived" && $0.value == "false" })
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["X-Codeagent-Has-More": "1", "X-Codeagent-Next-Cursor": "next-cursor"])!
            return (response, Data(#"{"code":0,"msg":"ok","data":[{"id":"one","workspace_path":"/tmp"}]}"#.utf8))
        }
        let page = try await makeClient().listConversationPage(archived: false, limit: 100, before: "opaque-cursor")
        XCTAssertEqual(page.conversations.map(\.id), ["one"])
        XCTAssertEqual(page.nextCursor, "next-cursor")
        XCTAssertTrue(page.hasMore)
        XCTAssertTrue(page.isPaged)
    }

    func testConversationListWithoutHeadersRemainsUnpaged() async throws {
        EventPageURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!,
             Data(#"{"code":0,"msg":"ok","data":[]}"#.utf8))
        }
        let page = try await makeClient().listConversationPage(archived: false, limit: 100, before: nil)
        XCTAssertFalse(page.isPaged)
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.nextCursor)
    }

    func testOlderLoaderJoinsAllFragmentsBeforePublishingPage() async throws {
        let pages: [Int: AgentEventBatch] = [
            100: AgentEventBatch(events: [.assistantText(turnID: "large", text: "tail")],
                                 nextSince: 90, oldestSeq: 80, hasMoreOlder: true,
                                 replayTruncated: true, turnFragment: true),
            80: AgentEventBatch(events: [.assistantText(turnID: "large", text: "middle")],
                                nextSince: 79, oldestSeq: 60, hasMoreOlder: true,
                                replayTruncated: true, turnFragment: true),
            60: AgentEventBatch(events: [
                .turnStarted(turnID: "large", text: "prompt"),
                .assistantText(turnID: "large", text: "head")],
                nextSince: 59, oldestSeq: 20, hasMoreOlder: true, turnFragment: false),
        ]
        let page = try await ConversationHistoryPager.load(before: 100) { cursor in
            guard let batch = pages[cursor] else { throw RuntimeHTTPError.invalidResponse }
            return batch
        }
        XCTAssertEqual(page.oldestSeq, 20)
        XCTAssertTrue(page.hasMoreOlder)
        XCTAssertFalse(page.isIncomplete)
        let order = page.events.compactMap { event -> String? in
            switch event {
            case .turnStarted: return "start"
            case .assistantText(_, let text): return text
            default: return nil
            }
        }
        XCTAssertEqual(order, ["start", "head", "middle", "tail"])
    }

    func testOlderLoaderRejectsNonAdvancingCursor() async {
        do {
            _ = try await ConversationHistoryPager.load(before: 100) { _ in
                AgentEventBatch(events: [], nextSince: 0, oldestSeq: 100,
                                hasMoreOlder: true, turnFragment: true)
            }
            XCTFail("expected invalid response")
        } catch {
            XCTAssertTrue(error is RuntimeHTTPError)
        }
    }

    func testTailForwardCursorUsesMaximumRawSequenceAcrossGaps() throws {
        let frames = try JSONDecoder().decode([WireFrame].self, from: Data(
            #"[{"kind":"turn_started","turn_id":"t1","seq":41},{"kind":"future_kind","seq":97}]"#.utf8))
        let batch = CodeAgentTransport.batch(from: frames, since: 0,
                                             oldestSeq: 41, hasMoreOlder: true)
        XCTAssertEqual(batch.nextSince, 97)
        XCTAssertEqual(batch.oldestSeq, 41)
        XCTAssertTrue(batch.hasMoreOlder)
        XCTAssertEqual(batch.events.count, 1)
    }

    private func makeClient() -> RuntimeHTTPClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EventPageURLProtocol.self]
        return RuntimeHTTPClient(
            environment: RuntimeEnvironment(host: "127.0.0.1", port: 8797),
            session: URLSession(configuration: config))
    }

    func testTailAndOlderPageUseHeadersAndExclusiveCursor() async throws {
        EventPageURLProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            let isTail = query.contains { $0.name == "tail" && $0.value == "200" }
            if !isTail {
                XCTAssertTrue(query.contains { $0.name == "before" && $0.value == "41" })
                XCTAssertTrue(query.contains { $0.name == "limit" && $0.value == "200" })
            }
            let headers = ["X-Codeagent-Oldest-Seq": isTail ? "41" : "12",
                           "X-Codeagent-Has-More-Older": isTail ? "1" : "0",
                           "X-Codeagent-Turn-Fragment": isTail ? "1" : "0"]
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: headers)!
            let data = try! JSONSerialization.data(withJSONObject: ["code": 0, "msg": "success", "data": [["kind": "turn_started", "seq": isTail ? 41 : 12]]])
            return (response, data)
        }
        let client = makeClient()
        let tail = try await client.getEventPage(conversationID: "c", tail: 200)
        XCTAssertEqual(tail.oldestSeq, 41)
        XCTAssertTrue(tail.hasMoreOlder)
        XCTAssertTrue(tail.turnFragment)
        XCTAssertEqual(tail.frames.first?.seq, 41)
        let older = try await client.getEventPage(conversationID: "c", before: 41, limit: 200)
        XCTAssertEqual(older.oldestSeq, 12)
        XCTAssertFalse(older.hasMoreOlder)
        XCTAssertFalse(older.turnFragment)
    }

    func testOldServerWithoutHeadersCannotEnableOlderPaging() async throws {
        EventPageURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil,
                                           headerFields: ["X-Codeagent-Replay-Truncated": "1"])!
            return (response, Data(#"{"code":0,"msg":"success","data":[]}"#.utf8))
        }
        let page = try await makeClient().getEventPage(conversationID: "c", tail: 200)
        XCTAssertNil(page.oldestSeq)
        XCTAssertFalse(page.hasMoreOlder)
        XCTAssertTrue(page.replayTruncated)
    }
}
