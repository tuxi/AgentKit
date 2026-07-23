//
//  WorkflowStore.swift
//  AgentKit
//
//  纯状态容器 + reducer，管理所有 Flux Workflow DAG 的状态。
//  以 `workflowID` 为 key，seq 做幂等和乱序处理。
//  对照协议：runtime-event-contract-v1.md §5.8。
//

import Foundation
import ClientToolProtocol

// MARK: - WorkflowStore

/// 所有 Workflow DAG 的状态中心。挂在 WorkspaceStore 级别，页面切换不清空。
@MainActor
public final class WorkflowStore: ObservableObject {

    /// 当前已知的所有 workflow run，以 workflowID 为 key。
    @Published public var runs: [String: WorkflowRun] = [:]

    /// 每个 workflow 已应用的最大 seq（幂等去重）。
    private var appliedSeq: [String: Int64] = [:]

    /// 乱序事件的暂存区：key = workflowID，value = 等待中的事件（按 seq 排序）。
    private var pendingEvents: [String: [(sequence: Int64, event: AgentEvent)]] = [:]

    /// 乱序缓冲窗口上限：超过此值强制应用（避免永远等待丢失的事件）。
    private static let maxPendingWindow = 50

    public init() {}

    // MARK: - Public API

    /// 处理单个事件。
    public func reduce(_ event: AgentEvent) {
        let (wfID, seq) = workflowSequence(from: event)

        guard let workflowID = wfID else { return }

        if let seq {
            let lastSeq = appliedSeq[workflowID] ?? 0
            if seq <= lastSeq {
                // 幂等：重复 seq，忽略
                return
            }

            if seq > lastSeq + 1 && pendingEvents[workflowID, default: []].count < Self.maxPendingWindow {
                // 乱序：暂存，等待前序事件
                var pending = pendingEvents[workflowID, default: []]
                let idx = pending.firstIndex(where: { $0.sequence > seq }) ?? pending.count
                pending.insert((seq, event), at: idx)
                pendingEvents[workflowID] = pending

                // 上限保护：超过缓冲区则强制刷新所有 pending
                if pending.count >= Self.maxPendingWindow {
                    flushPending(for: workflowID)
                }
                return
            }
        }

        // 直接应用
        apply(event, workflowID: workflowID, seq: seq)

        // 尝试消费缓冲区中续接的事件
        if seq != nil {
            flushPending(for: workflowID)
        }
    }

    /// 重连恢复：排序后逐个 replay。
    public func replay(_ events: [AgentEvent]) {
        // 排序：有 seq 的按 seq，无 seq 的 transient 放在尾部
        let sorted = events.sorted { a, b in
            let seqA = workflowSequence(from: a).seq ?? Int64.max
            let seqB = workflowSequence(from: b).seq ?? Int64.max
            return seqA < seqB
        }

        for event in sorted {
            // replay 时放宽 seq 检查：仅当 seq > 已记录时才应用
            // （因为 replay 可能包含之前已应用的事件）
            let (wfID, seq) = workflowSequence(from: event)
            guard let wfID else { continue }
            if let seq, seq <= (appliedSeq[wfID] ?? 0) { continue }
            apply(event, workflowID: wfID, seq: seq)
        }

        // 清空所有 pending（replay 后不应有残留）
        pendingEvents.removeAll()
    }

    // MARK: - Event extraction

    /// 从 AgentEvent 提取 (workflowID?, sequence?)。
    private func workflowSequence(from event: AgentEvent) -> (workflowID: String?, seq: Int64?) {
        switch event {
        case .workflowStarted(_, _, let workflowID):
            return (workflowID, nil)

        case .workflowPlanReady(_, _, let wf):
            return (wf.workflowID, nil) // plan_ready 可能没有 seq

        case .workflowTaskStateChanged(_, let wf):
            return (wf.workflowID, wf.sequence)

        case .workflowNodeStateChanged(_, let wf):
            return (wf.workflowID, wf.sequence)

        case .workflowSuspended(_, let wf):
            return (wf.workflowID, nil) // suspended 可能没有 seq

        case .workflowFinished(_, let wf):
            return (wf.workflowID, nil)

        case .workflowFailed(_, let wf):
            return (wf.workflowID, nil)

        case .workflowNodeProgress(_, let wf):
            return (wf.workflowID, nil) // transient, no seq

        case .workflowTaskProgress(_, let wf):
            return (wf.workflowID, nil)

        case .workflowToolProgress(_, let wf):
            return (wf.workflowID, nil)

        case .workflowToolLog(_, let wf):
            return (wf.workflowID, nil)

        case .workflowToolStream(_, let wf):
            return (wf.workflowID, nil)

        case .workflowToolStreamEnd(_, let workflowID, _):
            return (workflowID, nil)

        default:
            return (nil, nil)
        }
    }

