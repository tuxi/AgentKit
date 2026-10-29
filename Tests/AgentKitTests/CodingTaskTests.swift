import Foundation
import XCTest
@testable import AgentKit

private struct TaskUIFixture: Decodable {
    let snapshot: CodingTaskSnapshot
    let event_page: CodingTaskEventPage
    let bundles: [String: CodingTaskReviewBundle]?
}

private func taskFixture(_ name: String = "managed") throws -> TaskUIFixture {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    return try JSONDecoder().decode(TaskUIFixture.self, from: Data(contentsOf: root.appendingPathComponent("Fixtures/coding-task/\(name).json")))
}

private actor TaskReaderFixture: CodingTaskReading {
    let fixture: TaskUIFixture
    var storeID: String
    var cursors: [String] = []
    var denied = false
    var resync = false
    var delay = false
    var failNext = false
    var snapshotOverride: CodingTaskSnapshot?
    init(_ fixture: TaskUIFixture) {
        self.fixture = fixture
        storeID = fixture.snapshot.managed_run?["store_id"]?.text ?? "store_example"
    }
    func changeStore() { storeID = "other-store" }
    func setDenied() { denied = true }
    func setDelay() { delay = true }
    func failOnce() { failNext = true }
    func requireResync() { resync = true }
    func overrideSnapshot(_ value: CodingTaskSnapshot) { snapshotOverride = value }
    func codingTaskCapabilities() async throws -> CodingTaskCapabilities {
        if failNext { failNext = false; throw URLError(.networkConnectionLost) }
        if denied { throw RuntimeHTTPError.unexpectedStatus(403, body: "denied") }
        return .init(server_id: fixture.snapshot.managed_run?["server_id"]?.text ?? "server_example", store_id: storeID, capabilities: ["task_timeline_v1", "task_review_gate_v1"])
    }
    func codingTasks() async throws -> [CodingTaskSummary] { [] }
    func codingTaskSnapshot(id: String) async throws -> CodingTaskSnapshot {
        if delay { try await Task.sleep(for: .milliseconds(100)) }
        return snapshotOverride ?? fixture.snapshot
    }
    func codingTaskEvents(id: String, after: String) async throws -> CodingTaskEventPage {
        cursors.append(after)
        if after == "0" { return fixture.event_page }
        return .init(task_id: id, after: after, next_cursor: after, events: [], has_more: false, resync_required: resync)
    }
    func codingTaskBundle(taskID: String, artifactID: String) async throws -> CodingTaskReviewBundle {
        guard let bundle = fixture.bundles?[artifactID] else { throw RuntimeHTTPError.notFound }
        return bundle
    }
}

@MainActor
final class CodingTaskTests: XCTestCase {
    func testManualFixtureRolesNullsAndRoundCount() throws {
        let f = try taskFixture("manual")
        XCTAssertEqual(f.snapshot.executionRounds, 1)
        XCTAssertNil(f.snapshot.usage); XCTAssertNil(f.snapshot.cost_usd); XCTAssertNil(f.snapshot.pending_attention)
        let planner = try XCTUnwrap(f.snapshot.participations.first { $0.role == "planner" })
        let reviewer = try XCTUnwrap(f.snapshot.participations.first { $0.role == "reviewer" })
        XCTAssertEqual(planner.session_ref.session_handle, reviewer.session_ref.session_handle)
        XCTAssertEqual(planner.observation_level, "reported")
        XCTAssertNil(planner.session_ref.localSession(in: .init(serverID: "server_example", storeID: "store_example")))
        let executor = try XCTUnwrap(f.snapshot.participations.first { $0.role == "executor" })
        XCTAssertNotNil(executor.session_ref.localSession(in: .init(serverID: "server_example", storeID: "store_example")))
        XCTAssertNil(executor.session_ref.localSession(in: .init(serverID: "server_example", storeID: "wrong-store")))
    }

