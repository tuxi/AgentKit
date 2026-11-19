import Foundation
import XCTest
@testable import AgentKit

private actor SupplementClientFixture: TextSupplementClient {
    var identity = "runtime-A"
    var enabled = true
    var lostResponse = false
    var holdResponse = false
    var state = "pending_apply"
    var sent: [TextSupplementRequest] = []
    var queries = 0
    var queryFails = false
    func failQueries() { queryFails = true }
    var continuation: CheckedContinuation<TextSupplementReceipt, Error>?
    func configure(identity: String? = nil, enabled: Bool? = nil, lost: Bool? = nil, hold: Bool? = nil, state: String? = nil) {
        if let identity { self.identity = identity }; if let enabled { self.enabled = enabled }
        if let lost { lostResponse = lost }; if let hold { holdResponse = hold }; if let state { self.state = state }
    }
    func runtimeCapabilities() async throws -> RuntimeCapabilitySnapshot { .init(capabilities: ["user_supplement_text_v1": enabled]) }
    func backgroundJobRuntimeIdentity() async throws -> String { identity }
    func receipt(_ request: TextSupplementRequest) -> TextSupplementReceipt {
        .init(input: .init(sessionID: "s", requestID: request.requestID, expectedTurnID: request.expectedTurnID, text: request.text), sequence: 7, state: state)
    }
    func submitTextSupplement(sessionID: String, request: TextSupplementRequest, runtimeIdentity: String) async throws -> TextSupplementReceipt {
        sent.append(request)
        if lostResponse { throw URLError(.networkConnectionLost) }
        if holdResponse { return try await withCheckedThrowingContinuation { continuation = $0 } }
        return receipt(request)
    }
    func release() { continuation?.resume(returning: receipt(sent[0])); continuation = nil }
    func queryTextSupplement(sessionID: String, requestID: String, runtimeIdentity: String) async throws -> TextSupplementReceipt {
        queries += 1
        if queryFails { throw URLError(.networkConnectionLost) }
        return receipt(sent[0])
    }
}

final class TextSupplementDeliveryTests: XCTestCase {
    func testCancelledReceiptIsRetainedWithoutResubmission() async throws {
        let client = SupplementClientFixture()
        let store = InMemoryConversationLocalStateStore()
        let coordinator = TextSupplementDeliveryCoordinator(client: client, store: store)
        try await coordinator.submit(sessionID: "s", request: .init(requestID: "cancelled", expectedTurnID: "t", text: "保留原文"))
        await client.configure(state: "cancelled")
        let confirmed = try await coordinator.recover(sessionID: "s")
        XCTAssertTrue(confirmed)
        let record = try XCTUnwrap(store.state(for: .session("s"))?.textSupplementDeliveries.first)
        XCTAssertEqual(record.state, "cancelled")
        XCTAssertEqual(record.request.text, "保留原文")
        let sends = await client.sent
        XCTAssertEqual(sends.count, 1)
        #if os(macOS)
        XCTAssertTrue(SupplementStatusPresentation.canRestore(record.state))
        XCTAssertFalse(SupplementStatusPresentation.canRestore("unconfirmed"))
        XCTAssertFalse(SupplementStatusPresentation.canRestore("future_state"))
        #endif
    }

    func testFailedQueryPreservesUnknownRequestAndReportsIncomplete() async throws {
        let client = SupplementClientFixture()
        let store = InMemoryConversationLocalStateStore()
        let coordinator = TextSupplementDeliveryCoordinator(client: client, store: store)
        await client.configure(lost: true)
        try? await coordinator.submit(sessionID: "s", request: .init(requestID: "uncertain", expectedTurnID: "t", text: "待确认原文"))
        await client.failQueries()
        let confirmed = try await coordinator.recover(sessionID: "s")
        XCTAssertFalse(confirmed)
        let record = try XCTUnwrap(store.state(for: .session("s"))?.textSupplementDeliveries.first)
        XCTAssertTrue(record.needsConfirmation)
        XCTAssertEqual(record.request.requestID, "uncertain")
        let sends = await client.sent
        XCTAssertEqual(sends.count, 1)
    }

    func testRuntimeChangeLeavesQueryIncomplete() async throws {
        let client = SupplementClientFixture()
        let store = InMemoryConversationLocalStateStore()
        let coordinator = TextSupplementDeliveryCoordinator(client: client, store: store)
        try await coordinator.submit(sessionID: "s", request: .init(requestID: "pending", expectedTurnID: "t", text: "原消息"))
        await client.configure(identity: "another-runtime")
        let confirmed = try await coordinator.recover(sessionID: "s")
        XCTAssertFalse(confirmed)
        XCTAssertEqual(try store.state(for: .session("s"))?.textSupplementDeliveries.first?.state, "pending_apply")
        let queries = await client.queries
        XCTAssertEqual(queries, 0)
    }