    // MARK: - Apply

    private func apply(_ event: AgentEvent, workflowID: String, seq: Int64?) {
        switch event {
        case .workflowStarted(_, let callID, _):
            ensureRun(workflowID: workflowID, parentCallID: callID)
            if let seq { appliedSeq[workflowID] = seq }

        case .workflowPlanReady(_, _, let data):
            applyPlanReady(data, seq: seq)

        case .workflowTaskStateChanged(_, let data):
            applyTaskStateChange(data, seq: seq)

        case .workflowNodeStateChanged(_, let data):
            applyNodeStateChange(data, seq: seq)

        case .workflowSuspended(_, let data):
            applySuspended(data)

        case .workflowFinished(_, let data):
            applyFinished(data)

        case .workflowFailed(_, let data):
            applyFailed(data)

        case .workflowNodeProgress(_, let data):
            applyProgress(data)

        case .workflowTaskProgress(_, let data):
            applyTaskProgress(data)

        case .workflowToolLog(_, let data):
            applyToolLog(data)

        case .workflowToolStream(_, let data):
            applyToolStream(data)

        case .workflowToolStreamEnd(_, let workflowID, let nodeName):
            applyToolStreamEnd(workflowID: workflowID, nodeName: nodeName)

        case .workflowToolProgress:
            break // 仅更新节点 progress，已在 applyProgress 处理

        default:
            break
        }
    }

    // MARK: - Apply helpers

    private func ensureRun(workflowID: String, parentCallID: String) {
        guard runs[workflowID] == nil else { return }
        runs[workflowID] = WorkflowRun(
            workflowID: workflowID,
            parentCallID: parentCallID
        )
    }

    private func applyPlanReady(_ data: WorkflowPlanReadyData, seq: Int64?) {
        var run = runs[data.workflowID] ?? WorkflowRun(
            workflowID: data.workflowID,
            parentCallID: data.parentCallID
        )
        run.goal = data.goal

        // 全量替换 nodes（以 node.name 为 key）
        var nodes: [String: WorkflowNode] = [:]
        for pn in data.nodes {
            nodes[pn.name] = WorkflowNode(
                name: pn.name,
                type: pn.type,
                toolName: pn.toolName
            )
        }
        run.nodes = nodes
        run.edges = data.edges

        if let seq {
            run.lastSequence = seq
            appliedSeq[data.workflowID] = seq
        }

        runs[data.workflowID] = run
    }

    private func applyTaskStateChange(_ data: WorkflowTaskStateChange, seq: Int64?) {
        guard var run = runs[data.workflowID] else { return }
        run.taskID = data.taskID ?? run.taskID
        run.status = WorkflowTaskStatus(rawValue: data.to)
        if let seq {
            run.lastSequence = seq
            appliedSeq[data.workflowID] = seq
        }
        runs[data.workflowID] = run
    }

    private func applyNodeStateChange(_ data: WorkflowNodeStateChange, seq: Int64?) {
        guard var run = runs[data.workflowID] else { return }
        var node = run.nodes[data.nodeName] ?? WorkflowNode(
            name: data.nodeName, type: "tool"
        )

        node.state = WorkflowNodeState(rawValue: data.to)
        node.terminal = data.terminal
        node.progress = data.progress
        if let error = data.error {
            node.error = error
        }

        run.nodes[data.nodeName] = node
        run.taskID = data.taskID ?? run.taskID
        if let seq {
            run.lastSequence = seq
            appliedSeq[data.workflowID] = seq
        }
        runs[data.workflowID] = run
    }

