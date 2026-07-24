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

    /// 每个 workflow 已应用的最大 seq（幂等去重 + snapshot 基线）。
    private var appliedSeq: [String: Int64] = [:]

    /// 乱序事件暂存区已移除（Phase 4：snapshot 之后允许 seq 跳跃）。

    public init() {}

    // MARK: - Public API

    /// 处理单个事件。
    public func reduce(_ event: AgentEvent) {
        let (wfID, seq) = workflowSequence(from: event)

        guard let workflowID = wfID else { return }

        if let seq {
            let lastSeq = appliedSeq[workflowID] ?? 0
            if seq <= lastSeq {
                // 幂等：重复或已被 snapshot 覆盖的 seq，忽略
                return
            }
        }

        // 直接应用
        apply(event, workflowID: workflowID, seq: seq)
    }

    /// 重连恢复：排序后逐个 replay。
    public func replay(_ events: [AgentEvent]) {
        // 排序：无 seq 的初始化事件优先（workflowStarted/planReady 建立 run），
        // 有 seq 的按 seq 升序，无 seq 的 transient 事件放在最后。
        let sorted = events.sorted { a, b in
            let seqA = workflowSequence(from: a).seq
            let seqB = workflowSequence(from: b).seq
            switch (seqA, seqB) {
            case (nil, nil): return false   // 保持原始顺序
            case (nil, _):   return true    // 无 seq 优先（建立 baseline）
            case (_, nil):   return false
            case (let a?, let b?): return a < b
            }
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

        case .workflowTaskFailed(_, let wf):
            return (wf.workflowID, wf.sequence)

        case .workflowTaskSucceeded(_, let wf):
            return (wf.workflowID, wf.sequence)

        case .workflowTaskSuspended(_, let wf):
            return (wf.workflowID, wf.sequence)

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

        case .workflowTaskFailed(_, let data):
            applyTaskBracket(data, status: .failed)

        case .workflowTaskSucceeded(_, let data):
            applyTaskBracket(data, status: .success)

        case .workflowTaskSuspended(_, let data):
            applyTaskBracket(data, status: .suspended)

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

    // MARK: - Phase 4 Snapshot

    /// 应用 snapshot（初始化或刷新 DAG 状态）。
    /// 覆盖现有 run 的 nodes/edges/task status，并设置 `snapshotSequence` 用于增量过滤。
    public func applySnapshot(_ snapshot: WorkflowSnapshot) {
        var run = runs[snapshot.workflowId] ?? WorkflowRun(
            workflowID: snapshot.workflowId,
            parentCallID: ""
        )
        run.goal = snapshot.goal ?? run.goal
        run.taskID = snapshot.task?.id ?? run.taskID
        run.status = WorkflowTaskStatus(rawValue: snapshot.task?.status ?? "pending")
        run.output = snapshot.task?.output ?? run.output

        // 从 snapshot 构建 nodes（带正确 state）
        var nodes: [String: WorkflowNode] = [:]
        for sn in snapshot.nodes {
            var node = WorkflowNode(name: sn.name, type: inferNodeType(sn.name))
            node.state = WorkflowNodeState(rawValue: sn.state)
            node.terminal = sn.terminal
            if let e = sn.error { node.error = e }
            if let p = sn.progress { node.progress = p }
            if let o = sn.output { node.output = o }
            nodes[sn.name] = node
        }
        run.nodes = nodes
        run.edges = snapshot.edges.map { WorkflowEdge(from: $0.from, to: $0.to) }

        // 建立 seq 基线，后续增量事件只接受 seq > snapshotSequence
        let ss = snapshot.snapshotSequence
        run.lastSequence = ss
        appliedSeq[snapshot.workflowId] = ss

        runs[snapshot.workflowId] = run
    }

    /// 从 RuntimeClient 获取 snapshot 并 apply。
    public func fetchAndApplySnapshot(
        conversationID: String,
        workflowID: String,
        using fetch: (String, String) async throws -> WorkflowSnapshot
    ) async {
        do {
            let snapshot = try await fetch(conversationID, workflowID)
            applySnapshot(snapshot)
        } catch {
            // snapshot 加载失败不阻塞 UI —— 保持现有的 plan_ready 数据
            print("[WorkflowStore] snapshot fetch failed for \(workflowID): \(error)")
        }
    }

    /// 简单推断节点类型。snapshot 不含 type 字段，客户端按历史数据或工具名推断。
    private func inferNodeType(_ name: String) -> String {
        // 如果已有 run 中记录了这个节点的 type，复用
        // 否则按常见约定推断
        let lower = name.lowercased()
        if lower == "start" { return "start" }
        if lower == "end" { return "end" }
        return "tool"
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
                toolName: pn.toolName,
                inputMapping: pn.inputMapping
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
        if let output = data.output {
            node.output = output
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

    private func applyTaskBracket(_ data: WorkflowTaskBracketData, status: WorkflowTaskStatus) {
        guard var run = runs[data.workflowID] else { return }
        run.status = status
        run.taskID = data.taskID ?? run.taskID
        if let error = data.error {
            run.error = error
        }
        if let seq = data.sequence {
            run.lastSequence = seq
            appliedSeq[data.workflowID] = seq
        }
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