    func testLostResponseRecoversByQueryWithoutResubmitting() async throws {
        let client = SupplementClientFixture(); await client.configure(lost: true)
        let store = InMemoryConversationLocalStateStore()
        let coordinator = TextSupplementDeliveryCoordinator(client: client, store: store)
        let request = TextSupplementRequest(requestID: "r", expectedTurnID: "t", text: "keep this")
        do { try await coordinator.submit(sessionID: "s", request: request); XCTFail("response should be lost") } catch {}
        XCTAssertEqual(try store.state(for: .session("s"))?.textSupplementDeliveries.first?.state, "unconfirmed")
        await client.configure(state: "applied")
        let recovered = TextSupplementDeliveryCoordinator(client: client, store: store)
        try await recovered.recover(sessionID: "s")
        let sends = await client.sent; let queries = await client.queries
        XCTAssertEqual(sends.map(\.requestID), ["r"]); XCTAssertEqual(queries, 1)
        XCTAssertEqual(try store.state(for: .session("s"))?.textSupplementDeliveries.first?.state, "applied")
    }
    func testDifferentRuntimeAndUnsupportedCapabilityDoNotSend() async throws {
        let client = SupplementClientFixture(); await client.configure(lost: true)
        let store = InMemoryConversationLocalStateStore(); let coordinator = TextSupplementDeliveryCoordinator(client: client, store: store)
        let request = TextSupplementRequest(requestID: "r", expectedTurnID: "t", text: "keep")
        try? await coordinator.submit(sessionID: "s", request: request)
        await client.configure(identity: "runtime-B")
        try await coordinator.recover(sessionID: "s")
        let queries = await client.queries; XCTAssertEqual(queries, 0)
        await client.configure(enabled: false)
        do { try await coordinator.submit(sessionID: "s", request: .init(expectedTurnID: "t", text: "new")); XCTFail("unsupported") } catch {}
        let sends = await client.sent; XCTAssertEqual(sends.count, 1)
    }
    func testAppliedEventWinsOverLateHTTPAcceptance() async throws {
        let client = SupplementClientFixture(); await client.configure(hold: true)
        let store = InMemoryConversationLocalStateStore(); let coordinator = TextSupplementDeliveryCoordinator(client: client, store: store)
        let sending = Task { try await coordinator.submit(sessionID: "s", request: .init(requestID: "r", expectedTurnID: "t", text: "keep")) }
        for _ in 0..<200 { if await client.continuation != nil { break }; try await Task.sleep(for: .milliseconds(5)) }
        try await coordinator.apply(.init(requestID: "r", turnID: "t", sequence: 7, appliedAt: "2026-11-18T00:00:00Z"), sessionID: "s")
        await client.release(); try await sending.value
        XCTAssertEqual(try store.state(for: .session("s"))?.textSupplementDeliveries.first?.state, "applied")
    }
    func testSQLiteReopenRecoversOriginalRequestByQuery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite")
        let store = SQLiteConversationLocalStateStore(databaseURL: url)
        let client = SupplementClientFixture(); await client.configure(lost: true)
        let coordinator = TextSupplementDeliveryCoordinator(client: client, store: store)
        try? await coordinator.submit(sessionID: "s", request: .init(requestID: "persisted", expectedTurnID: "t", text: "keep"))
        try store.flush()
        let reopened = SQLiteConversationLocalStateStore(databaseURL: url)
        XCTAssertEqual(try reopened.state(for: .session("s"))?.textSupplementDeliveries.first?.request.requestID, "persisted")
        await client.configure(state: "applied")
        try await TextSupplementDeliveryCoordinator(client: client, store: reopened).recover(sessionID: "s")
        XCTAssertEqual(try reopened.state(for: .session("s"))?.textSupplementDeliveries.first?.state, "applied")
        let sends = await client.sent; XCTAssertEqual(sends.count, 1)
    }

    func testUnknownStateIsRetainedAndWireIdentityMustMatch() async throws {
        let client = SupplementClientFixture(); await client.configure(state: "future_state")
        let store = InMemoryConversationLocalStateStore(); let coordinator = TextSupplementDeliveryCoordinator(client: client, store: store)
        try await coordinator.submit(sessionID: "s", request: .init(requestID: "r", expectedTurnID: "t", text: "keep"))
        XCTAssertEqual(try store.state(for: .session("s"))?.textSupplementDeliveries.first?.state, "future_state")
        let json = #"{"kind":"user_supplement_applied","turn_id":"t","request_id":"r","seq":20,"supplement_application":{"request_id":"r","turn_id":"t","sequence":7,"applied_at":"2026-11-18T00:00:00Z"}}"#
        let wire = try JSONDecoder().decode(WireFrame.self, from: Data(json.utf8))
        guard case .supplementApplied(let receipt) = AgentEvent.from(wire: wire) else { return XCTFail("missing application") }
        XCTAssertEqual(receipt.sequence, 7)
        let invalid = json.replacingOccurrences(of: #""request_id":"r","seq""#, with: #""request_id":"other","seq""#)
        XCTAssertNil(AgentEvent.from(wire: try JSONDecoder().decode(WireFrame.self, from: Data(invalid.utf8))))
    }
}