    func testSessionNavigationKeepsArchivedExecutorMetadata() throws {
        let raw = """
        {"id":"old-executor","workspace_path":"/isolated/repo","name":"Executor","turn_count":2,"message_count":4,"created_at":"then","updated_at":"now","turn_status":"cancelled","execution_policy":"shared_workspace","workspace_id":"checkout-1","archived_at":"2026-10-29T00:00:00Z"}
        """
        let detail = try JSONDecoder().decode(ConversationDetail.self, from: Data(raw.utf8))
        let ref = try CodingTaskSessionNavigation.reference(detail)
        XCTAssertEqual(ref.id, "old-executor"); XCTAssertEqual(ref.workspaceID, "checkout-1")
        XCTAssertTrue(ref.isArchived); XCTAssertEqual(ref.turnStatus, "cancelled")
    }

    func testManagedFixtureHasRealTwoRoundReviewsAndFinalAcceptance() throws {
        let f = try taskFixture()
        XCTAssertEqual(f.snapshot.task_acceptance, "accepted")
        XCTAssertEqual(f.snapshot.executionRounds, 2)
        XCTAssertEqual(f.bundles?.count, 2)
        let reviews = f.event_page.events.filter { $0.kind == "review.recorded" }
        XCTAssertEqual(reviews.count, 2)
        XCTAssertEqual(Set(reviews.compactMap { $0.payload["review"]?["verdict"]?.text }), ["request_changes", "pass"])
        XCTAssertTrue(f.event_page.events.contains { $0.kind == "task.accepted" && $0.isSystem })
        XCTAssertTrue(f.event_page.events.filter { $0.kind == "review.gate_consumed" }.allSatisfy(\.isSystem))
    }

    func testHistoryDedupUnknownKindsLargeCursorsAndGaps() throws {
        let raw = """
        {"event_id":"e","task_id":"t","task_seq":"9007199254740993","task_revision":"1","recorded_at":"now","kind":"future.progress","payload":{"new":true}}
        """
        let event = try JSONDecoder().decode(CodingTaskEvent.self, from: Data(raw.utf8))
        var history = CodingTaskHistory()
        try history.append(.init(task_id: "t", after: "0", next_cursor: event.task_seq, events: [event, event], has_more: false, resync_required: false), taskID: "t")
        XCTAssertEqual(history.events.count, 1)
        XCTAssertEqual(history.events[0].kind, "future.progress")
        XCTAssertEqual(history.cursor, "9007199254740993")
        XCTAssertTrue(CodingTaskSequence.less("9007199254740992", history.cursor))
        XCTAssertFalse(CodingTaskSequence.less("0009", "9"))
        XCTAssertThrowsError(try history.append(.init(task_id: "t", after: history.cursor, next_cursor: history.cursor, events: [], has_more: true, resync_required: false), taskID: "t"))
        XCTAssertThrowsError(try history.append(.init(task_id: "other", after: history.cursor, next_cursor: history.cursor, events: [], has_more: false, resync_required: false), taskID: "t"))
    }

