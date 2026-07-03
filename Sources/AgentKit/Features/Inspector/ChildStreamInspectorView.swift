//
//  ChildStreamInspectorView.swift
//  AgentKit
//
//  P8.7 — 子流查看器（task 子agent / 后台 job）。
//  交互对齐 Claude Code 的 subagent UX：父对话只有一张折叠入口卡，
//  macOS 在右侧面板展开为完整 turn card（带活跃状态），iPhone 自动降级为 sheet。
//
//  取数走 ChildStreamTransport（M1/M2 轮询，Phase C 换 WS attach，视图不变）。
//

import SwiftUI

// MARK: - ChildStreamViewModel

/// 一个子流一个实例：内部复用独立的 `RuntimeEngine`，
/// task 子流的事件词汇表与主会话相同，reducer 原样可用；
/// job 子流只有 job_started/job_output/job_finished 三个 kind。
@MainActor
@Observable
public final class ChildStreamViewModel {

    public let selection: ChildStreamSelection

    /// 子流自己的快照 — 查看器唯一数据源。
    public private(set) var snapshot: RuntimeSnapshot
    /// 收到终态事件（task_finished / job_finished）后置位，轮询随之停止。
    public private(set) var isFinished = false
    /// 最近一次取数失败的描述（有事件后不再展示）。
    public private(set) var lastError: String?

    private let transport: ChildStreamTransport
    private let engine: RuntimeEngine
    private var since = 0
    private var pollTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?

    /// 轮询间隔（纳秒）。fixture/测试可注入更短的间隔。
    private let pollIntervalNs: UInt64

    public init(selection: ChildStreamSelection,
                transport: ChildStreamTransport,
                pollIntervalNs: UInt64 = 1_000_000_000) {
        self.selection = selection
        self.transport = transport
        self.engine = RuntimeEngine(sessionID: selection.childID)
        self.snapshot = .empty(sessionID: selection.childID)
        self.pollIntervalNs = pollIntervalNs
    }

    // MARK: - Lifecycle

    public func start() {
        guard pollTask == nil else { return }

        let stream = engine.stateStream()
        snapshotTask = Task { [weak self] in
            for await snap in stream {
                guard let self else { return }
                self.snapshot = snap
            }
        }

        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        snapshotTask?.cancel()
        snapshotTask = nil
    }

    // MARK: - Poll loop

    private func pollLoop() async {
        // 子流轮询期间视为 live — snapshot.turns 的 isLive 与旧的 `!isFinished` 一致。
        await engine.markLive()
        while !Task.isCancelled && !isFinished {
            do {
                let batch = try await transport.fetch(childID: selection.childID, since: since)
                since = batch.nextSince
                lastError = nil
                for event in batch.events {
                    if isTerminal(event) { isFinished = true }
                    await engine.ingest(event)
                }
                if isFinished { await engine.markFinished() }
            } catch {
                // 子流可能尚未产生事件（404）或网络抖动 — 下一轮重试。
                lastError = error.localizedDescription
            }
            if isFinished || Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: pollIntervalNs)
        }
    }

    private func isTerminal(_ event: AgentEvent) -> Bool {
        switch event {
        case .jobFinished, .taskFinished:
            return true
        default:
            return false
        }
    }

    // MARK: - Derived state

    /// job 子流的聚合节点（started/output/finished 归并成一个节点）。
    public var jobPayload: ChildStreamNodePayload? {
        for node in snapshot.timeline {
            if case .childStream(let payload) = node.kind, payload.kind == .job {
                return payload
            }
        }
        return nil
    }

    /// task 子流的 turn card 列表（复用主会话的 Turn → Block 投影，引擎侧已投影好）。
    public var turns: [ConversationTurn] {
        snapshot.turns
    }

    public var isEmpty: Bool {
        snapshot.timeline.isEmpty
    }
}

// MARK: - ChildStreamInspectorView

public struct ChildStreamInspectorView: View {
    let selection: ChildStreamSelection
    @Environment(WorkspaceStore.self) private var store
    @State private var viewModel: ChildStreamViewModel?

    public init(selection: ChildStreamSelection) {
        self.selection = selection
    }

    public var body: some View {
        Group {
            if let viewModel {
                ChildStreamContentView(viewModel: viewModel)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: selection) {
            viewModel?.stop()
            let vm = ChildStreamViewModel(
                selection: selection,
                transport: PollingChildStreamTransport(client: store.client)
            )
            viewModel = vm
            vm.start()
        }
        .onDisappear {
            viewModel?.stop()
        }
    }
}

// MARK: - ChildStreamContentView

struct ChildStreamContentView: View {
    let viewModel: ChildStreamViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
    }

