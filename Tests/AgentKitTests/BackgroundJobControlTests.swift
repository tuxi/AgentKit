import Foundation
import XCTest
@testable import AgentKit
#if os(macOS)
import AppKit
import SwiftUI
#endif

private func job(_ id: String = "job_fixture", turn: String = "turn", status: BackgroundJobStatus = .running,
                 cancel: Bool = false) -> BackgroundJobSnapshot {
    .init(jobID: id, sessionID: "session", turnID: turn, callID: "call_\(id)", command: "python3 worker.py",
          status: status, durationMs: 4200, cancelRequested: cancel, outputTail: "Ready\nProcessing 12 records…")
}
private actor JobFixture {
    var origin = "http://localhost:1234"
    var jobs = [job(), job("job_second", turn: "older-turn")]
    var supported = true
    var fail = false
    var reads = 0
    var canceled: [BackgroundJobOwner] = []
    var holdRead = false
    var held: CheckedContinuation<[BackgroundJobSnapshot], Error>?
    var holdCancel = false
    var cancels: [String: CheckedContinuation<BackgroundJobSnapshot, Error>] = [:]
    func identity() -> String { origin }
    func capabilities() -> RuntimeCapabilitySnapshot { .init(capabilities: ["background_job_control_v1": supported]) }
    func list() async throws -> [BackgroundJobSnapshot] {
        reads += 1
        if fail { throw URLError(.notConnectedToInternet) }
        if holdRead { return try await withCheckedThrowingContinuation { held = $0 } }
        return jobs
    }
    func stop(_ owner: BackgroundJobOwner) async throws -> BackgroundJobSnapshot {
        canceled.append(owner)
        if holdCancel { return try await withCheckedThrowingContinuation { cancels[owner.jobID] = $0 } }
        let pending = job(owner.jobID, status: .running, cancel: true)
        jobs = jobs.map { $0.owner == owner ? pending : $0 }
        return pending
    }
    func configure(origin: String? = nil, supported: Bool? = nil, fail: Bool? = nil, jobs: [BackgroundJobSnapshot]? = nil,
                   holdRead: Bool? = nil, holdCancel: Bool? = nil) {
        if let origin { self.origin = origin }; if let supported { self.supported = supported }
        if let fail { self.fail = fail }; if let jobs { self.jobs = jobs }
        if let holdRead { self.holdRead = holdRead }; if let holdCancel { self.holdCancel = holdCancel }
    }
    func releaseRead(_ result: [BackgroundJobSnapshot]) { held?.resume(returning: result); held = nil; holdRead = false }
    func releaseCancel(_ value: BackgroundJobSnapshot) { cancels.removeValue(forKey: value.jobID)?.resume(returning: value) }
    func hasRead() -> Bool { held != nil }
    func cancelCount() -> Int { canceled.count }
    func readCount() -> Int { reads }
    nonisolated var operations: BackgroundJobOperations {
        .init(identity: { await self.identity() }, capabilities: { await self.capabilities() },
              list: { _, _ in try await self.list() }, cancel: { _, owner, _ in try await self.stop(owner) })
    }
}

