//
//  ChildStreamTests.swift
//  AgentKitTests
//
//  P8.7 — job_started/job_output/job_finished 解码、reducer 生命周期、
//  入口卡投影与 fixture transport。见 docs/p8.7-client-plan.md。
//

import XCTest
@testable import AgentKit

final class ChildStreamTests: XCTestCase {

    // MARK: - Helpers

    private func decodeEvent(_ json: String) throws -> AgentEvent? {
        let frame = try JSONDecoder().decode(WireFrame.self, from: Data(json.utf8))
        return AgentEvent.from(wire: frame)
    }

    private func childNode(_ graph: ExecutionGraph, id: String) -> (GraphNode, ChildStreamPayload)? {
        guard let node = graph.nodes["sub_\(id)"],
              case .childStream(let payload) = node.payload else { return nil }
        return (node, payload)
    }

    // MARK: - Wire decode（线格式按 §8.4 决策点 1 暂定：子流 id 复用 session_id）

    func testDecodeJobStarted() throws {
        let event = try decodeEvent(
            #"{"kind":"job_started","at":"2026-07-02T10:00:00.000Z","session_id":"job_1","turn_id":"t1","text":"npx skills add okx/onchainos-skills"}"#
        )
        guard case .jobStarted(let turnID, let jobID, let command)? = event else {
            return XCTFail("expected jobStarted, got \(String(describing: event))")
        }
        XCTAssertEqual(turnID, "t1")
        XCTAssertEqual(jobID, "job_1")
        XCTAssertEqual(command, "npx skills add okx/onchainos-skills")
    }

    func testDecodeJobOutput() throws {
        let event = try decodeEvent(
            #"{"kind":"job_output","at":"2026-07-02T10:00:01.000Z","session_id":"job_1","chunk":"Cloning...\n"}"#
        )
        guard case .jobOutput(_, let jobID, let chunk)? = event else {
            return XCTFail("expected jobOutput")
        }
        XCTAssertEqual(jobID, "job_1")
        XCTAssertEqual(chunk, "Cloning...\n")
    }

    // §8.5 golden 冻结形状：失败带结构化 exit_code + 冗余 err，text 是状态枚举。
    func testDecodeJobFinishedFrozenShape() throws {
        let event = try decodeEvent(
            #"{"kind":"job_finished","at":"2026-07-02T10:05:00.000Z","seq":42,"session_id":"job_1","text":"failed","exit_code":2,"err":"exit code 2"}"#
        )
        guard case .jobFinished(_, let jobID, let exitCode, let err, _, let text)? = event else {
            return XCTFail("expected jobFinished")
        }
        XCTAssertEqual(jobID, "job_1")
        XCTAssertEqual(exitCode, 2)
        XCTAssertEqual(err, "exit code 2")
        XCTAssertEqual(text, "failed")
    }

    // 成功形状：exit_code omitempty 省略，text=="exited" 即退出码 0。
    func testDecodeJobFinishedSuccessOmitsExitCode() throws {
        let event = try decodeEvent(
            #"{"kind":"job_finished","at":"2026-07-02T10:05:00.000Z","seq":43,"session_id":"job_1","text":"exited"}"#
        )
        guard case .jobFinished(_, _, let exitCode, let err, _, let text)? = event else {
            return XCTFail("expected jobFinished")
        }
        XCTAssertNil(exitCode)
        XCTAssertNil(err)
        XCTAssertEqual(text, "exited")
    }

    // 前向兼容底线：未知 kind → nil，不崩（client_integration_v1.md §5.5）。
    func testUnknownKindIsDropped() throws {
        let event = try decodeEvent(
            #"{"kind":"job_teleported","at":"2026-07-02T10:00:00.000Z","session_id":"job_1"}"#
        )
        XCTAssertNil(event)
    }

    // MARK: - Golden 契约（Tests/AgentKitTests/Fixtures/job-observability/，
    // 原样复制自 code-agent internal/server/testdata/*.json，后端 CI diff 锁定。
    // 注意：不能放 docs/protocols/fixtures/ —— 那里会被后端文档镜像同步冲掉。）

    func testGoldenJobStarted() throws {
        let event = AgentEvent.from(wire: try goldenFrame("job_started.json"))
        guard case .jobStarted(_, let jobID, let command)? = event else {
            return XCTFail("golden job_started must decode")
        }
        XCTAssertEqual(jobID, "job_1")
        XCTAssertEqual(command, "npx skills add okx/onchainos-skills --yes -g")
    }

    func testGoldenJobOutput() throws {
        let event = AgentEvent.from(wire: try goldenFrame("job_output.json"))
        guard case .jobOutput(_, let jobID, let chunk)? = event else {
            return XCTFail("golden job_output must decode")
        }
        XCTAssertEqual(jobID, "job_1")
        XCTAssertEqual(chunk, "Cloning repository...\n")
    }