    // MARK: - Header（完整 turn card 的顶栏：标题 + 活跃状态）

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: viewModel.selection.kind == .task
                  ? "person.crop.rectangle.stack" : "terminal")
                .font(.body)
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.selection.kind == .task ? "Subagent" : "Background Job")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Text(viewModel.selection.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                statusBadge
                if let elapsed = viewModel.jobPayload?.formattedElapsed {
                    Text(elapsed)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .running:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.small)
                Text("运行中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .completed:
            Label("已完成", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed:
            Label(failedLabel, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .canceled:
            Label("已取消", systemImage: "minus.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var failedLabel: String {
        // §8.5：-1 = 启动失败/被信号杀死；>0 = 命令非零退出。
        if let code = viewModel.jobPayload?.exitCode {
            if code == -1 { return "失败（被终止）" }
            if code > 0 { return "失败 (exit \(code))" }
        }
        return "失败"
    }

    private var status: ChildStreamNodeStatus {
        if let payload = viewModel.jobPayload { return payload.status }
        return viewModel.isFinished ? .completed : .running
    }

    private var statusColor: Color {
        switch status {
        case .running: return .orange
        case .completed: return .green
        case .failed: return .red
        case .canceled: return .gray
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isEmpty {
            emptyState
        } else {
            switch viewModel.selection.kind {
            case .task:
                taskTranscript
            case .job:
                jobOutput
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if let error = viewModel.lastError, !viewModel.isFinished {
                ContentUnavailableView(
                    "等待子任务事件…",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(error)
                )
            } else {
                ContentUnavailableView(
                    viewModel.isFinished ? "子任务无记录" : "等待子任务事件…",
                    systemImage: "clock.arrow.circlepath"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// task 子流：完整 turn card 时间线（复用主会话渲染器）。
    /// 滚动跟随与主时间线同一套 FollowingScrollView —— 贴底才跟随，
    /// 用户上滑看历史时子流事件不会拉回。
    private var taskTranscript: some View {
        FollowingScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(viewModel.turns) { turn in
                    TurnView(turn: turn)
                        .equatable()
                        .id(turn.id)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// job 子流：终端式实时输出。
    private var jobOutput: some View {
        FollowingScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let payload = viewModel.jobPayload {
                    Text("$ \(payload.title)")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    if !payload.output.isEmpty {
                        Text(payload.output)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let result = payload.result, !result.isEmpty,
                       payload.status != .running {
                        Divider()
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(payload.status == .failed ? .red : .secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(12)
        }
    }
}

// MARK: - Previews（fixture 驱动，M1 可视化验收 —— 不依赖后端）

/// 构造一个用 fixture 回放驱动的查看器 VM；批次按轮询节奏逐批吐出，预览会动。
@MainActor
private func previewViewModel(
    kind: ChildStreamKind, title: String,
    batches: [[AgentEvent]]
) -> ChildStreamViewModel {
    let vm = ChildStreamViewModel(
        selection: ChildStreamSelection(childID: "job_preview", kind: kind, title: title),
        transport: FixtureChildStreamTransport(batches: batches),
        pollIntervalNs: 600_000_000
    )
    vm.start()
    return vm
}

#Preview("Job · 成功（流式输出）") {
    ChildStreamContentView(viewModel: previewViewModel(
        kind: .job, title: "npx skills add okx/onchainos-skills --yes -g",
        batches: [
            [.jobStarted(turnID: nil, jobID: "job_preview",
                         command: "npx skills add okx/onchainos-skills --yes -g")],
            [.jobOutput(turnID: nil, jobID: "job_preview", chunk: "Cloning repository...\n")],
            [.jobOutput(turnID: nil, jobID: "job_preview", chunk: "Resolving deltas: 100%\n"),
             .jobOutput(turnID: nil, jobID: "job_preview", chunk: "Installed 3 skills.\n")],
            [.jobFinished(turnID: nil, jobID: "job_preview", exitCode: nil,
                          err: nil, elapsedMs: 93000, text: "exited")],
        ]
    ))
    .frame(width: 360, height: 420)
    .environment(WorkspaceStore())
}

#Preview("Job · 失败 exit 2") {
    ChildStreamContentView(viewModel: previewViewModel(
        kind: .job, title: "make release",
        batches: [
            [.jobStarted(turnID: nil, jobID: "job_preview", command: "make release"),
             .jobOutput(turnID: nil, jobID: "job_preview", chunk: "ld: symbol not found\n"),
             .jobFinished(turnID: nil, jobID: "job_preview", exitCode: 2,
                          err: "exit code 2", elapsedMs: 4200, text: "failed")],
        ]
    ))
    .frame(width: 360, height: 420)
    .environment(WorkspaceStore())
}

#Preview("Job · 已取消") {
    ChildStreamContentView(viewModel: previewViewModel(
        kind: .job, title: "sleep 600",
        batches: [
            [.jobStarted(turnID: nil, jobID: "job_preview", command: "sleep 600"),
             .jobFinished(turnID: nil, jobID: "job_preview", exitCode: nil,
                          err: nil, elapsedMs: 12000, text: "canceled")],
        ]
    ))
    .frame(width: 360, height: 420)
    .environment(WorkspaceStore())
}

#Preview("Task · 子agent transcript") {
    ChildStreamContentView(viewModel: previewViewModel(
        kind: .task, title: "explore the repo and summarize the event pipeline",
        batches: [
            [.turnStarted(turnID: "t1", text: "explore the repo and summarize the event pipeline"),
             .toolStarted(turnID: "t1", callID: "c1",
                          tool: ToolCall(callID: "c1", toolName: "grep",
                                         toolArgs: .object(["pattern": .string("EventKind")])))],
            [.toolFinished(turnID: "t1", callID: "c1",
                           result: ToolResult(callID: "c1", toolName: "grep",
                                              observation: "12 matches", error: nil))],
            [.turnFinished(turnID: "t1", text: "事件管线：WireFrame → AgentEvent → Reducer → Projection。",
                           textAnnotations: []),
             .taskFinished(turnID: "t1", sessionId: "job_preview", parentSessionId: "root",
                           text: "已完成探索")],
        ]
    ))
    .frame(width: 360, height: 480)
    .environment(WorkspaceStore())
}