@MainActor
final class BackgroundJobsModelTests: XCTestCase {
    private func wait(_ condition: () async -> Bool) async {
        for _ in 0..<200 { if await condition() { return }; try? await Task.sleep(for: .milliseconds(2)) }
        XCTFail("fixture did not reach expected state")
    }
    func testStop202RemainsRunningUntilAuthoritativeTerminal() async {
        let fixture = JobFixture(); let model = BackgroundJobsModel(operations: fixture.operations)
        model.select("session"); await model.refresh()
        XCTAssertEqual(model.runningCount, 2)
        await model.stop(job().owner)
        XCTAssertEqual(model.jobs.first?.status, .running)
        XCTAssertEqual(model.jobs.first?.cancelRequested, true)
        XCTAssertEqual(model.runningCount, 2)
        await fixture.configure(jobs: [job(status: .canceled), job("job_second", turn: "older-turn")])
        await model.refresh()
        XCTAssertEqual(model.runningCount, 1)
        XCTAssertEqual(model.jobs.first?.status, .canceled)
    }
    func testMultipleStopsAreIndependentAndCannotDuplicate() async {
        let fixture = JobFixture(); let model = BackgroundJobsModel(operations: fixture.operations)
        model.select("session"); await model.refresh(); await fixture.configure(holdCancel: true)
        let first = Task { await model.stop(job().owner) }
        let secondOwner = job("job_second", turn: "older-turn").owner
        let second = Task { await model.stop(secondOwner) }
        await wait { await fixture.cancelCount() == 2 }
        await model.stop(job().owner)
        XCTAssertEqual(model.stopping.count, 2)
        let canceledCount = await fixture.cancelCount(); XCTAssertEqual(canceledCount, 2)
        await fixture.releaseCancel(job(status: .canceled)); await first.value
        XCTAssertEqual(model.jobs.first?.status, .canceled)
        XCTAssertTrue(model.stopping.contains(secondOwner))
        await fixture.configure(jobs: [job(status: .canceled), job("job_second", turn: "older-turn", status: .exited)])
        await fixture.releaseCancel(job("job_second", turn: "older-turn", status: .exited)); await second.value
        XCTAssertEqual(model.runningCount, 0)
    }
    func testLateListCannotOverwriteStopResponse() async {
        let fixture = JobFixture(); let model = BackgroundJobsModel(operations: fixture.operations)
        model.select("session"); await model.refresh(); await fixture.configure(holdRead: true, holdCancel: true)
        let oldRead = Task { await model.refresh() }; await wait { await fixture.hasRead() }
        let stop = Task { await model.stop(job().owner) }; await wait { await fixture.cancelCount() == 1 }
        await fixture.releaseRead([job()]); await oldRead.value
        XCTAssertEqual(model.stopping.count, 1)
        await fixture.configure(jobs: [job(status: .canceled)])
        await fixture.releaseCancel(job(status: .canceled)); await stop.value
        XCTAssertEqual(model.jobs.first?.status, .canceled)
    }
    func testConversationSwitchIgnoresInflightRead() async {
        let fixture = JobFixture(); let model = BackgroundJobsModel(operations: fixture.operations)
        model.select("session"); await fixture.configure(holdRead: true)
        let refresh = Task { await model.refresh() }; await wait { await fixture.hasRead() }
        model.select("other"); await fixture.releaseRead([job()]); await refresh.value
        XCTAssertTrue(model.jobs.isEmpty); XCTAssertEqual(model.conversationID, "other")
    }
    func testRuntimeSwitchDuringCancelDoesNotApplyOldResponse() async {
        let fixture = JobFixture(); let model = BackgroundJobsModel(operations: fixture.operations)
        model.select("session"); await model.refresh(); await fixture.configure(holdCancel: true)
        let stop = Task { await model.stop(job().owner) }; await wait { await fixture.cancelCount() == 1 }
        await fixture.configure(origin: "http://localhost:4321", jobs: [])
        await fixture.releaseCancel(job(status: .canceled)); await stop.value
        XCTAssertTrue(model.isStale); XCTAssertNotEqual(model.jobs.first?.status, .canceled)
        await model.refresh()
        XCTAssertTrue(model.jobs.isEmpty); XCTAssertEqual(model.runtimeIdentity, "http://localhost:4321")
    }
    func testUnsupportedAndNetworkLossHaveNoFakeTerminalState() async {
        let fixture = JobFixture(); let model = BackgroundJobsModel(operations: fixture.operations)
        model.select("session"); await fixture.configure(supported: false); await model.refresh()
        XCTAssertEqual(model.support, .unsupported); XCTAssertFalse(model.canControl)
        let reads = await fixture.readCount(); XCTAssertEqual(reads, 0)
        await fixture.configure(supported: true); await model.refresh(rediscover: true)
        await fixture.configure(fail: true); await model.refresh()
        XCTAssertTrue(model.isStale); XCTAssertFalse(model.canControl)
        XCTAssertEqual(model.jobs.first?.status, .running)
        let count = await fixture.cancelCount(); await model.stop(job().owner)
        let after = await fixture.cancelCount(); XCTAssertEqual(count, after)
    }
    func testPollingOnlyWhileVisibleAndStopsAfterFailure() async {
        let fixture = JobFixture(); let model = BackgroundJobsModel(operations: fixture.operations, pollInterval: .milliseconds(20))
        model.select("session"); await model.refresh()
        try? await Task.sleep(for: .milliseconds(60))
        let hidden = await fixture.readCount(); XCTAssertEqual(hidden, 1)
        await fixture.configure(fail: true)
        model.setVisible(true)
        await wait { model.isStale }
        let failed = await fixture.readCount(); XCTAssertEqual(failed, 2)
        try? await Task.sleep(for: .milliseconds(60))
        let stopped = await fixture.readCount(); XCTAssertEqual(stopped, 2)
        model.setVisible(false)
    }
    #if os(macOS)
    func testNativePanelFixture() async throws {
        let fixture = JobFixture(); let model = BackgroundJobsModel(operations: fixture.operations)
        model.select("session"); await model.refresh()
        let view = NSHostingView(rootView: BackgroundJobsPanel(model: model, onLogs: { _ in }).frame(width: 520, height: 440))
        view.frame = .init(x: 0, y: 0, width: 520, height: 440)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            view.appearance = NSAppearance(named: appearance)
            window.appearance = view.appearance
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/agentkit-background-jobs-\(name).png"))
        }
    }
    #endif
}

