//
//  ChildStream.swift
//  AgentKit
//
//  P8.7 — 子流（task 子agent / 后台 job）取数抽象。
//  设计：docs/p8.7-client-plan.md §WI-3a、docs/p8.7-job-observability.md §4 Phase C。
//
//  统一为「打开一条事件流」语义（push），三种实现对查看器透明：
//    - 会话回放（旧 backend 兼容）：GET /v1/conversations/{child}/events 翻页到尾。
//    - job 实时 WS（Phase C）：GET /v1/jobs/{id}/events backlog + /v1/jobs/{id}/stream 直播。
//    - task / multi-agent 实时 WS：GET /v1/child-streams/{id}/events backlog + /stream 直播。
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
    func open(childID: String) -> AsyncThrowingStream<AgentEvent, Error>
}

// MARK: - ConversationReplayChildStreamTransport（旧 backend 回放兼容）

/// 旧 backend 的兼容回放层。新 task/multi-agent Inspector 使用
/// `TaskLiveChildStreamTransport`，此实现不再承担活动子流展示。
public struct ConversationReplayChildStreamTransport: ChildStreamTransport {
    private let fetchBatch: @Sendable (String, Int) async throws -> AgentEventBatch
    /// backlog 尚未落库时的空批重试预算（subagent bracket 与子流持久化之间的窗口）。
    private let emptyRetryBudget: Int
    private let retryDelayNs: UInt64

    public init(client: RuntimeClient, emptyRetryBudget: Int = 3,
                retryDelayNs: UInt64 = 400_000_000) {
        self.fetchBatch = { childID, since in
            try await client.getEventBatch(conversationID: childID, since: since)
        }
        self.emptyRetryBudget = emptyRetryBudget
        self.retryDelayNs = retryDelayNs
    }

    init(emptyRetryBudget: Int = 3, retryDelayNs: UInt64 = 400_000_000,
         fetchBatch: @escaping @Sendable (String, Int) async throws -> AgentEventBatch) {
        self.fetchBatch = fetchBatch
        self.emptyRetryBudget = emptyRetryBudget
        self.retryDelayNs = retryDelayNs
    }

    public func open(childID: String) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var since = 0
                var idleRetries = 0
                do {
                    while !Task.isCancelled {
                        let batch = try await fetchBatch(childID, since)
                        var reachedTerminal = false
                        for event in batch.events {
                            continuation.yield(event)
                            if case .taskFinished(_, let sessionID, _, _) = event,
                               sessionID == childID {
                                reachedTerminal = true
                            }
                        }
                        if reachedTerminal { break }

                        if batch.nextSince > since {
                            since = batch.nextSince
                            idleRetries = 0
                            continue
                        }

                        // A non-empty batch is not proof that persistence has
                        // reached the tail. Keep polling for the matching
                        // task_finished envelope for a bounded quiet period.
                        idleRetries += 1
                        if idleRetries > emptyRetryBudget { break }
                        try await Task.sleep(nanoseconds: retryDelayNs)
                    }
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
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

    public func open(childID: String) -> AsyncThrowingStream<AgentEvent, Error> {
        let inner = client.openJobStream(jobID: childID)
        return AsyncThrowingStream { continuation in
            let task = Task {
                for await event in inner { continuation.yield(event) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - TaskLiveChildStreamTransport（task / multi-agent 实时 WS）

/// task / future multi-agent 子流：通用只读 child-stream endpoint。
/// RuntimeClient 负责 backlog、直播缓冲、seq 去重和断线重连。
public struct TaskLiveChildStreamTransport: ChildStreamTransport {
    private let client: RuntimeClient

    public init(client: RuntimeClient) {
        self.client = client
    }

    public func open(childID: String) -> AsyncThrowingStream<AgentEvent, Error> {
        let inner = client.openChildStream(childID: childID)
        return AsyncThrowingStream { continuation in
            let task = Task {
                for await event in inner { continuation.yield(event) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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

    public func open(childID: String) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
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