    func testFirstLoadReplaysOldReviewsAndReconnectUsesDelta() async throws {
        let f = try taskFixture(), reader = TaskReaderFixture(try taskFixture())
        let store = CodingTaskStore(reader: reader)
        store.select(f.snapshot.task_id)
        await store.refresh()
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.historyLoaded)
        XCTAssertEqual(store.snapshot?.task_acceptance, "accepted")
        XCTAssertEqual(store.history.events.filter { $0.kind == "review.recorded" }.count, 2)
        await store.refresh()
        let cursors = await reader.cursors
        XCTAssertEqual(cursors, ["0", f.event_page.next_cursor])
        XCTAssertEqual(store.history.events.count, f.event_page.events.count)
        let recreated = CodingTaskStore(reader: reader)
        recreated.select(f.snapshot.task_id)
        await recreated.refresh()
        XCTAssertEqual(recreated.history.events.count, store.history.events.count)
    }

    func testIdentityAndAuthorizationChangesClearReadState() async throws {
        let f = try taskFixture(), reader = TaskReaderFixture(try taskFixture())
        let store = CodingTaskStore(reader: reader)
        store.select(f.snapshot.task_id); await store.refresh()
        await reader.changeStore(); await store.refresh()
        XCTAssertNil(store.snapshot); XCTAssertNil(store.selectedID); XCTAssertTrue(store.history.events.isEmpty)
        XCTAssertNotNil(store.errorMessage)
        await reader.setDenied(); await store.refresh()
        XCTAssertTrue(store.errorMessage?.contains("owner") == true)
        XCTAssertTrue(store.tasks.isEmpty)
    }

    func testSelectionChangeDiscardsLateResponse() async throws {
        let f = try taskFixture(), reader = TaskReaderFixture(try taskFixture())
        let store = CodingTaskStore(reader: reader)
        store.select(f.snapshot.task_id); await reader.setDelay()
        let request = Task { await store.refresh() }
        try await Task.sleep(for: .milliseconds(20))
        store.select("another-task")
        await request.value
        XCTAssertNil(store.snapshot); XCTAssertTrue(store.history.events.isEmpty)
        XCTAssertEqual(store.selectedID, "another-task")
    }

    func testFrozenFirstReviewRemainsFirstAfterSecondEdit() async throws {
        let f = try taskFixture(), reader = TaskReaderFixture(try taskFixture())
        let store = CodingTaskStore(reader: reader)
        store.select(f.snapshot.task_id); await store.refresh()
        let refs = f.snapshot.artifact_refs.filter { $0.kind == "review_bundle" }
        let first = try XCTUnwrap(refs.first), second = try XCTUnwrap(refs.last)
        let one = try await store.bundle(for: first), two = try await store.bundle(for: second)
        XCTAssertEqual(one.iteration, 1); XCTAssertEqual(two.iteration, 2)
        XCTAssertNotEqual(one.candidate.files?.first?.data, two.candidate.files?.first?.data)
        XCTAssertEqual(one.baseline.files?.first?.text, "baseline\n")
        await reader.changeStore()
        do { _ = try await store.bundle(for: first); XCTFail("cross-store bundle accepted") } catch {}
    }

    func testNetworkFailureRetainsCursorAndResyncRebuildsHistory() async throws {
        let f = try taskFixture(), reader = TaskReaderFixture(try taskFixture())
        let store = CodingTaskStore(reader: reader)
        store.select(f.snapshot.task_id); await store.refresh()
        let count = store.history.events.count
        await reader.failOnce(); await store.refresh()
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.history.cursor, f.event_page.next_cursor)
        await store.refresh()
        XCTAssertNil(store.errorMessage); XCTAssertEqual(store.history.events.count, count)
        await reader.requireResync(); await store.refresh()
        XCTAssertFalse(store.historyLoaded); XCTAssertEqual(store.history.cursor, "0")
        await store.refresh()
        XCTAssertTrue(store.historyLoaded); XCTAssertEqual(store.history.events.count, count)
    }

    func testCancelledReadDoesNotPublishSnapshot() async throws {
        let f = try taskFixture(), reader = TaskReaderFixture(try taskFixture())
        let store = CodingTaskStore(reader: reader)
        store.select(f.snapshot.task_id); await reader.setDelay()
        let request = Task { await store.refresh() }
        try await Task.sleep(for: .milliseconds(20)); request.cancel(); await request.value
        XCTAssertNil(store.snapshot); XCTAssertFalse(store.historyLoaded); XCTAssertNil(store.errorMessage)
    }

    func testInvalidationAndRecoveryDoNotInheritHistoricalPass() async throws {
        let f = try taskFixture(), reader = TaskReaderFixture(try taskFixture())
        let store = CodingTaskStore(reader: reader)
        store.select(f.snapshot.task_id); await store.refresh()
        for reason in ["candidate_invalidated", "recovery_required", "needs_validation"] {
            var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(f.snapshot)) as? [String: Any])
            raw["state"] = "waiting"; raw["wait_reason"] = reason
            raw["task_acceptance"] = "not_reviewed"
            raw["revision"] = "999999"
            let next = try JSONDecoder().decode(CodingTaskSnapshot.self, from: JSONSerialization.data(withJSONObject: raw))
            await reader.overrideSnapshot(next); await store.refresh()
            XCTAssertEqual(store.snapshot?.task_acceptance, "not_reviewed")
            XCTAssertEqual(store.snapshot?.wait_reason, reason)
            XCTAssertEqual(store.history.events.filter { $0.payload["review"]?["verdict"]?.text == "pass" }.count, 2)
        }
        await reader.overrideSnapshot(f.snapshot); await store.refresh()
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.snapshot?.revision, "999999")
    }
}
