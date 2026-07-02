//
//  EventStreamResumeTests.swift
//  AgentKitTests
//
//  v1.2 §4 增量续传：AgentWireSocket 的 seq 去重 + 握手后补缺口。
//  见 docs/client_integration_v1.md §2（恢复流程）/ §5.8-8（断线重连）。
//
//  测试直接喂 handleFrame（internal）驱动握手 / 直播帧，不依赖真实 WebSocket；
//  gapFetch 用闭包桩替代 HTTP 面。
//

import XCTest
@testable import AgentKit

@MainActor
final class EventStreamResumeTests: XCTestCase {

    // MARK: - Helpers

    private func makeSocket(since: Int) -> AgentWireSocket {
        AgentWireSocket(environment: .placeholder, conversationID: "c1", since: since)
    }

    private var helloData: Data {
        Data(#"{"type":"hello","protocol_version":1,"server":"test"}"#.utf8)
    }

    /// `turn_started` 事件帧；`text` 作标记方便断言顺序。
    private func frameJSON(seq: Int?, text: String) -> String {
        if let seq {
            return #"{"kind":"turn_started","seq":\#(seq),"turn_id":"t1","text":"\#(text)"}"#
        }
        return #"{"kind":"token_delta","turn_id":"t1","text":"\#(text)"}"#
    }

    private func frameData(seq: Int?, text: String) -> Data {
        Data(frameJSON(seq: seq, text: text).utf8)
    }

    // MARK: - 直播帧按 seq 去重（无 gapFetch，纯直播路径）

    /// 历史批已回放到 seq=10：直播流里 seq <= 10 的重叠帧丢弃，
    /// token_delta（无 seq）直通，重复 seq 只放行一次。
    func testLiveFramesDedupBySeqAgainstHistoryCursor() async throws {
        let socket = makeSocket(since: 10)
        let reader = StreamReader(socket.connect())

        socket.handleFrame(data: helloData)
        socket.handleFrame(data: frameData(seq: 9, text: "stale"))     // ≤ 10 → 丢
        socket.handleFrame(data: frameData(seq: 11, text: "s11"))
        socket.handleFrame(data: frameData(seq: nil, text: "delta"))   // token_delta 无 seq → 直通
        socket.handleFrame(data: frameData(seq: 11, text: "s11-dup"))  // 重复 → 丢
        socket.handleFrame(data: frameData(seq: 12, text: "s12"))

        let labels = await reader.collectLabels(count: 3)
        XCTAssertEqual(labels, ["s11", "delta", "s12"])
        socket.disconnect()
    }

    // MARK: - 握手后补缺口：缺口先行、直播缓冲、重叠去重

    /// 历史到 seq=5，缺口是 6/7。backfill 期间直播已送到 7（重叠）和 8：
    /// 产出顺序必须是 6 → 7 → 8，7 只出现一次。
    func testHandshakeBackfillBridgesGapAndDedupsOverlap() async throws {
        let socket = makeSocket(since: 5)
        let requestedSince = CallLog()
        socket.gapFetch = { since in
            await requestedSince.record(since)
            return try [
                makeWireFrame(seq: 6, text: "s6"),
                makeWireFrame(seq: 7, text: "s7"),
            ]
        }

        let reader = StreamReader(socket.connect())

        socket.handleFrame(data: helloData)
        // backfill 在途：直播帧进缓冲
        socket.handleFrame(data: frameData(seq: 7, text: "s7-live"))   // 与缺口批重叠 → 丢
        socket.handleFrame(data: frameData(seq: 8, text: "s8"))

        let labels = await reader.collectLabels(count: 3)
        XCTAssertEqual(labels, ["s6", "s7", "s8"])

        let calls = await requestedSince.calls
        XCTAssertEqual(calls, [5], "补缺口必须从历史批最大 seq 开始")
        socket.disconnect()
    }

    // MARK: - 重连（第二次 hello）：从推进后的游标续传

    /// 首连补空批后直播推进到 seq=8；断线重连（新 hello）时必须用 since=8 补缺口，
    /// 缺口批（seq=9）先于重连后的直播帧（seq=10）产出，重复的 9 被丢弃。
    func testReconnectResumesFromAdvancedCursor() async throws {
        let socket = makeSocket(since: 5)
        let requestedSince = CallLog()
        socket.gapFetch = { since in
            await requestedSince.record(since)
            guard since == 8 else { return [] }
            return try [makeWireFrame(seq: 9, text: "s9")]
        }

        let reader = StreamReader(socket.connect())

        // 首连：backfill(since=5) 返回空批，直播推进游标到 8
        socket.handleFrame(data: helloData)
        socket.handleFrame(data: frameData(seq: 8, text: "s8"))
        var labels = await reader.collectLabels(count: 1)
        XCTAssertEqual(labels, ["s8"])

        // 重连：新 hello → backfill(since=8) 补回 9；直播重发的 9 去重、10 放行
        socket.handleFrame(data: helloData)
        socket.handleFrame(data: frameData(seq: 9, text: "s9-live"))   // 与缺口批重叠 → 丢
        socket.handleFrame(data: frameData(seq: 10, text: "s10"))

        labels = await reader.collectLabels(count: 2)
        XCTAssertEqual(labels, ["s9", "s10"])

        let calls = await requestedSince.calls
        XCTAssertEqual(calls, [5, 8])
        socket.disconnect()
    }
}

// MARK: - StreamReader

/// 非隔离的流读取器：持有 iterator，规避 MainActor 隔离变量跨域 next() 的限制。
private final class StreamReader: @unchecked Sendable {
    private var iterator: AsyncStream<AgentEvent>.Iterator

    init(_ stream: AsyncStream<AgentEvent>) {
        self.iterator = stream.makeAsyncIterator()
    }

    /// 读取直到收集满 `count` 个带文本标记的事件（turn_started / token_delta）。
    func collectLabels(count: Int) async -> [String] {
        var labels: [String] = []
        while labels.count < count, let event = await iterator.next() {
            switch event {
            case .turnStarted(_, let text): labels.append(text)
            case .tokenDelta(_, let text): labels.append(text)
            default: break
            }
        }
        return labels
    }
}

// MARK: - Frame factory（自由函数：@Sendable gapFetch 闭包内可调，不捕获测试类）

private func makeWireFrame(seq: Int, text: String) throws -> WireFrame {
    let json = #"{"kind":"turn_started","seq":\#(seq),"turn_id":"t1","text":"\#(text)"}"#
    return try JSONDecoder().decode(WireFrame.self, from: Data(json.utf8))
}

// MARK: - CallLog

/// 记录 gapFetch 被调用时的 since 参数（@Sendable 闭包内的可变状态）。
private actor CallLog {
    private(set) var calls: [Int] = []

    func record(_ value: Int) {
        calls.append(value)
    }
}