    func testGoldenJobFinished() throws {
        let event = AgentEvent.from(wire: try goldenFrame("job_finished.json"))
        guard case .jobFinished(_, let jobID, let exitCode, let err, let elapsedMs, let text)? = event else {
            return XCTFail("golden job_finished must decode")
        }
        XCTAssertEqual(jobID, "job_1")
        XCTAssertEqual(text, "failed")
        XCTAssertEqual(exitCode, 2)
        XCTAssertEqual(err, "exit code 2")
        XCTAssertEqual(elapsedMs, 93000)
    }

    private func goldenFrame(_ name: String) throws -> WireFrame {
        let data = try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/job-observability")
            .appendingPathComponent(name))
        return try JSONDecoder().decode(WireFrame.self, from: data)
    }

    // MARK: - Reducer: job 生命周期

    func testJobLifecycleHappyPath() {
        var reducer = ExecutionReducer()
        var graph = ExecutionGraph()

        _ = reducer.reduce(.jobStarted(turnID: "t1", jobID: "job_1", command: "npm install"), into: &graph)
        guard let (started, startedPayload) = childNode(graph, id: "job_1") else {
            return XCTFail("job_started must create a childStream node")
        }
        XCTAssertEqual(started.status, .running)
        XCTAssertEqual(startedPayload.kind, .job)
        XCTAssertEqual(startedPayload.title, "npm install")

        _ = reducer.reduce(.jobOutput(turnID: nil, jobID: "job_1", chunk: "added 1 package\n"), into: &graph)
        _ = reducer.reduce(.jobOutput(turnID: nil, jobID: "job_1", chunk: "done\n"), into: &graph)
        guard let (_, outputPayload) = childNode(graph, id: "job_1") else { return XCTFail() }
        XCTAssertEqual(outputPayload.output, "added 1 package\ndone\n")

        _ = reducer.reduce(.jobFinished(turnID: "t1", jobID: "job_1", exitCode: nil,
                                        err: nil, elapsedMs: 93000, text: "exited"), into: &graph)
        guard let (finished, finishedPayload) = childNode(graph, id: "job_1") else { return XCTFail() }
        XCTAssertEqual(finished.status, .completed)
        // §8.5：成功时 text 是状态枚举 "exited"，不是人读摘要 — result 应为空。
        XCTAssertNil(finishedPayload.result)
        XCTAssertFalse(finishedPayload.canceled)
        XCTAssertEqual(finishedPayload.elapsedMs, 93000)
        // started/output/finished 归并进同一个节点，不产生重复卡片。
        XCTAssertEqual(graph.nodes.values.filter { $0.kind == .childStream }.count, 1)
    }

    func testJobFinishedFailureStates() {
        // 命令非零退出（§8.5：exit_code > 0，err 冗余退出码作展示文案）
        var reducer = ExecutionReducer()
        var graph = ExecutionGraph()
        _ = reducer.reduce(.jobStarted(turnID: nil, jobID: "j", command: "make"), into: &graph)
        _ = reducer.reduce(.jobFinished(turnID: nil, jobID: "j", exitCode: 2,
                                        err: "exit code 2", elapsedMs: nil, text: "failed"), into: &graph)
        guard let (node, payload) = childNode(graph, id: "j") else { return XCTFail() }
        XCTAssertEqual(node.status, .failed)
        XCTAssertEqual(payload.result, "exit code 2")
        XCTAssertEqual(payload.exitCode, 2)

        // 启动失败/被信号杀死（§8.5：exit_code == -1）
        var reducer2 = ExecutionReducer()
        var graph2 = ExecutionGraph()
        _ = reducer2.reduce(.jobStarted(turnID: nil, jobID: "j", command: "make"), into: &graph2)
        _ = reducer2.reduce(.jobFinished(turnID: nil, jobID: "j", exitCode: -1,
                                         err: "signal: killed", elapsedMs: nil, text: "failed"), into: &graph2)
        guard let (killed, killedPayload) = childNode(graph2, id: "j") else { return XCTFail() }
        XCTAssertEqual(killed.status, .failed)
        XCTAssertEqual(killedPayload.exitCode, -1)
        XCTAssertEqual(killedPayload.result, "signal: killed")
    }

    // 主动取消（§8.5：text=="canceled"）→ 独立终态，样式区别于失败。
    func testJobCanceledIsDistinctFromFailure() {
        var reducer = ExecutionReducer()
        var graph = ExecutionGraph()
        _ = reducer.reduce(.turnStarted(turnID: "t1", text: "install"), into: &graph)
        _ = reducer.reduce(.jobStarted(turnID: "t1", jobID: "j", command: "sleep 100"), into: &graph)
        _ = reducer.reduce(.jobFinished(turnID: "t1", jobID: "j", exitCode: nil,
                                        err: nil, elapsedMs: nil, text: "canceled"), into: &graph)
        guard let (node, payload) = childNode(graph, id: "j") else { return XCTFail() }
        XCTAssertNotEqual(node.status, .failed)
        XCTAssertTrue(payload.canceled)

        // 投影层给独立的 .canceled 状态
        let turns = TimelineProjection().projectTurns(graph)
        let block = turns.flatMap(\.blocks).compactMap { block -> ChildStreamNodePayload? in
            if case .childStream(_, let p) = block { return p }
            return nil
        }.first
        XCTAssertEqual(block?.status, .canceled)
    }

    // 乱序/部分回放：没有 started 的 output/finished 不崩、不建节点。
    func testOrphanJobEventsAreSafe() {
        var reducer = ExecutionReducer()
        var graph = ExecutionGraph()
        XCTAssertEqual(reducer.reduce(.jobOutput(turnID: nil, jobID: "ghost", chunk: "x"), into: &graph), [])
        XCTAssertEqual(reducer.reduce(.jobFinished(turnID: nil, jobID: "ghost", exitCode: 0,
                                                   err: nil, elapsedMs: nil, text: ""), into: &graph), [])
        XCTAssertTrue(graph.nodes.isEmpty)
    }

    // Replay 重复 started：保持节点身份，不产生重复卡片。
    func testDuplicateJobStartedKeepsIdentity() {
        var reducer = ExecutionReducer()
        var graph = ExecutionGraph()
        _ = reducer.reduce(.jobStarted(turnID: nil, jobID: "j", command: "sleep 100"), into: &graph)
        _ = reducer.reduce(.jobStarted(turnID: nil, jobID: "j", command: "sleep 100"), into: &graph)
        XCTAssertEqual(graph.nodes.values.filter { $0.kind == .childStream }.count, 1)
    }

    // 回归：task 子agent 走同一 handler，行为不变。
    func testTaskEventsStillReduceToChildStream() {
        var reducer = ExecutionReducer()
        var graph = ExecutionGraph()
        _ = reducer.reduce(.taskStarted(turnID: "t1", sessionId: "sub_sess",
                                        parentSessionId: "root", text: "explore repo"), into: &graph)
        _ = reducer.reduce(.taskFinished(turnID: "t1", sessionId: "sub_sess",
                                         parentSessionId: "root", text: "found 3 issues"), into: &graph)
        guard let (node, payload) = childNode(graph, id: "sub_sess") else {
            return XCTFail("task events must produce a childStream node")
        }
        XCTAssertEqual(node.status, .completed)
        XCTAssertEqual(payload.kind, .task)
        XCTAssertEqual(payload.title, "explore repo")
        XCTAssertEqual(payload.result, "found 3 issues")
    }

    // MARK: - 投影：入口卡作为独立 TurnBlock 出现在 turn card 内

    func testProjectionEmitsChildStreamBlock() {
        var reducer = ExecutionReducer()
        var graph = ExecutionGraph()
        let events: [AgentEvent] = [
            .turnStarted(turnID: "t1", text: "安装 Onchain OS"),
            .jobStarted(turnID: "t1", jobID: "job_1", command: "npx skills add"),
            .jobFinished(turnID: "t1", jobID: "job_1", exitCode: nil, err: nil, elapsedMs: nil, text: "exited"),
            .turnFinished(turnID: "t1", text: "装好了", textAnnotations: []),
        ]
        for e in events { _ = reducer.reduce(e, into: &graph) }

        let turns = TimelineProjection().projectTurns(graph)
        XCTAssertEqual(turns.count, 1)
        let childBlocks = turns[0].blocks.compactMap { block -> ChildStreamNodePayload? in
            if case .childStream(_, let payload) = block { return payload }
            return nil
        }
        XCTAssertEqual(childBlocks.count, 1)
        XCTAssertEqual(childBlocks[0].childID, "job_1")
        XCTAssertEqual(childBlocks[0].status, .completed)
    }

    // MARK: - FixtureChildStreamTransport

    func testFixtureTransportServesBatchesByCursor() async throws {
        let transport = FixtureChildStreamTransport(batches: [
            [.jobStarted(turnID: nil, jobID: "j", command: "make")],
            [.jobOutput(turnID: nil, jobID: "j", chunk: "a"),
             .jobOutput(turnID: nil, jobID: "j", chunk: "b")],
            [.jobFinished(turnID: nil, jobID: "j", exitCode: nil, err: nil, elapsedMs: nil, text: "exited")],
        ])

        let first = try await transport.fetch(childID: "j", since: 0)
        XCTAssertEqual(first.events.count, 1)
        XCTAssertEqual(first.nextSince, 1)

        let second = try await transport.fetch(childID: "j", since: first.nextSince)
        XCTAssertEqual(second.events.count, 2)
        XCTAssertEqual(second.nextSince, 3)

        let third = try await transport.fetch(childID: "j", since: second.nextSince)
        XCTAssertEqual(third.events.count, 1)
        XCTAssertEqual(third.nextSince, 4)

        // 批次耗尽 → 空批，游标不回退。
        let drained = try await transport.fetch(childID: "j", since: third.nextSince)
        XCTAssertTrue(drained.events.isEmpty)
        XCTAssertEqual(drained.nextSince, 4)
    }
}
