//
//  ChildStream.swift
//  AgentKit
//
//  P8.7 — 子流（task 子agent / 后台 job）取数抽象。
//  设计：docs/p8.7-client-plan.md §WI-3a。
//
//  M1/M2 用轮询实现（GET /v1/conversations/{child_id}/events?since=N）；
//  Phase C 后端就绪后新增 WS attach 实现替换传输层，查看器不变。
//

import Foundation

// MARK: - AgentEventBatch

/// 一批增量事件 + 下一次读取游标。
/// `nextSince` 按服务端原始事件计数推进（未知 kind 被丢弃也不影响游标）。
public struct AgentEventBatch: Sendable {
    public let events: [AgentEvent]
    public let nextSince: Int

    public init(events: [AgentEvent], nextSince: Int) {
        self.events = events
        self.nextSince = nextSince
    }
}

// MARK: - ChildStreamTransport

/// 子流取数边界 —— `ChildStreamViewModel` 只依赖此协议。
public protocol ChildStreamTransport: Sendable {
    /// 读取 `childID` 子流自 `since` 游标之后的事件。
    /// 空批（`events.isEmpty`）表示暂无新事件，调用方按自己的节奏重试。
    func fetch(childID: String, since: Int) async throws -> AgentEventBatch
}

// MARK: - PollingChildStreamTransport

/// 轮询实现：走现有 REST 事件端点，按 id 直读事件日志（不要求根会话）。
public struct PollingChildStreamTransport: ChildStreamTransport {
    private let client: RuntimeClient

    public init(client: RuntimeClient) {
        self.client = client
    }

    public func fetch(childID: String, since: Int) async throws -> AgentEventBatch {
        try await client.getEventBatch(conversationID: childID, since: since)
    }
}

// MARK: - FixtureChildStreamTransport

/// M1 开发/演示/测试用：按脚本分批吐事件，模拟一个逐步产生输出的子流。
/// 每次 `fetch` 消费一个批次；批次耗尽后返回空批。
public final class FixtureChildStreamTransport: ChildStreamTransport, @unchecked Sendable {
    private let batches: [[AgentEvent]]

    public init(batches: [[AgentEvent]]) {
        self.batches = batches
    }

    public func fetch(childID: String, since: Int) async throws -> AgentEventBatch {
        var offset = 0
        for batch in batches {
            if offset >= since {
                return AgentEventBatch(events: batch, nextSince: offset + batch.count)
            }
            offset += batch.count
        }
        return AgentEventBatch(events: [], nextSince: offset)
    }
}