final class BackgroundJobReconciliationTests: XCTestCase {
    func testTurnCancelAndFailureLeaveJobsRunningUntilOwnTerminal() async {
        for mode in 0..<3 {
            var reducer = ExecutionReducer(); var graph = ExecutionGraph()
            _ = reducer.reduce(.turnStarted(turnID: "turn", text: "work"), into: &graph)
            _ = reducer.reduce(.jobStarted(turnID: "turn", jobID: "job_fixture", callID: "call_job_fixture", command: "worker"), into: &graph)
            switch mode {
            case 0: reducer.cancelActiveTurn(turnID: "turn", graph: &graph)
            case 1: _ = reducer.reduce(.turnCancelled(turnID: "turn", reason: "user"), into: &graph)
            default: _ = reducer.reduce(.turnFailed(turnID: "turn", text: "error", err: nil, errorCode: nil), into: &graph)
            }
            XCTAssertEqual(graph.nodes["sub_job_fixture"]?.status, .running)
            _ = reducer.reduce(.jobFinished(turnID: "turn", jobID: "job_fixture", exitCode: nil, err: nil, elapsedMs: 42, text: "canceled"), into: &graph)
            guard case .childStream(let payload) = graph.nodes["sub_job_fixture"]?.payload else { return XCTFail("missing job") }
            XCTAssertTrue(payload.canceled)
        }
    }
    func testMissingRegistryJobIsUnavailableAndSnapshotCanConfirmTerminal() async {
        let engine = RuntimeEngine(sessionID: "session")
        await engine.ingest(.turnStarted(turnID: "turn", text: "work"))
        await engine.ingest(.jobStarted(turnID: "turn", jobID: "job_fixture", callID: "call_job_fixture", command: "worker"))
        await engine.cancelActiveTurn()
        await engine.reconcileBackgroundJobs([])
        let snap = await engine.currentSnapshot()
        let child = snap.timeline.compactMap { node -> ChildStreamNodePayload? in
            if case .childStream(let value) = node.kind { return value }; return nil
        }.first
        XCTAssertEqual(child?.status, .unavailable)
        await engine.reconcileBackgroundJobs([job(status: .canceled)])
        let terminal = await engine.currentSnapshot().timeline.compactMap { node -> ChildStreamNodePayload? in
            if case .childStream(let value) = node.kind { return value }; return nil
        }.first
        XCTAssertEqual(terminal?.status, .canceled)
    }
}
