//
//  ParallelToolsTests.swift
//  AgentKitTests
//
//  P8.8 并行工具执行 —— 锁定客户端的两个契约不变量（docs/p8.8-*.md §8.1）：
//    1. tool_finished 按 call_id 关联，不靠"紧跟它的 tool_started"（并行下会交错）。
//    2. N 个工具可同时 running；乱序完成时各卡按 call_id 独立解析，互不串。
//  这些是审计的回归护栏——结构本就就绪，测试确保未来重构不引回相邻配对/单活跃假设。
//

import XCTest
@testable import AgentKit

final class ParallelToolsTests: XCTestCase {

    private func tool(_ id: String, _ name: String) -> AgentEvent {
        .toolStarted(turnID: "t1", callID: id,
                     tool: ToolCall(callID: id, toolName: name, toolArgs: nil))
    }
    private func done(_ id: String, _ name: String, err: String? = nil) -> AgentEvent {
        .toolFinished(turnID: "t1", callID: id,
                      result: ToolResult(callID: id, toolName: name,
                                         observation: err == nil ? "ok" : nil, error: err))
    }
    private func node(_ graph: ExecutionGraph, _ callID: String) -> GraphNode? { graph.nodes[callID] }

    // 交错 + 乱序完成：5 个工具全部 started 后才陆续 finished，且完成顺序打乱。
    func testInterleavedOutOfOrderFinishResolvesByCallID() {
        var reducer = ExecutionReducer()
        var graph = ExecutionGraph()

        var events: [AgentEvent] = [.turnStarted(turnID: "t1", text: "fan out")]
        // 5 个并发 tool_started 先到（no finished yet）
        for i in 0..<5 { events.append(tool("c\(i)", "read")) }
        for e in events { _ = reducer.reduce(e, into: &graph) }

        // 5 张卡全部同时 running —— 不假设"同时只有一个在跑"。
        let running = graph.nodes.values.filter {
            if case .toolCall = $0.payload { return $0.status == .running }
            return false
        }
        XCTAssertEqual(running.count, 5)

        // 乱序完成：c2, c0, c4, c1（c3 故意留着不完成），中间不相邻。
        _ = reducer.reduce(done("c2", "read"), into: &graph)
        _ = reducer.reduce(done("c0", "read"), into: &graph)
        _ = reducer.reduce(done("c4", "read", err: "boom"), into: &graph)
        _ = reducer.reduce(done("c1", "read"), into: &graph)

        // 每张卡按自己的 call_id 解析，互不串。
        XCTAssertEqual(node(graph, "c0")?.status, .completed)
        XCTAssertEqual(node(graph, "c1")?.status, .completed)
        XCTAssertEqual(node(graph, "c2")?.status, .completed)
        XCTAssertEqual(node(graph, "c4")?.status, .failed)     // 只有 c4 失败
        XCTAssertEqual(node(graph, "c3")?.status, .running)    // 未完成的仍 running
    }

    // tool_finished 不靠相邻：two 工具的 started/finished 完全交错穿插。
    func testFinishedNotAdjacentToItsStarted() {
        var reducer = ExecutionReducer()
        var graph = ExecutionGraph()
        let events: [AgentEvent] = [
            .turnStarted(turnID: "t1", text: "x"),
            tool("a", "grep"),
            tool("b", "read"),
            done("a", "grep"),      // a 完成时，b 的 finished 还没来（非相邻）
            tool("c", "bash"),
            done("b", "read"),      // b 完成夹在 c 的 started 之后
            done("c", "bash"),
        ]
        for e in events { _ = reducer.reduce(e, into: &graph) }

        XCTAssertEqual(node(graph, "a")?.status, .completed)
        XCTAssertEqual(node(graph, "b")?.status, .completed)
        XCTAssertEqual(node(graph, "c")?.status, .completed)
        // 三个不同 call_id → 三个独立节点（没有被相邻配对逻辑错误合并/覆盖）。
        let toolNodes = graph.nodes.values.filter { if case .toolCall = $0.payload { return true }; return false }
        XCTAssertEqual(toolNodes.count, 3)
    }

    // 交错的 tool_stdout 按 call_id 路由到正确的卡，不会串到别的工具。
    func testStreamingOutputRoutesByCallID() {
        var reducer = ExecutionReducer()
        var graph = ExecutionGraph()
        let events: [AgentEvent] = [
            .turnStarted(turnID: "t1", text: "x"),
            tool("a", "bash"),
            tool("b", "bash"),
            .toolStdout(turnID: "t1", callID: "a", chunk: "AAA"),
            .toolStdout(turnID: "t1", callID: "b", chunk: "BBB"),
            .toolStdout(turnID: "t1", callID: "a", chunk: "aaa"),
        ]
        for e in events { _ = reducer.reduce(e, into: &graph) }

        guard case .toolCall(let pa)? = node(graph, "a")?.payload,
              case .toolCall(let pb)? = node(graph, "b")?.payload else {
            return XCTFail("both tool nodes must exist")
        }
        XCTAssertEqual(pa.output, "AAAaaa")   // a 的两段，不含 B 的
        XCTAssertEqual(pb.output, "BBB")
    }

    // 5 个并行 task → 5 张 childStream 入口卡同时出现，各自 call_id 独立。
    func testFiveParallelSubagentsProduceFiveEntryCards() {
        var reducer = ExecutionReducer()
        var graph = ExecutionGraph()

        var events: [AgentEvent] = [.turnStarted(turnID: "t1", text: "调研 A/B/C/D/E")]
        // 5 个 task 工具卡 + 5 个 task_started bracket（共享各自 call_id）交错到达
        for i in 0..<5 {
            events.append(.toolStarted(turnID: "t1", callID: "c\(i)",
                tool: ToolCall(callID: "c\(i)", toolName: "task",
                               toolArgs: .object(["prompt": .string("调研 \(i)")]))))
            events.append(.taskStarted(turnID: "t1", sessionId: "sub\(i)",
                                       parentSessionId: "root", callID: "c\(i)", text: "调研 \(i)"))
        }
        for e in events { _ = reducer.reduce(e, into: &graph) }

        let entryCards = graph.nodes.values.filter { $0.kind == .childStream }
        XCTAssertEqual(entryCards.count, 5)
        XCTAssertTrue(entryCards.allSatisfy { $0.status == .running })

        // 投影层：5 张入口卡，5 张 task 工具卡全部按 call_id 合并隐藏。
        let blocks = TimelineProjection().projectTurns(graph)[0].blocks
        let cards = blocks.filter { if case .childStream = $0 { return true }; return false }
        XCTAssertEqual(cards.count, 5)
        let hasTaskToolGroup = blocks.contains { block in
            if case .toolGroup(let g) = block { return g.tools.contains { $0.toolName == "task" } }
            return false
        }
        XCTAssertFalse(hasTaskToolGroup)
    }
}