    private func applySuspended(_ data: WorkflowSuspendedData) {
        guard var run = runs[data.workflowID] else { return }
        run.status = WorkflowTaskStatus(rawValue: data.status)
        run.suspendedNodeName = data.nodeName
        run.taskID = data.taskID ?? run.taskID
        runs[data.workflowID] = run
    }

    private func applyFinished(_ data: WorkflowFinishedData) {
        guard var run = runs[data.workflowID] else { return }
        run.status = WorkflowTaskStatus(rawValue: data.status)
        run.output = data.output
        run.taskID = data.taskID ?? run.taskID
        runs[data.workflowID] = run
    }

    private func applyFailed(_ data: WorkflowFailedData) {
        guard var run = runs[data.workflowID] else { return }
        run.status = WorkflowTaskStatus(rawValue: data.status)
        run.error = data.error
        run.taskID = data.taskID ?? run.taskID
        runs[data.workflowID] = run
    }

    private func applyProgress(_ data: WorkflowProgressData) {
        guard var run = runs[data.workflowID] else { return }
        if let nodeName = data.nodeName {
            var node = run.nodes[nodeName] ?? WorkflowNode(name: nodeName, type: "tool")
            node.progress = data.progress
            run.nodes[nodeName] = node
        }
        // 无 nodeName = task-level progress
        runs[data.workflowID] = run
    }

    private func applyTaskProgress(_ data: WorkflowProgressData) {
        // Task-level progress: 暂存为 metadata，不改变 node 状态
        // 在 Phase 2 UI 中可用于整体进度条
        guard runs[data.workflowID] != nil else { return }
        // No structural change — just keep the run alive for UI observation
    }

    private func applyToolLog(_ data: WorkflowToolStreamData) {
        guard var run = runs[data.workflowID] else { return }
        var node = run.nodes[data.nodeName] ?? WorkflowNode(name: data.nodeName, type: "tool")
        node.streamOutput = appendCapped(node.streamOutput, data.chunk)
        run.nodes[data.nodeName] = node
        runs[data.workflowID] = run
    }

    private func applyToolStream(_ data: WorkflowToolStreamData) {
        // 与 tool_log 相同处理：追加到 streamOutput 缓冲
        applyToolLog(data)
    }

    private func applyToolStreamEnd(workflowID: String, nodeName: String) {
        // stream_end marker — 不改变状态，只是标记流结束
        // Phase 2 UI 可据此停止流式动画
        guard runs[workflowID] != nil else { return }
    }

    // MARK: - Pending buffer

    private func flushPending(for workflowID: String) {
        guard var pending = pendingEvents[workflowID], !pending.isEmpty else { return }

        let lastSeq = appliedSeq[workflowID] ?? 0
        var applied = 0

        for item in pending {
            if item.sequence <= lastSeq {
                applied += 1
                continue // 已应用，跳过
            }
            if item.sequence == lastSeq + 1 {
                apply(item.event, workflowID: workflowID, seq: item.sequence)
                applied += 1
            } else {
                break // 还有缺口，等待
            }
        }

        if applied > 0 {
            pending.removeFirst(applied)
            if pending.isEmpty {
                pendingEvents.removeValue(forKey: workflowID)
            } else {
                pendingEvents[workflowID] = pending
            }
        }
    }

    // MARK: - Output capping

    /// Stream 输出上限（字符数），与 ExecutionReducer 保持一致。
    private static let maxStreamedOutput = 262_144
    private static let cappedHead = 131_072
    private static let cappedTail = 65_536
    private static let truncationMarker = "\n… [output truncated] …\n"

    private func appendCapped(_ current: String, _ chunk: String) -> String {
        var result = current + chunk
        guard result.count > Self.maxStreamedOutput else { return result }
        let head = result.prefix(Self.cappedHead)
        let tail = result.suffix(Self.cappedTail)
        result = String(head) + Self.truncationMarker + String(tail)
        return result
    }
}
