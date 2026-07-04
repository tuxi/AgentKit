//
//  ChildStream.swift
//  AgentKit
//
//  P8.7 — 子流（task 子agent / 后台 job）取数抽象。
//  设计：docs/p8.7-client-plan.md §WI-3a、docs/p8.7-job-observability.md §4 Phase C。
//
//  统一为「打开一条事件流」语义（push），三种实现对查看器透明：
//    - 会话回放（subagent，回放-only）：GET /v1/conversations/{child}/events 翻页到尾。
//    - job 实时 WS（Phase C）：GET /v1/jobs/{id}/events backlog + /v1/jobs/{id}/stream 直播。
//    - fixture 回放（预览/测试）：脚本分批吐帧。
//

import Foundation

// MARK: - AgentEventBatch

/// 一批增量事件 + 下一次读取游标（CodeAgent backend 的游标 = 已收帧最大 seq）。
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
/// `open` 产出事件直到子流结束（回放到尾 / 收到 `job_finished`）或调用方取消迭代。
/// 实现内部决定轮询补齐 / WS 实时 / fixture 回放。
public protocol ChildStreamTransport: Sendable {
    func open(childID: String) -> AsyncStream<AgentEvent>
}

// MARK: - ConversationReplayChildStreamTransport（subagent，回放-only）

/// subagent 子流：同步执行，拿到 `task_finished` 时它已结束——没有实时可接的尾巴。
/// 打开时翻页拉 `GET /v1/conversations/{child}/events` 到尾即完成。
public struct ConversationReplayChildStreamTransport: ChildStreamTransport {
    private let client: RuntimeClient
    /// backlog 尚未落库时的空批重试预算（subagent bracket 与子流持久化之间的窗口）。
    private let emptyRetryBudget: Int
    private let retryDelayNs: UInt64

    public init(client: RuntimeClient, emptyRetryBudget: Int = 3,
                retryDelayNs: UInt64 = 400_000_000) {
        self.client = client
        self.emptyRetryBudget = emptyRetryBudget
        self.retryDelayNs = retryDelayNs
    }

    public func open(childID: String) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task {
                var since = 0
                var received = false
                var emptyRetries = 0
                while !Task.isCancelled {
                    let batch = (try? await client.getEventBatch(conversationID: childID, since: since))
                        ?? AgentEventBatch(events: [], nextSince: since)
                    for event in batch.events {
                        received = true
                        continuation.yield(event)
                    }
                    // 游标前进 → 还有更多，继续翻页。
                    if batch.nextSince > since {
                        since = batch.nextSince
                        continue
                    }
                    // 已收到过事件且到尾 → 回放完成。
                    if received { break }
                    // 一条都没收到：可能 backlog 还没落库，短暂重试几次后放弃。
                    emptyRetries += 1
                    if emptyRetries > emptyRetryBudget { break }
                    try? await Task.sleep(nanoseconds: retryDelayNs)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - JobLiveChildStreamTransport（后台 job，实时 WS）

/// job 子流：委托 `RuntimeClient.openJobStream`（transport 层用 AgentWireSocket 接
/// `/v1/jobs/{id}/stream`，含 backlog + seq 去重 + 重连）。查看器逻辑不变，只换传输。
public struct JobLiveChildStreamTransport: ChildStreamTransport {
    private let client: RuntimeClient

    public init(client: RuntimeClient) {
        self.client = client
    }

    public func open(childID: String) -> AsyncStream<AgentEvent> {
        client.openJobStream(jobID: childID)
    }
}

// MARK: - FixtureChildStreamTransport

/// 预览/测试用：按脚本分批吐事件，模拟逐步产生输出的子流。批次间插入延迟，让预览会动。
public final class FixtureChildStreamTransport: ChildStreamTransport, @unchecked Sendable {
    private let batches: [[AgentEvent]]
    private let batchDelayNs: UInt64

    public init(batches: [[AgentEvent]], batchDelayNs: UInt64 = 400_000_000) {
        self.batches = batches
        self.batchDelayNs = batchDelayNs
    }

    public func open(childID: String) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task { [batches, batchDelayNs] in
                for (index, batch) in batches.enumerated() {
                    if index > 0 { try? await Task.sleep(nanoseconds: batchDelayNs) }
                    if Task.isCancelled { break }
                    for event in batch { continuation.yield(event) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
